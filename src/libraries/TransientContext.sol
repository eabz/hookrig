// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title TransientContext
/// @notice EIP-1153 transient storage manager for per-PoolId pre-swap snapshots and recursive self-swap guards.
library TransientContext {
    bytes32 private constant SNAPSHOT_NAMESPACE = keccak256("hookrig.transient.swapSnapshot.v1");
    bytes32 private constant INTERNAL_EXEC_NAMESPACE = keccak256("hookrig.transient.internalExec.v1");

    struct PreSwapSnapshot {
        uint160 sqrtPriceX96;
        int24 tick;
        uint32 blockNumber;
        bool active;
    }

    function storePreSwapSnapshot(PoolId poolId, uint160 sqrtPriceX96, int24 tick) internal {
        bytes32 slot = keccak256(abi.encodePacked(SNAPSHOT_NAMESPACE, PoolId.unwrap(poolId)));
        uint256 packed = uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160) | (uint256(uint32(block.number)) << 184)
            | (uint256(1) << 216);
        assembly ("memory-safe") {
            tstore(slot, packed)
        }
    }

    function loadAndClearPreSwapSnapshot(PoolId poolId) internal returns (PreSwapSnapshot memory snap) {
        bytes32 slot = keccak256(abi.encodePacked(SNAPSHOT_NAMESPACE, PoolId.unwrap(poolId)));
        uint256 packed;
        assembly ("memory-safe") {
            packed := tload(slot)
            tstore(slot, 0)
        }
        snap.sqrtPriceX96 = uint160(packed);
        snap.tick = int24(uint24(packed >> 160));
        snap.blockNumber = uint32(packed >> 184);
        snap.active = ((packed >> 216) & 1) == 1;
    }

    function setInternalHookExecution(PoolId poolId, bool active) internal {
        bytes32 slot = keccak256(abi.encodePacked(INTERNAL_EXEC_NAMESPACE, PoolId.unwrap(poolId)));
        uint256 val = active ? 1 : 0;
        assembly ("memory-safe") {
            tstore(slot, val)
        }
    }

    function isInternalHookExecution(PoolId poolId) internal view returns (bool active) {
        bytes32 slot = keccak256(abi.encodePacked(INTERNAL_EXEC_NAMESPACE, PoolId.unwrap(poolId)));
        uint256 val;
        assembly ("memory-safe") {
            val := tload(slot)
        }
        active = (val == 1);
    }
}
