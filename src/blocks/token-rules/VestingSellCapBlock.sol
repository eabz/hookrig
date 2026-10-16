// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library VestingSellCapLogic {
    uint16 internal constant MIN_DAILY_SELL_BPS = 50; // Minimum 0.50% per day (anti-honeypot)
    uint16 internal constant MAX_DAILY_SELL_BPS = 5000; // Maximum 50.00% per day

    struct WalletSellEpoch {
        uint64 epochIndex;
        uint128 startOfEpochBalance;
        uint128 soldInEpoch;
    }

    error InvalidDailySellCapBps(uint16 requestedBps);
    error DailyVestingSellCapExceeded(address seller, uint256 attemptedSellTotal, uint256 maxDailyAllowed);

    function init(
        mapping(PoolId => IHookRigBlock.VestingSellCapParams) storage configs,
        PoolId poolId,
        IHookRigBlock.VestingSellCapParams calldata params
    ) external {
        if (params.maxDailySellBps < MIN_DAILY_SELL_BPS || params.maxDailySellBps > MAX_DAILY_SELL_BPS) {
            revert InvalidDailySellCapBps(params.maxDailySellBps);
        }
        configs[poolId] = params;
    }

    /// @param sellerIsSwapper True when `seller` is the PoolManager locker itself (not a user resolved through a
    ///        trusted router), so its open PoolManager deltas (flash `take`, pre-settled input) are netted out.
    function enforceSellCap(
        mapping(PoolId => IHookRigBlock.VestingSellCapParams) storage configs,
        mapping(PoolId => mapping(address => WalletSellEpoch)) storage epochs,
        IPoolManager manager,
        PoolId poolId,
        Currency projectCurrency,
        address seller,
        bool sellerIsSwapper,
        uint256 tokensSold
    ) external {
        uint16 maxBps = configs[poolId].maxDailySellBps;
        if (maxBps == 0 || maxBps >= 10_000 || tokensSold == 0 || projectCurrency.isAddressZero()) return;

        if (sellerIsSwapper) {
            revert DailyVestingSellCapExceeded(seller, tokensSold, 0);
        }

        uint256 preSellBal = _preSellBalance(manager, projectCurrency, seller, sellerIsSwapper, tokensSold);
        if (preSellBal == 0) return;

        uint64 currentEpoch = uint64(block.timestamp / 1 days);
        WalletSellEpoch storage ep = epochs[poolId][seller];

        if (ep.epochIndex != currentEpoch || ep.startOfEpochBalance == 0) {
            ep.epochIndex = currentEpoch;
            ep.startOfEpochBalance = _toUint128(preSellBal);
            ep.soldInEpoch = 0;
        } else {
            // Tokens moved out after the snapshot lower the cap; tokens moved in never raise it.
            uint256 liveStart = preSellBal + ep.soldInEpoch;
            if (liveStart < ep.startOfEpochBalance) {
                ep.startOfEpochBalance = _toUint128(liveStart);
            }
        }

        uint256 maxAllowed = Math.mulDiv(ep.startOfEpochBalance, maxBps, 10_000, Math.Rounding.Floor);
        if (maxAllowed == 0 && ep.startOfEpochBalance > 0) {
            maxAllowed = 1;
        }
        uint256 newSoldTotal = uint256(ep.soldInEpoch) + tokensSold;
        if (newSoldTotal > maxAllowed) {
            revert DailyVestingSellCapExceeded(seller, newSoldTotal, maxAllowed);
        }

        ep.soldInEpoch = uint128(newSoldTotal);
    }

    /// @dev The seller's balance before this sale. PoolManager has not yet booked the sale itself when
    ///      afterSwap runs, so for the locker the open delta is only earlier activity in the same unlock:
    ///      a flash `take` (negative) or input settled before the swap (positive).
    function _preSellBalance(
        IPoolManager manager,
        Currency projectCurrency,
        address seller,
        bool sellerIsSwapper,
        uint256 tokensSold
    ) private view returns (uint256) {
        int256 bal = int256(IERC20(Currency.unwrap(projectCurrency)).balanceOf(seller));
        if (sellerIsSwapper) {
            int256 delta = TransientStateLibrary.currencyDelta(manager, seller, projectCurrency);
            // A stateless pass-through router holds 0 tokens after settling and has at most `+tokensSold` pre-settled
            // in PoolManager (which PoolManager will net against the swap right after `afterSwap`).
            if (bal == 0 && delta <= int256(tokensSold)) {
                return 0;
            }
            bal += delta;
        } else if (bal < int256(tokensSold)) {
            // A trusted router pulled the input from the user before the swap.
            bal += int256(tokensSold);
        }
        return bal > 0 ? uint256(bal) : 0;
    }

    function _toUint128(uint256 x) private pure returns (uint128) {
        return uint128(x > type(uint128).max ? type(uint128).max : x);
    }
}

/// @title VestingSellCapBlock
/// @notice Group 3 (Token Rules) — Expansion Block #21: Vesting / Daily Sell Cap (`beforeSwap`, `afterSwap`).
/// @dev Trust Level: Low (caps the percentage of a wallet's balance that can be sold per 24-hour epoch;
///      bounded by MIN_DAILY_SELL_BPS = 50 = 0.50%/day so selling can never be bricked).
abstract contract VestingSellCapBlock is IHookRigBlock {
    mapping(PoolId poolId => VestingSellCapParams config) internal _vestingSellConfigs;
    mapping(PoolId poolId => mapping(address seller => VestingSellCapLogic.WalletSellEpoch epoch)) internal
        _walletSellEpochs;

    function _initVestingSellCap(PoolId poolId, VestingSellCapParams calldata params) internal {
        VestingSellCapLogic.init(_vestingSellConfigs, poolId, params);
    }

    function _enforceVestingSellCap(
        IPoolManager manager,
        PoolId poolId,
        Currency projectCurrency,
        address seller,
        bool sellerIsSwapper,
        uint256 tokensSold
    ) internal {
        VestingSellCapLogic.enforceSellCap(
            _vestingSellConfigs,
            _walletSellEpochs,
            manager,
            poolId,
            projectCurrency,
            seller,
            sellerIsSwapper,
            tokensSold
        );
    }
}
