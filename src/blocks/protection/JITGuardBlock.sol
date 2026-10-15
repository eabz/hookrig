// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library JITGuardLogic {
    struct JITConfig {
        uint32 minLPHoldBlocks;
        uint16 jitExitPenaltyBps;
    }

    error JITLiquidityCooldownActive(uint32 addedBlock, uint32 currentBlock, uint32 minHoldBlocks);
    error InvalidJITGuardConfig(uint32 minLPHoldBlocks, uint16 jitExitPenaltyBps);

    function recordAddition(
        mapping(PoolId => mapping(bytes32 => uint32)) storage lpAddedBlock,
        PoolId poolId,
        address lpOwner,
        ModifyLiquidityParams calldata params
    ) external {
        bytes32 posKey = keccak256(abi.encodePacked(lpOwner, params.tickLower, params.tickUpper, params.salt));
        if (lpAddedBlock[poolId][posKey] == 0) {
            lpAddedBlock[poolId][posKey] = uint32(block.number);
        }
        bytes32 rangeKey = keccak256(abi.encodePacked(params.tickLower, params.tickUpper, params.salt));
        if (lpAddedBlock[poolId][rangeKey] == 0) {
            lpAddedBlock[poolId][rangeKey] = uint32(block.number);
        }
    }

    function enforceOnRemove(
        mapping(PoolId => JITConfig) storage configs,
        mapping(PoolId => mapping(bytes32 => uint32)) storage lpAddedBlock,
        PoolId poolId,
        address lpOwner,
        ModifyLiquidityParams calldata params
    ) external view {
        uint32 minHold = configs[poolId].minLPHoldBlocks;
        if (minHold == 0) return;

        bytes32 posKey = keccak256(abi.encodePacked(lpOwner, params.tickLower, params.tickUpper, params.salt));
        uint32 addedBlock = lpAddedBlock[poolId][posKey];
        if (addedBlock == 0) {
            bytes32 rangeKey = keccak256(abi.encodePacked(params.tickLower, params.tickUpper, params.salt));
            addedBlock = lpAddedBlock[poolId][rangeKey];
        }
        if (addedBlock > 0 && block.number < uint256(addedBlock) + uint256(minHold)) {
            revert JITLiquidityCooldownActive(addedBlock, uint32(block.number), minHold);
        }
    }
}

/// @title JITGuardBlock
/// @notice Group 2 (Protection & Access) — Expansion Block #18: Just-In-Time (JIT) Liquidity Guard
///         (`beforeAddLiquidity`, `beforeRemoveLiquidity`).
/// @dev Trust Level: Low (prevents single-block JIT liquidity attacks that dilute LP rewards / Arb recapture donations).
abstract contract JITGuardBlock is IHookRigBlock {
    mapping(PoolId poolId => JITGuardLogic.JITConfig config) internal _jitConfigs;
    mapping(PoolId poolId => mapping(bytes32 positionKey => uint32 addedAtBlock)) internal _lpAddedBlock;

    uint32 internal constant MAX_LP_HOLD_BLOCKS = 7200; // ~24h ceiling so LPs can never be permanently locked
    uint16 internal constant MAX_JIT_PENALTY_BPS = 5000; // 50.00%

    function _initJITGuard(PoolId poolId, uint32 minLPHoldBlocks, uint16 jitExitPenaltyBps) internal {
        if (minLPHoldBlocks > MAX_LP_HOLD_BLOCKS || jitExitPenaltyBps > MAX_JIT_PENALTY_BPS) {
            revert JITGuardLogic.InvalidJITGuardConfig(minLPHoldBlocks, jitExitPenaltyBps);
        }
        _jitConfigs[poolId] =
            JITGuardLogic.JITConfig({minLPHoldBlocks: minLPHoldBlocks, jitExitPenaltyBps: jitExitPenaltyBps});
    }

    function _recordLPAddition(PoolId poolId, address lpOwner, ModifyLiquidityParams calldata params) internal {
        JITGuardLogic.recordAddition(_lpAddedBlock, poolId, lpOwner, params);
    }

    function _enforceJITGuardOnRemove(PoolId poolId, address lpOwner, ModifyLiquidityParams calldata params)
        internal
        view
    {
        JITGuardLogic.enforceOnRemove(_jitConfigs, _lpAddedBlock, poolId, lpOwner, params);
    }
}
