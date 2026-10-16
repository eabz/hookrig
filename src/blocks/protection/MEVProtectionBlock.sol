// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";
import {JITGuardBlock, JITGuardLogic} from "./JITGuardBlock.sol";

library MEVProtectionLogic {
    struct MEVProtectionState {
        int24 maxTickDeltaPerSwap;
        int24 blockStartTick;
        uint32 lastSwapBlock;
        bool lastSwapZeroForOne;
        bool blockDirectionSet;
    }

    error SwapPriceImpactExceeded(int24 tickDelta, int24 maxAllowed);
    error InvalidMEVProtectionConfig(int24 maxTickDeltaPerSwap);

    function init(
        mapping(PoolId => MEVProtectionState) storage mevStates,
        mapping(PoolId => JITGuardLogic.JITConfig) storage jitConfigs,
        PoolId poolId,
        IHookRigBlock.MEVProtectionParams calldata params
    ) external {
        if (
            params.maxTickDeltaPerSwap < 0 || (params.maxTickDeltaPerSwap > 0 && params.maxTickDeltaPerSwap < 10)
                || params.maxTickDeltaPerSwap > 887_272
        ) {
            revert InvalidMEVProtectionConfig(params.maxTickDeltaPerSwap);
        }
        mevStates[poolId] = MEVProtectionState({
            maxTickDeltaPerSwap: params.maxTickDeltaPerSwap,
            blockStartTick: 0,
            lastSwapBlock: 0,
            lastSwapZeroForOne: false,
            blockDirectionSet: false
        });
        if (params.minLPHoldBlocks > 7200 || params.jitExitPenaltyBps > 5000) {
            revert JITGuardLogic.InvalidJITGuardConfig(params.minLPHoldBlocks, params.jitExitPenaltyBps);
        }
        jitConfigs[poolId] = JITGuardLogic.JITConfig({
            minLPHoldBlocks: params.minLPHoldBlocks, jitExitPenaltyBps: params.jitExitPenaltyBps
        });
    }

    /// @notice Enforces per-swap and intra-block cumulative tick impact limits and blocks intra-block sandwiching.
    /// @dev Direction-lock threshold (`S4-L07`): Only swaps moving at least `dirThreshold = max(2, maxDelta / 20)`
    ///      ticks (> 1 tick) arm or check the intra-block direction lock (`blockDirectionSet`). This dust-swap
    ///      exemption ensures 0-tick or 1-tick dust swaps (e.g., 1 wei) cannot grief opposite-direction traders for
    ///      the remainder of the block, while multi-step 1-tick walks remain strictly bounded by `blockDelta <= maxDelta`
    ///      from `blockStartTick` as well as per-swap LP fees and gas costs.
    function enforceAfterSwap(
        mapping(PoolId => MEVProtectionState) storage states,
        PoolId poolId,
        int24 preSwapTick,
        int24 postSwapTick,
        bool zeroForOne
    ) external {
        MEVProtectionState storage state = states[poolId];
        int24 maxDelta = state.maxTickDeltaPerSwap;
        int256 delta = postSwapTick >= preSwapTick
            ? int256(postSwapTick) - int256(preSwapTick)
            : int256(preSwapTick) - int256(postSwapTick);
        if (maxDelta > 0) {
            bool isNewBlock = state.lastSwapBlock != uint32(block.number);
            if (isNewBlock) {
                state.blockStartTick = preSwapTick;
                state.lastSwapBlock = uint32(block.number);
                state.blockDirectionSet = false;
            }
            int256 blockDelta = postSwapTick >= state.blockStartTick
                ? int256(postSwapTick) - int256(state.blockStartTick)
                : int256(state.blockStartTick) - int256(postSwapTick);
            if (delta > int256(maxDelta) || blockDelta > int256(maxDelta)) {
                int256 worst = delta >= blockDelta ? delta : blockDelta;
                int24 clampedDelta = worst > int256(type(int24).max) ? type(int24).max : int24(worst);
                revert SwapPriceImpactExceeded(clampedDelta, maxDelta);
            }
            int256 dirThreshold = int256(maxDelta) / 20;
            if (dirThreshold < 2) dirThreshold = 2;
            // Only a swap that moves at least `dirThreshold` ticks (> 1 tick) sets the block direction, so a 1-wei
            // dust swap cannot lock out opposite-direction traders for the block (`S4-L07`).
            if (delta >= dirThreshold) {
                if (state.blockDirectionSet && state.lastSwapZeroForOne != zeroForOne) {
                    int24 clampedDelta = delta > int256(type(int24).max) ? type(int24).max : int24(delta);
                    revert SwapPriceImpactExceeded(clampedDelta, maxDelta);
                }
                state.lastSwapZeroForOne = zeroForOne;
                state.blockDirectionSet = true;
            }
        }
    }
}

/// @title MEVProtectionBlock
/// @notice Group 2 (Protection & Access) — Block #5 (integrating Expansion Block #18 `JITGuardBlock`):
///         Enforces per-swap max tick impact, intra-block sandwich tracking, and JIT LP hold blocks.
/// @dev Trust Level: Low (purely algorithmic protection). Sub-threshold 0/1-tick dust swaps are exempt from
///      setting the intra-block direction lock (`dirThreshold >= 2`) so 1-wei swaps cannot grief opposite-direction
///      traders, while cumulative intra-block movement is still capped by `blockDelta <= maxTickDeltaPerSwap`.
abstract contract MEVProtectionBlock is JITGuardBlock {
    mapping(PoolId poolId => MEVProtectionLogic.MEVProtectionState state) internal _mevStates;

    error SwapPriceImpactExceeded(int24 tickDelta, int24 maxAllowed);
    error InvalidMEVProtectionConfig(int24 maxTickDeltaPerSwap);

    function _initMEVProtection(PoolId poolId, MEVProtectionParams calldata params) internal {
        MEVProtectionLogic.init(_mevStates, _jitConfigs, poolId, params);
    }

    function _enforceMEVAfterSwap(PoolId poolId, int24 preSwapTick, int24 postSwapTick, bool zeroForOne) internal {
        MEVProtectionLogic.enforceAfterSwap(_mevStates, poolId, preSwapTick, postSwapTick, zeroForOne);
    }
}
