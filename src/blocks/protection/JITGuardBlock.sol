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
        address sender,
        address lpOwner,
        ModifyLiquidityParams calldata params
    ) external {
        bytes32 senderKey = (params.salt == bytes32(0) && lpOwner != sender)
            ? keccak256(abi.encodePacked(sender, lpOwner, params.tickLower, params.tickUpper, params.salt))
            : keccak256(abi.encodePacked(sender, params.tickLower, params.tickUpper, params.salt));
        lpAddedBlock[poolId][senderKey] = uint32(block.number);
        if (lpOwner != sender) {
            bytes32 userKey = keccak256(abi.encodePacked(lpOwner, params.tickLower, params.tickUpper, params.salt));
            lpAddedBlock[poolId][userKey] = uint32(block.number);
        }
    }

    function _trackAddKey(
        mapping(PoolId => mapping(bytes32 => uint32)) storage lpAddedBlock,
        mapping(PoolId => mapping(bytes32 => uint256)) storage lpTrackedLiquidity,
        PoolId poolId,
        bytes32 key,
        uint256 addedLiq,
        bool allowDustSkip
    ) private {
        uint256 existing = lpTrackedLiquidity[poolId][key];
        bool isDust = allowDustSkip && existing > 0 && addedLiq <= type(uint256).max / 20 && addedLiq * 20 < existing;
        if (!isDust) {
            lpAddedBlock[poolId][key] = uint32(block.number);
        }
        lpTrackedLiquidity[poolId][key] = existing + addedLiq;
    }

    function _decrementKey(
        mapping(PoolId => mapping(bytes32 => uint256)) storage lpTrackedLiquidity,
        PoolId poolId,
        bytes32 key,
        uint256 removedLiq
    ) private {
        uint256 tracked = lpTrackedLiquidity[poolId][key];
        lpTrackedLiquidity[poolId][key] = tracked >= removedLiq ? tracked - removedLiq : 0;
    }

    /// @notice Records an LP addition with per-owner and per-position liquidity tracking (`S4-F08`) and
    ///         a 5% anti-griefing dust floor on shared default-salt positions (`S2-F41`).
    function recordAddition(
        mapping(PoolId => mapping(bytes32 => uint32)) storage lpAddedBlock,
        mapping(PoolId => mapping(bytes32 => uint256)) storage lpTrackedLiquidity,
        PoolId poolId,
        address sender,
        address lpOwner,
        ModifyLiquidityParams calldata params
    ) external {
        uint256 addedLiq = params.liquidityDelta > 0 ? uint256(params.liquidityDelta) : 0;
        if (addedLiq == 0) return;

        bool zeroSalt = params.salt == bytes32(0);
        bytes32 posKey = keccak256(abi.encodePacked(sender, params.tickLower, params.tickUpper, params.salt));
        bytes32 ownerKey = keccak256(abi.encodePacked(sender, lpOwner, params.tickLower, params.tickUpper, params.salt));

        _trackAddKey(lpAddedBlock, lpTrackedLiquidity, poolId, ownerKey, addedLiq, zeroSalt);
        _trackAddKey(lpAddedBlock, lpTrackedLiquidity, poolId, posKey, addedLiq, zeroSalt);

        if (lpOwner != sender) {
            bytes32 userKey = keccak256(abi.encodePacked(lpOwner, params.tickLower, params.tickUpper, params.salt));
            _trackAddKey(lpAddedBlock, lpTrackedLiquidity, poolId, userKey, addedLiq, zeroSalt);
        }
    }

    function enforceOnRemove(
        mapping(PoolId => JITConfig) storage configs,
        mapping(PoolId => mapping(bytes32 => uint32)) storage lpAddedBlock,
        PoolId poolId,
        address sender,
        address lpOwner,
        ModifyLiquidityParams calldata params
    ) external view {
        JITConfig storage cfg = configs[poolId];
        uint32 minHold = cfg.minLPHoldBlocks > 0 ? cfg.minLPHoldBlocks : (cfg.jitExitPenaltyBps > 0 ? 1 : 0);
        if (minHold == 0) return;

        bytes32 senderKey = (params.salt == bytes32(0) && lpOwner != sender)
            ? keccak256(abi.encodePacked(sender, lpOwner, params.tickLower, params.tickUpper, params.salt))
            : keccak256(abi.encodePacked(sender, params.tickLower, params.tickUpper, params.salt));
        uint32 addedBlock = lpAddedBlock[poolId][senderKey];
        if (lpOwner != sender) {
            bytes32 userKey = keccak256(abi.encodePacked(lpOwner, params.tickLower, params.tickUpper, params.salt));
            uint32 userAdded = lpAddedBlock[poolId][userKey];
            if (userAdded > addedBlock) {
                addedBlock = userAdded;
            }
        }
        if (addedBlock > 0 && block.number < uint256(addedBlock) + uint256(minHold)) {
            revert JITLiquidityCooldownActive(addedBlock, uint32(block.number), minHold);
        }
    }

    /// @notice Enforces minimum LP hold blocks on liquidity removal (`S4-F08`, `S2-F41`, `S3-F58`).
    /// @dev When `lpOwner != sender` and `salt == 0`, an LP with sufficient `lpTrackedLiquidity[poolId][ownerKey]`
    ///      uses their isolated `ownerKey` timer (`test_Regression03`). If `lpTrackedLiquidity[poolId][ownerKey] < removedLiq`,
    ///      the caller is attempting to remove liquidity added under a different account (`S4-F08`), so `posKey` is enforced.
    function enforceOnRemove(
        mapping(PoolId => JITConfig) storage configs,
        mapping(PoolId => mapping(bytes32 => uint32)) storage lpAddedBlock,
        mapping(PoolId => mapping(bytes32 => uint256)) storage lpTrackedLiquidity,
        PoolId poolId,
        address sender,
        address lpOwner,
        ModifyLiquidityParams calldata params
    ) external {
        uint32 minHold;
        {
            JITConfig storage cfg = configs[poolId];
            minHold = cfg.minLPHoldBlocks > 0 ? cfg.minLPHoldBlocks : (cfg.jitExitPenaltyBps > 0 ? 1 : 0);
        }

        uint256 removedLiq = params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : 0;
        bytes32 posKey = keccak256(abi.encodePacked(sender, params.tickLower, params.tickUpper, params.salt));
        bytes32 ownerKey = keccak256(abi.encodePacked(sender, lpOwner, params.tickLower, params.tickUpper, params.salt));
        uint256 ownerTracked = lpTrackedLiquidity[poolId][ownerKey];

        if (minHold > 0) {
            uint32 addedBlock;
            if (params.salt == bytes32(0) && lpOwner != sender && removedLiq > 0 && ownerTracked >= removedLiq) {
                addedBlock = lpAddedBlock[poolId][ownerKey];
            } else {
                addedBlock = lpAddedBlock[poolId][posKey];
                uint32 ownerAdded = lpAddedBlock[poolId][ownerKey];
                if (ownerAdded > addedBlock) {
                    addedBlock = ownerAdded;
                }
                if (lpOwner != sender) {
                    bytes32 userKey =
                        keccak256(abi.encodePacked(lpOwner, params.tickLower, params.tickUpper, params.salt));
                    uint32 userAdded = lpAddedBlock[poolId][userKey];
                    if (userAdded > addedBlock) {
                        addedBlock = userAdded;
                    }
                }
            }
            if (addedBlock > 0 && block.number < uint256(addedBlock) + uint256(minHold)) {
                revert JITLiquidityCooldownActive(addedBlock, uint32(block.number), minHold);
            }
        }

        if (removedLiq > 0) {
            _decrementKey(lpTrackedLiquidity, poolId, ownerKey, removedLiq);
            _decrementKey(lpTrackedLiquidity, poolId, posKey, removedLiq);
            if (lpOwner != sender) {
                bytes32 userKey = keccak256(abi.encodePacked(lpOwner, params.tickLower, params.tickUpper, params.salt));
                _decrementKey(lpTrackedLiquidity, poolId, userKey, removedLiq);
            }
        }
    }
}

