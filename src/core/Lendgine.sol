// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.4;

import { ERC20 } from "./ERC20.sol";
import { JumpRate } from "./JumpRate.sol";
import { Pair } from "./Pair.sol";

import { IMintCallback } from "./interfaces/callbacks/IMintCallback.sol";

import { Balance } from "./libraries/Balance.sol";
import { FullMath } from "./libraries/FullMath.sol";
import { Position } from "./libraries/Position.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";

contract Lendgine is ERC20, JumpRate, Pair {
    using Position for mapping(address => Position.Info);
    using Position for Position.Info;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Mint(address indexed sender, uint256 amountS, uint256 shares, uint256 liquidity, address indexed to);

    event Burn(address indexed sender, uint256 amountS, uint256 shares, uint256 liquidity, address indexed to);

    event Deposit(address indexed sender, uint256 liquidity, address indexed to);

    event Withdraw(address indexed sender, uint256 liquidity, address indexed to);

    event AccrueInterest(uint256 timeElapsed, uint256 amountS, uint256 liquidity, uint256 rewardPerLiquidity);

    event AccruePositionInterest(address indexed owner, uint256 rewardPerLiquidity);

    event Collect(address indexed owner, address indexed to, uint256 amountBase);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InputError();

    error CompleteUtilizationError();

    error InsufficientInputError();

    error InsufficientPositionError();

    /*//////////////////////////////////////////////////////////////
                          LENDGINE STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(address => Position.Info) public positions;

    uint256 public totalLiquidityBorrowed;

    uint256 public totalLiquiditySupplied;

    uint256 public rewardPerLiquidityStored;

    uint64 public lastUpdate;

    function mint(
        address to,
        uint256 collateral,
        bytes calldata data
    ) external nonReentrant returns (uint256 shares) {
        _accrueInterest();

        uint256 liquidity = convertCollateralToLiquidity(collateral);
        shares = convertLiquidityToShare(liquidity);

        if (shares == 0 || collateral == 0) revert InsufficientOutputError();
        if (liquidity + totalLiquidityBorrowed > totalLiquidity) revert CompleteUtilizationError();
        if (totalSupply > 0 && totalLiquidityBorrowed == 0) revert CompleteUtilizationError();

        totalLiquidityBorrowed += liquidity;

        burn(to, liquidity);
        _mint(to, shares);

        uint256 balanceBefore = Balance.balance(token1);
        IMintCallback(msg.sender).mintCallback(collateral, data);
        uint256 balanceAfter = Balance.balance(token1);

        if (balanceAfter < balanceBefore + collateral) revert InsufficientInputError();

        emit Mint(msg.sender, collateral, shares, liquidity, to);
    }

    function burn(address to, bytes calldata data) external nonReentrant returns (uint256 collateral) {
        _accrueInterest();

        // calc shares and liquidity
        uint256 shares = balanceOf[address(this)];
        uint256 liquidity = convertShareToLiquidity(shares);
        collateral = convertLiquidityToCollateral(liquidity);

        if (liquidity == 0 || collateral == 0 || shares == 0) revert InputError();

        totalLiquidityBorrowed -= liquidity;

        // update state
        _burn(address(this), shares);
        SafeTransferLib.safeTransfer(token1, to, collateral); // optimistically transfer
        mint(liquidity, data);

        emit Burn(msg.sender, collateral, shares, liquidity, to);
    }

    function deposit(
        address to,
        uint256 liquidity,
        bytes calldata data
    ) external nonReentrant {
        _accrueInterest();

        uint256 _totalLiquiditySupplied = totalLiquiditySupplied; // SLOAD

        // validate inputs
        if (liquidity == 0) revert InputError();

        // calculate position
        uint256 position = Position.convertLiquidityToPosition(liquidity, totalLiquidity, _totalLiquiditySupplied);

        // update state
        positions.update(to, int256(position), rewardPerLiquidityStored);
        totalLiquiditySupplied = _totalLiquiditySupplied + liquidity;
        mint(liquidity, data);

        emit Deposit(msg.sender, liquidity, to);
    }

    function withdraw(address to, uint256 position) external nonReentrant {
        _accrueInterest();

        uint256 _totalLiquidity = totalLiquidity; // SLOAD
        uint256 _totalLiquiditySupplied = totalLiquiditySupplied; // SLOAD

        // validate inputs
        if (position == 0) revert InputError();

        // read position
        Position.Info memory positionInfo = positions.get(msg.sender);
        uint256 liquidity = Position.convertPositionToLiquidity(position, _totalLiquidity, _totalLiquiditySupplied);

        // check position
        if (position > positionInfo.size) revert InsufficientPositionError();
        if (totalLiquidityBorrowed > _totalLiquidity - liquidity) revert CompleteUtilizationError();

        // update state
        positions.update(msg.sender, -int256(position), rewardPerLiquidityStored);
        totalLiquiditySupplied = _totalLiquiditySupplied - liquidity;
        burn(to, liquidity);

        emit Withdraw(msg.sender, liquidity, to);
    }

    function accrueInterest() external nonReentrant {
        _accrueInterest();
    }

    function accruePositionInterest() external nonReentrant {
        _accrueInterest();
        _accruePositionInterest(msg.sender);
    }

    function collect(address to, uint256 collateralRequested) external nonReentrant returns (uint256 collateral) {
        Position.Info storage position = positions.get(msg.sender);

        collateral = collateralRequested > position.tokensOwed ? position.tokensOwed : collateralRequested;

        if (collateral > 0) {
            position.tokensOwed -= collateral;
            SafeTransferLib.safeTransfer(token1, to, collateral);
        }

        emit Collect(msg.sender, to, collateral);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function convertLiquidityToShare(uint256 liquidity) public view returns (uint256) {
        uint256 _totalLiquidityBorrowed = totalLiquidityBorrowed; // SLOAD
        return
            _totalLiquidityBorrowed == 0 ? liquidity : FullMath.mulDiv(liquidity, totalSupply, _totalLiquidityBorrowed);
    }

    function convertShareToLiquidity(uint256 shares) public view returns (uint256) {
        return FullMath.mulDiv(totalLiquidityBorrowed, shares, totalSupply);
    }

    function convertCollateralToLiquidity(uint256 collateral) public view returns (uint256) {
        return FullMath.mulDiv(collateral, 1 ether, 2 * upperBound);
    }

    function convertLiquidityToCollateral(uint256 liquidity) public view returns (uint256) {
        return FullMath.mulDiv(liquidity, 2 * upperBound, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL INTEREST LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Helper function for accruing lendgine interest
    function _accrueInterest() private {
        if (totalSupply == 0 || totalLiquidityBorrowed == 0) {
            lastUpdate = uint64(block.timestamp);
            return;
        }

        uint256 timeElapsed = block.timestamp - lastUpdate;
        if (timeElapsed == 0) return;

        uint256 _totalLiquidityBorrowed = totalLiquidityBorrowed; // SLOAD
        uint256 _totalLiquiditySupplied = totalLiquiditySupplied; // SLOAD

        uint256 borrowRate = getBorrowRate(_totalLiquidityBorrowed, _totalLiquiditySupplied);

        uint256 dilutionLPRequested = (FullMath.mulDiv(borrowRate, _totalLiquidityBorrowed, 1 ether) * timeElapsed) /
            365 days;
        uint256 dilutionLP = dilutionLPRequested > _totalLiquidityBorrowed
            ? _totalLiquidityBorrowed
            : dilutionLPRequested;
        uint256 dilutionSpeculative = convertLiquidityToCollateral(dilutionLP);

        totalLiquidityBorrowed = _totalLiquidityBorrowed - dilutionLP;
        totalLiquiditySupplied = _totalLiquiditySupplied - dilutionLP;
        rewardPerLiquidityStored += FullMath.mulDiv(dilutionSpeculative, 1 ether, _totalLiquiditySupplied);
        lastUpdate = uint64(block.timestamp);

        emit AccrueInterest(timeElapsed, dilutionSpeculative, dilutionLP, rewardPerLiquidityStored);
    }

    /// @notice Helper function for accruing interest to a position
    /// @dev Assume the global interest is up to date
    /// @param owner The address that this position belongs to
    function _accruePositionInterest(address owner) private {
        uint256 _rewardPerLiquidityStored = rewardPerLiquidityStored; // SLOAD

        positions.update(owner, 0, _rewardPerLiquidityStored); // TODO: rewards based on

        emit AccruePositionInterest(owner, _rewardPerLiquidityStored);
    }
}