// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {JITGuardBlock} from "./JITGuardBlock.sol";

library MEVProtectionLogic {
    struct MEVProtectionState {
        int24 maxTickDeltaPerSwap;
        uint32 lastSwapBlock;
        bool lastSwapZeroForOne;
    }

    error SwapPriceImpactExceeded(int24 tickDelta, int24 maxAllowed);

    function enforceAfterSwap(
        mapping(PoolId => MEVProtectionState) storage states,
        PoolId poolId,
        int24 preSwapTick,
        int24 postSwapTick,
        bool zeroForOne
    ) external {
        MEVProtectionState storage state = states[poolId];
        int24 maxDelta = state.maxTickDeltaPerSwap;
        if (maxDelta > 0) {
            int24 delta = postSwapTick >= preSwapTick ? postSwapTick - preSwapTick : preSwapTick - postSwapTick;
            if (delta > maxDelta) {
                revert SwapPriceImpactExceeded(delta, maxDelta);
            }
        }
        state.lastSwapBlock = uint32(block.number);
        state.lastSwapZeroForOne = zeroForOne;
    }
}

/// @title MEVProtectionBlock
/// @notice Group 2 (Protection & Access) — Block #5 (integrating Expansion Block #18 `JITGuardBlock`):
///         Enforces per-swap max tick impact, intra-block sandwich tracking, and JIT LP hold blocks.
/// @dev Trust Level: Low (purely algorithmic protection).
abstract contract MEVProtectionBlock is JITGuardBlock {
    mapping(PoolId poolId => MEVProtectionLogic.MEVProtectionState state) internal _mevStates;

    error SwapPriceImpactExceeded(int24 tickDelta, int24 maxAllowed);

    function _initMEVProtection(PoolId poolId, MEVProtectionParams calldata params) internal {
        _mevStates[poolId] = MEVProtectionLogic.MEVProtectionState({
            maxTickDeltaPerSwap: params.maxTickDeltaPerSwap, lastSwapBlock: 0, lastSwapZeroForOne: false
        });
        _initJITGuard(poolId, params.minLPHoldBlocks, params.jitExitPenaltyBps);
    }

    function _enforceMEVAfterSwap(PoolId poolId, int24 preSwapTick, int24 postSwapTick, bool zeroForOne) internal {
        MEVProtectionLogic.enforceAfterSwap(_mevStates, poolId, preSwapTick, postSwapTick, zeroForOne);
    }
}