/// @title JITGuardBlock
/// @notice Group 2 (Protection & Access) — Expansion Block #18: Just-In-Time (JIT) Liquidity Guard
///         (`beforeAddLiquidity`, `beforeRemoveLiquidity`).
/// @dev Trust Level: Low (prevents single-block JIT liquidity attacks that dilute LP rewards / Arb recapture donations).
///      Note (`S3-F58`): Because Uniswap v4 `beforeRemoveLiquidity` does not return a `BalanceDelta`
///      (`afterRemoveLiquidityReturnDelta == false`), `jitExitPenaltyBps > 0` acts as a minimum 1-block hold
///      enforcement flag/floor when `minLPHoldBlocks == 0`, reverting same-block JIT exits rather than deducting a fee.
abstract contract JITGuardBlock is IHookRigBlock {
    mapping(PoolId poolId => JITGuardLogic.JITConfig config) internal _jitConfigs;
    mapping(PoolId poolId => mapping(bytes32 positionKey => uint32 addedAtBlock)) internal _lpAddedBlock;
    mapping(PoolId poolId => mapping(bytes32 key => uint256 trackedLiquidity)) public lpTrackedLiquidity;

    uint32 internal constant MAX_LP_HOLD_BLOCKS = 7200; // ~24h ceiling so LPs can never be permanently locked
    uint16 internal constant MAX_JIT_PENALTY_BPS = 5000; // 50.00%

    function lpAddedBlock(PoolId poolId, bytes32 positionKey) external view returns (uint32) {
        return _lpAddedBlock[poolId][positionKey];
    }

    function _initJITGuard(PoolId poolId, uint32 minLPHoldBlocks, uint16 jitExitPenaltyBps) internal {
        if (minLPHoldBlocks > MAX_LP_HOLD_BLOCKS || jitExitPenaltyBps > MAX_JIT_PENALTY_BPS) {
            revert JITGuardLogic.InvalidJITGuardConfig(minLPHoldBlocks, jitExitPenaltyBps);
        }
        _jitConfigs[poolId] =
            JITGuardLogic.JITConfig({minLPHoldBlocks: minLPHoldBlocks, jitExitPenaltyBps: jitExitPenaltyBps});
    }

    function _recordLPAddition(PoolId poolId, address sender, address lpOwner, ModifyLiquidityParams calldata params)
        internal
    {
        JITGuardLogic.recordAddition(_lpAddedBlock, lpTrackedLiquidity, poolId, sender, lpOwner, params);
    }

    function _enforceJITGuardOnRemove(
        PoolId poolId,
        address sender,
        address lpOwner,
        ModifyLiquidityParams calldata params
    ) internal {
        JITGuardLogic.enforceOnRemove(_jitConfigs, _lpAddedBlock, lpTrackedLiquidity, poolId, sender, lpOwner, params);
    }
}
