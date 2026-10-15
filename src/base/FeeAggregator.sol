// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {DynamicFeeBlock, DynamicFeeLogic} from "../blocks/fees/DynamicFeeBlock.sol";
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
        return DynamicFeeLogic.resolveBeforeSwapFee(
            _dynamicFeeStates, _managedFeeStates, _marketHoursConfigs, _antiSnipeStates, poolId, bitmap, currentTick
        );
    }
}
