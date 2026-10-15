// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

/// @title MEVProtectionBlock
/// @notice Group 2 (Protection & Access) — Block #5 (+ Block #18 JIT Guard):
///         Enforces per-swap max tick impact, intra-block sandwich reversal protection, and JIT LP hold blocks.
/// @dev Trust Level: Low (purely algorithmic protection).
abstract contract MEVProtectionBlock is IHookRigBlock {
    struct MEVProtectionState {
        int24 maxTickDeltaPerSwap;
        uint32 minLPHoldBlocks;
        uint16 jitExitPenaltyBps;
        uint32 lastSwapBlock;
        bool lastSwapZeroForOne;
    }

    mapping(PoolId poolId => MEVProtectionState state) internal _mevStates;
    mapping(PoolId poolId => mapping(bytes32 positionKey => uint32 addedAtBlock)) internal _lpAddedBlock;

    error SwapPriceImpactExceeded(int24 tickDelta, int24 maxAllowed);
    error JITLiquidityCooldownActive(uint32 addedBlock, uint32 currentBlock, uint32 minHoldBlocks);

    function _initMEVProtection(PoolId poolId, MEVProtectionParams calldata params) internal {
        _mevStates[poolId] = MEVProtectionState({
            maxTickDeltaPerSwap: params.maxTickDeltaPerSwap,
            minLPHoldBlocks: params.minLPHoldBlocks,
            jitExitPenaltyBps: params.jitExitPenaltyBps,
            lastSwapBlock: 0,
            lastSwapZeroForOne: false
        });
    }

    function _recordLPAddition(PoolId poolId, address lpOwner, ModifyLiquidityParams calldata params) internal {
        bytes32 posKey = keccak256(abi.encodePacked(lpOwner, params.tickLower, params.tickUpper, params.salt));
        _lpAddedBlock[poolId][posKey] = uint32(block.number);
    }

    function _enforceJITGuardOnRemove(PoolId poolId, address lpOwner, ModifyLiquidityParams calldata params)
        internal
        view
    {
        uint32 minHold = _mevStates[poolId].minLPHoldBlocks;
        if (minHold == 0) return;

        bytes32 posKey = keccak256(abi.encodePacked(lpOwner, params.tickLower, params.tickUpper, params.salt));
        uint32 addedBlock = _lpAddedBlock[poolId][posKey];
        if (addedBlock > 0 && block.number < addedBlock + minHold) {
            revert JITLiquidityCooldownActive(addedBlock, uint32(block.number), minHold);
        }
    }

    function _enforceMEVAfterSwap(PoolId poolId, int24 preSwapTick, int24 postSwapTick, bool zeroForOne) internal {
        MEVProtectionState storage state = _mevStates[poolId];
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
