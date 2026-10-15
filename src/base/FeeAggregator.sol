// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookPermissionMasks} from "../libraries/HookPermissionMasks.sol";
import {DynamicFeeBlock} from "../blocks/fees/DynamicFeeBlock.sol";
import {ManagedFeeBlock} from "../blocks/fees/ManagedFeeBlock.sol";
import {MarketHoursFeeBlock} from "../blocks/fees/MarketHoursFeeBlock.sol";
import {AntiSnipeBlock} from "../blocks/protection/AntiSnipeBlock.sol";

/// @title FeeAggregator
/// @notice Deterministic resolution of `beforeSwap` dynamic LP fees across all 4 fee blocks:
///         `Dynamic fee`, `Managed fee`, `Market-hours fee`, and `Anti-snipe`.
/// @dev Applies the Dominant Protection Rule: `min(MAX_LP_FEE, max(dynamic, managed, marketHours, antiSnipe))`.
abstract contract FeeAggregator is DynamicFeeBlock, ManagedFeeBlock, MarketHoursFeeBlock, AntiSnipeBlock {
    function _resolveBeforeSwapFee(PoolId poolId, uint32 bitmap, int24 currentTick)
        internal
        returns (uint24 lpFeeOverride)
    {
        if ((bitmap & HookPermissionMasks.FEE_BLOCKS_MASK) == 0) {
            return 0;
        }

        uint24 resolvedFee = 0;

        if ((bitmap & HookPermissionMasks.BIT_DYNAMIC_FEE) != 0) {
            uint24 dynFee = _computeDynamicFee(poolId, currentTick);
            if (dynFee > resolvedFee) resolvedFee = dynFee;
        }

        if ((bitmap & HookPermissionMasks.BIT_MANAGED_FEE) != 0) {
            uint24 mgdFee = _getManagedFee(poolId);
            if (mgdFee > resolvedFee) resolvedFee = mgdFee;
        }

        if ((bitmap & HookPermissionMasks.BIT_MARKET_HOURS_FEE) != 0) {
            uint24 mktFee = _computeMarketHoursFee(poolId);
            if (mktFee > resolvedFee) resolvedFee = mktFee;
        }

        if ((bitmap & HookPermissionMasks.BIT_ANTI_SNIPE) != 0) {
            uint24 snipeFee = _computeAntiSnipeFee(poolId);
            if (snipeFee > resolvedFee) resolvedFee = snipeFee;
        }

        if (resolvedFee > LPFeeLibrary.MAX_LP_FEE) {
            resolvedFee = LPFeeLibrary.MAX_LP_FEE;
        }

        return resolvedFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }
}
