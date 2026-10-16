// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
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
    error TokenNotDeployed();
    error OneSidedLiquidityNotAllowed(PoolId poolId, int24 currentTick, int24 tickLower, int24 tickUpper);
    error UnauthorizedAccessControlManager(address caller);
    error UnauthorizedPoolInitializer(address caller, address expectedAdmin);

    /// @notice Validates that `sender` is authorized to initialize a registered pool (`S4-F02`).
    /// @dev Launchpad pools require `sender == authorizedCurve` (or `orchestratorOwner` / factory when passed).
    ///      Standard registered pools (`poolAdmin != address(0)`) require `sender == poolAdmin || sender == orchestratorOwner`,
    ///      blocking third-party front-running of `PoolManager.initialize` with a manipulated starting `sqrtPriceX96`.
    function verifyInitializer(
        address sender,
        address poolAdmin,
        address orchestratorOwner,
        bool isLaunchpadPool,
        address authorizedCurve
    ) external pure {
        if (isLaunchpadPool) {
            if (sender != authorizedCurve && sender != orchestratorOwner) {
                revert IHookRigOrchestrator.UnauthorizedPoolInitializer(sender);
            }
        } else if (poolAdmin != address(0) && sender != poolAdmin && sender != orchestratorOwner) {
            revert IHookRigOrchestrator.UnauthorizedPoolInitializer(sender);
        }
    }

    function checkValidTier3Bitmap(uint32 bitmap) external pure returns (bool) {
        return HookPermissionMasks.isValidTier3Bitmap(bitmap);
    }

    /// @notice Rejects bitmaps whose blocks need a callback the hook address does not enable, so no block is
    ///         registered on a preset hook that PoolManager would never call for it.
    function validateBitmapAndPermissions(uint32 bitmap, uint160 hookAddr) external pure {
        if (!HookPermissionMasks.isValidTier3Bitmap(bitmap)) {
            revert IHookRigOrchestrator.InvalidBlockBitmap(bitmap);
        }
        uint160 required = _permissionFlags(HookPermissionMasks.permissionsForBitmap(bitmap));
        if ((hookAddr & required) != required) {
            revert IHookRigOrchestrator.InvalidBlockBitmap(bitmap);
        }
    }

    function _permissionFlags(Hooks.Permissions memory p) private pure returns (uint160 flags) {
        if (p.beforeInitialize) flags |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (p.afterInitialize) flags |= Hooks.AFTER_INITIALIZE_FLAG;
        if (p.beforeAddLiquidity) flags |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (p.beforeRemoveLiquidity) flags |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (p.beforeSwap) flags |= Hooks.BEFORE_SWAP_FLAG;
        if (p.afterSwap) flags |= Hooks.AFTER_SWAP_FLAG;
        if (p.afterSwapReturnDelta) flags |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }

    function resolveBitmap(IHookRigBlock.PresetId presetId, uint32 enabledBlocksBitmap)
        internal
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
        if (
            !isLaunchpad && config.poolAdmin != address(0) && msg.sender != config.poolAdmin
                && msg.sender != launchpadFactory
        ) {
            revert HookRigBase.OnlyPoolAdmin(msg.sender);
        }

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtPriceX96 != 0) revert IHookRigOrchestrator.PoolAlreadyInitialized(poolId);
        // Both tokens must already exist: otherwise anyone can pre-register the pool of a predicted launch token,
        // take its admin role and make the launch revert.
        if (_isUndeployedToken(currency0) || _isUndeployedToken(currency1)) {
            revert TokenNotDeployed();
        }

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

    function _isUndeployedToken(Currency currency) private view returns (bool) {
        return !currency.isAddressZero() && Currency.unwrap(currency).code.length == 0;
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

    function _isTrustedRouter(address account) private view returns (bool) {
        (bool ok, bytes memory data) =
            address(this).staticcall(abi.encodeWithSignature("isTrustedRouter(address)", account));
        return ok && data.length >= 32 && abi.decode(data, (bool));
    }

    function verifyAccess(
        mapping(PoolId => IHookRigBlock.AccessControlParams) storage configs,
        mapping(PoolId => mapping(address => bool)) storage allowlisted,
        PoolId poolId,
        address user,
        bytes calldata hookData,
        bool isAddLiquidity
    ) public view {
        IHookRigBlock.AccessControlParams storage cfg = configs[poolId];
        if (isAddLiquidity && !cfg.checkBeforeAddLiquidity) return;
        if (!isAddLiquidity && !cfg.checkBeforeSwap) return;

        if (_isTrustedRouter(user)) {
            revert AccountNotAllowlisted(poolId, user);
        }

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

    /// @notice Verifies pool access while rejecting self-attributed router callers (`sender == user` when
    ///         `isTrustedSender` is true, or when an untrusted contract caller attempts to use a shared router
    ///         identity) (`S4-L01`).
    function verifyAccess(
        mapping(PoolId => IHookRigBlock.AccessControlParams) storage configs,
        mapping(PoolId => mapping(address => bool)) storage allowlisted,
        PoolId poolId,
        address sender,
        address user,
        bytes calldata hookData,
        bool isAddLiquidity
    ) external view {
        IHookRigBlock.AccessControlParams storage cfg = configs[poolId];
        if (isAddLiquidity && !cfg.checkBeforeAddLiquidity) return;
        if (!isAddLiquidity && !cfg.checkBeforeSwap) return;

        if (sender == user) {
            revert AccountNotAllowlisted(poolId, user);
        }

        verifyAccess(configs, allowlisted, poolId, user, hookData, isAddLiquidity);
    }

    /// @notice Verifies pool access with explicit trusted-sender flag (`S4-L01`): prevents a trusted router whose
    ///         `msgSender()` returns itself (`sender == user && isTrustedSender`) from acting as a shared allowlist identity.
    function verifyAccess(
        mapping(PoolId => IHookRigBlock.AccessControlParams) storage configs,
        mapping(PoolId => mapping(address => bool)) storage allowlisted,
        PoolId poolId,
        address sender,
        address user,
        bool isTrustedSender,
        bytes calldata hookData,
        bool isAddLiquidity
    ) external view {
        IHookRigBlock.AccessControlParams storage cfg = configs[poolId];
        if (isAddLiquidity && !cfg.checkBeforeAddLiquidity) return;
        if (!isAddLiquidity && !cfg.checkBeforeSwap) return;

        if (sender == user && isTrustedSender) {
            revert AccountNotAllowlisted(poolId, user);
        }

        verifyAccess(configs, allowlisted, poolId, user, hookData, isAddLiquidity);
    }

    /// @notice Rejects liquidity adds whose range excludes the current tick on pools with per-wallet caps:
    ///         a one-sided position is a range order that buys or sells without a swap, skipping the caps and cuts.
    function enforceTwoSidedLiquidity(IPoolManager manager, PoolId poolId, ModifyLiquidityParams calldata params)
        external
        view
    {
        if (params.liquidityDelta <= 0) return;
        (, int24 tick,,) = StateLibrary.getSlot0(manager, poolId);
        if (tick < params.tickLower || tick >= params.tickUpper) {
            revert OneSidedLiquidityNotAllowed(poolId, tick, params.tickLower, params.tickUpper);
        }
    }

    function resolveUser(mapping(address => bool) storage isTrustedRouter, address routerSender, bytes calldata)
        external
        view
        returns (address user)
    {
        if (isTrustedRouter[routerSender]) {
            try IMsgSender(routerSender).msgSender() returns (address resolved) {
                return resolved != address(0) ? resolved : routerSender;
            } catch {
                return routerSender;
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

    function _verifyAccess(PoolId poolId, address sender, address user, bytes calldata hookData, bool isAddLiquidity)
        internal
        view
    {
        AccessControlLogic.verifyAccess(
            _accessConfigs, isAccountAllowlisted, poolId, sender, user, hookData, isAddLiquidity
        );
    }

    function _verifyAccess(
        PoolId poolId,
        address sender,
        address user,
        bool isTrustedSender,
        bytes calldata hookData,
        bool isAddLiquidity
    ) internal view {
        AccessControlLogic.verifyAccess(
            _accessConfigs, isAccountAllowlisted, poolId, sender, user, isTrustedSender, hookData, isAddLiquidity
        );
    }
}
