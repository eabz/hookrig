// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library AccessControlLogic {
    error AccountNotAllowlisted(PoolId poolId, address account);

    function verifyAccess(
        mapping(PoolId => IHookRigBlock.AccessControlParams) storage configs,
        mapping(PoolId => mapping(address => bool)) storage allowlisted,
        PoolId poolId,
        address user,
        bytes calldata hookData,
        bool isAddLiquidity
    ) external view {
        IHookRigBlock.AccessControlParams storage cfg = configs[poolId];
        if (isAddLiquidity && !cfg.checkBeforeAddLiquidity) return;
        if (!isAddLiquidity && !cfg.checkBeforeSwap) return;

        if (allowlisted[poolId][user]) return;

        bytes32 root = cfg.merkleRoot;
        if (root != bytes32(0) && hookData.length >= 32) {
            bytes32 computedHash = keccak256(bytes.concat(keccak256(abi.encode(user))));
            uint256 count = (hookData.length - 32) / 32;
            for (uint256 i = 0; i < count; i++) {
                bytes32 proofElement = bytes32(hookData[32 + i * 32:64 + i * 32]);
                computedHash = computedHash < proofElement
                    ? keccak256(abi.encodePacked(computedHash, proofElement))
                    : keccak256(abi.encodePacked(proofElement, computedHash));
            }
            if (computedHash == root) return;
        }

        revert AccountNotAllowlisted(poolId, user);
    }
}

/// @title AccessControlBlock
/// @notice Group 2 (Protection & Access) — Block #7: Allowlist and Merkle root access control
///         for `beforeAddLiquidity` and/or `beforeSwap`.
/// @dev Trust Level: Medium (NEVER applied to `beforeRemoveLiquidity`, guaranteeing LPs can always exit).
abstract contract AccessControlBlock is IHookRigBlock {
    mapping(PoolId poolId => AccessControlParams config) internal _accessConfigs;
    mapping(PoolId poolId => mapping(address account => bool allowed)) public isAccountAllowlisted;

    event AllowlistUpdated(PoolId indexed poolId, address indexed account, bool allowed);
    event MerkleRootUpdated(PoolId indexed poolId, bytes32 newMerkleRoot);

    error UnauthorizedAccessControlManager(address caller);

    function _initAccessControl(PoolId poolId, AccessControlParams memory params) internal {
        _accessConfigs[poolId] = params;
    }

    function setAllowlistAccount(PoolId poolId, address account, bool allowed) external {
        if (msg.sender != _accessConfigs[poolId].manager) revert UnauthorizedAccessControlManager(msg.sender);
        isAccountAllowlisted[poolId][account] = allowed;
        emit AllowlistUpdated(poolId, account, allowed);
    }

    function setAccessMerkleRoot(PoolId poolId, bytes32 newRoot) external {
        if (msg.sender != _accessConfigs[poolId].manager) revert UnauthorizedAccessControlManager(msg.sender);
        _accessConfigs[poolId].merkleRoot = newRoot;
        emit MerkleRootUpdated(poolId, newRoot);
    }

    function _verifyAccess(PoolId poolId, address user, bytes calldata hookData, bool isAddLiquidity) internal view {
        AccessControlLogic.verifyAccess(_accessConfigs, isAccountAllowlisted, poolId, user, hookData, isAddLiquidity);
    }
}
