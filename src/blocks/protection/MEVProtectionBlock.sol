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
            lastSwapZeroForOne: false
        });
        if (params.minLPHoldBlocks > 7200 || params.jitExitPenaltyBps > 5000) {
            revert JITGuardLogic.InvalidJITGuardConfig(params.minLPHoldBlocks, params.jitExitPenaltyBps);
        }
        jitConfigs[poolId] = JITGuardLogic.JITConfig({
            minLPHoldBlocks: params.minLPHoldBlocks, jitExitPenaltyBps: params.jitExitPenaltyBps
        });
    }

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
            if (state.lastSwapBlock != uint32(block.number)) {
                state.blockStartTick = preSwapTick;
            }
            int256 blockDelta = postSwapTick >= state.blockStartTick
                ? int256(postSwapTick) - int256(state.blockStartTick)
                : int256(state.blockStartTick) - int256(postSwapTick);
            if (delta > int256(maxDelta) || blockDelta > int256(maxDelta)) {
                int256 worst = delta >= blockDelta ? delta : blockDelta;
                int24 clampedDelta = worst > int256(type(int24).max) ? type(int24).max : int24(worst);
                revert SwapPriceImpactExceeded(clampedDelta, maxDelta);
            }
            if (delta > 0 && state.lastSwapBlock == uint32(block.number) && state.lastSwapZeroForOne != zeroForOne) {
                int24 clampedDelta = delta > int256(type(int24).max) ? type(int24).max : int24(delta);
                revert SwapPriceImpactExceeded(clampedDelta, maxDelta);
            }
        }
        if (delta > 0) {
            state.lastSwapBlock = uint32(block.number);
            state.lastSwapZeroForOne = zeroForOne;
        }
    }
}

/// @title MEVProtectionBlock
/// @notice Group 2 (Protection & Access) — Block #5 (integrating Expansion Block #18 `JITGuardBlock`):
///         Enforces per-swap max tick impact, intra-block sandwich tracking, and JIT LP hold blocks.
/// @dev Trust Level: Low (purely algorithmic protection).
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
