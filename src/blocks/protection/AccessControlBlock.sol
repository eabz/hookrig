// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";
import {IHookRigOrchestrator} from "../../interfaces/IHookRigOrchestrator.sol";
import {HookRigBase} from "../../base/HookRigBase.sol";
import {IMsgSender} from "../../interfaces/IMsgSender.sol";
import {HookPermissionMasks} from "../../libraries/HookPermissionMasks.sol";

library AccessControlLogic {
    using LPFeeLibrary for uint24;

    event AllowlistUpdated(PoolId indexed poolId, address indexed account, bool allowed);
    event MerkleRootUpdated(PoolId indexed poolId, bytes32 newMerkleRoot);
    event PoolStackConfigured(
        PoolId indexed poolId,
        IHookRigBlock.PresetId indexed presetId,
        uint32 enabledBlocksBitmap,
        address indexed admin
    );
    event ClaimWithdrawn(PoolId indexed poolId, Currency indexed currency, address indexed beneficiary, uint256 amount);

    error AccountNotAllowlisted(PoolId poolId, address account);
    error UnauthorizedAccessControlManager(address caller);

    function checkValidTier3Bitmap(uint32 bitmap) external pure returns (bool) {
        return HookPermissionMasks.isValidTier3Bitmap(bitmap);
    }

    function resolveBitmap(IHookRigBlock.PresetId presetId, uint32 enabledBlocksBitmap)
        public
        pure
        returns (uint32 bitmap)
    {
        bitmap = presetId == IHookRigBlock.PresetId.Blank
            ? enabledBlocksBitmap
            : (HookPermissionMasks.getPresetBitmap(presetId) | enabledBlocksBitmap);
    }

    function initPoolMeta(
        mapping(PoolId => HookRigBase.PoolRuntimeMeta) storage poolMeta,
        IPoolManager poolManager,
        PoolId poolId,
        uint24 keyFee,
        Currency currency0,
        Currency currency1,
        IHookRigBlock.PoolStackConfig calldata config,
        address launchpadFactory
    ) external returns (uint32 bitmap, address admin) {
        HookRigBase.PoolRuntimeMeta storage meta = poolMeta[poolId];
        if (meta.configured) revert IHookRigOrchestrator.PoolAlreadyConfigured(poolId);

        bool isLaunchpad = config.authorizedCurve != address(0);
        if (isLaunchpad && msg.sender != launchpadFactory) {
            revert HookRigBase.OnlyLaunchpadFactory(msg.sender);
        }

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtPriceX96 != 0) revert IHookRigOrchestrator.PoolAlreadyInitialized(poolId);

        bitmap = resolveBitmap(config.presetId, config.enabledBlocksBitmap);
        if ((bitmap & HookPermissionMasks.FEE_BLOCKS_MASK) != 0 && !keyFee.isDynamicFee()) {
            revert IHookRigOrchestrator.DynamicFeeFlagRequired();
        }

        admin = config.poolAdmin != address(0) ? config.poolAdmin : msg.sender;
        meta.presetId = config.presetId;
        meta.enabledBlocksBitmap = bitmap;
        meta.isToken0ProjectToken = config.isToken0ProjectToken;
        meta.configured = true;
        meta.isLaunchpadPool = isLaunchpad;
        meta.launchpadGraduated = false;
        meta.authorizedCurve = config.authorizedCurve;
        meta.poolAdmin = admin;
        meta.projectCurrency = config.isToken0ProjectToken ? currency0 : currency1;

        emit PoolStackConfigured(poolId, config.presetId, bitmap, admin);
    }

    function validateWithdrawClaim(
        mapping(PoolId => mapping(Currency => mapping(address => uint256))) storage poolClaims,
        PoolId poolId,
        Currency currency,
        uint256 amount
    ) external returns (uint256 withdrawAmount) {
        uint256 available = poolClaims[poolId][currency][msg.sender];
        withdrawAmount = amount == 0 ? available : amount;
        if (withdrawAmount == 0 || withdrawAmount > available) {
            revert IHookRigOrchestrator.InsufficientClaimBalance(amount, available);
        }
        unchecked {
            poolClaims[poolId][currency][msg.sender] = available - withdrawAmount;
        }
        emit ClaimWithdrawn(poolId, currency, msg.sender, withdrawAmount);
    }

    function init(
        mapping(PoolId => IHookRigBlock.AccessControlParams) storage configs,
        PoolId poolId,
        IHookRigBlock.AccessControlParams calldata params,
        address fallbackAdmin
    ) external {
        IHookRigBlock.AccessControlParams storage cfg = configs[poolId];
        cfg.checkBeforeAddLiquidity = params.checkBeforeAddLiquidity;
        cfg.checkBeforeSwap = params.checkBeforeSwap;
        cfg.merkleRoot = params.merkleRoot;
        cfg.manager = params.manager != address(0) ? params.manager : fallbackAdmin;
    }

    function setAllowlist(
        mapping(PoolId => IHookRigBlock.AccessControlParams) storage configs,
        mapping(PoolId => mapping(address => bool)) storage allowlisted,
        PoolId poolId,
        address account,
        bool allowed
    ) external {
        if (msg.sender != configs[poolId].manager) revert UnauthorizedAccessControlManager(msg.sender);
        allowlisted[poolId][account] = allowed;
        emit AllowlistUpdated(poolId, account, allowed);
    }

    function setMerkleRoot(
        mapping(PoolId => IHookRigBlock.AccessControlParams) storage configs,
        PoolId poolId,
        bytes32 newRoot
    ) external {
        if (msg.sender != configs[poolId].manager) revert UnauthorizedAccessControlManager(msg.sender);
        configs[poolId].merkleRoot = newRoot;
        emit MerkleRootUpdated(poolId, newRoot);
    }

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
        if (root != bytes32(0)) {
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(user))));
            if (leaf == root) return;

            if (hookData.length >= 32) {
                bytes32 computedHash = leaf;
                uint256 count = hookData.length / 32;
                for (uint256 i = 0; i < count; i++) {
                    bytes32 proofElement = bytes32(hookData[i * 32:32 + i * 32]);
                    computedHash = computedHash < proofElement
                        ? keccak256(abi.encodePacked(computedHash, proofElement))
                        : keccak256(abi.encodePacked(proofElement, computedHash));
                }
                if (computedHash == root) return;
            }

            if (hookData.length >= 64) {
                bytes32 computedHash = leaf;
                uint256 count = (hookData.length - 32) / 32;
                for (uint256 i = 0; i < count; i++) {
                    bytes32 proofElement = bytes32(hookData[32 + i * 32:64 + i * 32]);
                    computedHash = computedHash < proofElement
                        ? keccak256(abi.encodePacked(computedHash, proofElement))
                        : keccak256(abi.encodePacked(proofElement, computedHash));
                }
                if (computedHash == root) return;
            }
        }

        revert AccountNotAllowlisted(poolId, user);
    }

    function resolveUser(
        mapping(address => bool) storage isTrustedRouter,
        address routerSender,
        bytes calldata hookData
    ) external view returns (address user) {
        if (isTrustedRouter[routerSender]) {
            try IMsgSender(routerSender).msgSender() returns (address resolved) {
                return resolved != address(0) ? resolved : routerSender;
            } catch {
                if (hookData.length >= 32) {
                    user = abi.decode(hookData[:32], (address));
                    if (user != address(0)) return user;
                }
            }
        }
        return routerSender;
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

    function _initAccessControl(PoolId poolId, AccessControlParams calldata params, address fallbackAdmin) internal {
        AccessControlLogic.init(_accessConfigs, poolId, params, fallbackAdmin);
    }

    function setAllowlistAccount(PoolId poolId, address account, bool allowed) external {
        AccessControlLogic.setAllowlist(_accessConfigs, isAccountAllowlisted, poolId, account, allowed);
    }

    function setAccessMerkleRoot(PoolId poolId, bytes32 newRoot) external {
        AccessControlLogic.setMerkleRoot(_accessConfigs, poolId, newRoot);
    }

    function _verifyAccess(PoolId poolId, address user, bytes calldata hookData, bool isAddLiquidity) internal view {
        AccessControlLogic.verifyAccess(_accessConfigs, isAccountAllowlisted, poolId, user, hookData, isAddLiquidity);
    }
}
