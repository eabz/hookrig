// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookPermissionMasks} from "./libraries/HookPermissionMasks.sol";
import {PoolTokenDir} from "./libraries/PoolTokenDir.sol";
import {TransientContext} from "./libraries/TransientContext.sol";
import {HookRigBase} from "./base/HookRigBase.sol";
import {FeeAggregator} from "./base/FeeAggregator.sol";
import {AfterSwapDeltaAggregator} from "./base/AfterSwapDeltaAggregator.sol";
import {DynamicFeeLogic} from "./blocks/fees/DynamicFeeBlock.sol";
import {MEVProtectionBlock} from "./blocks/protection/MEVProtectionBlock.sol";
import {AccessControlBlock, AccessControlLogic} from "./blocks/protection/AccessControlBlock.sol";
import {AntiSnipeLogic} from "./blocks/protection/AntiSnipeBlock.sol";
import {CircuitBreakerBlock} from "./blocks/protection/CircuitBreakerBlock.sol";
import {BuySellTaxLogic} from "./blocks/token-rules/BuySellTaxBlock.sol";
import {WalletCapBlock} from "./blocks/token-rules/WalletCapBlock.sol";
import {VestingSellCapBlock} from "./blocks/token-rules/VestingSellCapBlock.sol";
import {SwapRewardsBlock} from "./blocks/rewards/SwapRewardsBlock.sol";
import {KingOfThePoolLogic} from "./blocks/rewards/KingOfThePoolBlock.sol";
import {LimitOrdersBlock} from "./blocks/trading/LimitOrdersBlock.sol";
import {TWAMMBlock} from "./blocks/trading/TWAMMBlock.sol";
import {OracleBlock, OracleLogic} from "./blocks/trading/OracleBlock.sol";

/// @title HookRigOrchestrator
/// @notice Composable Uniswap v4 Hook Orchestrator uniting all 17 core blocks, 5 expansion blocks, and 12 presets.
/// @dev Enforces deterministic callback ordering (`docs/03-hooks-flow.md`) and security invariants (`docs/04-security-mechanics-and-caveats.md`).
contract HookRigOrchestrator is
    HookRigBase,
    FeeAggregator,
    AfterSwapDeltaAggregator,
    MEVProtectionBlock,
    AccessControlBlock,
    CircuitBreakerBlock,
    WalletCapBlock,
    VestingSellCapBlock,
    SwapRewardsBlock,
    LimitOrdersBlock,
    TWAMMBlock,
    OracleBlock
{
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    constructor(IPoolManager _poolManager, address _initialOwner) HookRigBase(_poolManager, _initialOwner) {}

    /// @notice Returns the full callback permission flags supported by the HookRigOrchestrator.
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =========================================================================
    // Pool Configuration & Launchpad Registration
    // =========================================================================

    /// @notice Exposes Tier 3 bitmap compatibility check on the orchestrator.
    function isValidTier3Bitmap(uint32 bitmap) public pure override returns (bool) {
        return AccessControlLogic.checkValidTier3Bitmap(bitmap);
    }

    /// @notice Virtual internal hook for Tier 3 bitmap validation (allows fuzz harness synthetic bitmaps).
    function _validateBitmapCompatibility(uint32 bitmap) internal view virtual {
        if (!AccessControlLogic.checkValidTier3Bitmap(bitmap)) {
            revert InvalidBlockBitmap(bitmap);
        }
    }

    /// @notice Registers a composable block stack or preset for a standard or launchpad Uniswap v4 pool.
    function registerPoolStack(PoolKey calldata key, PoolStackConfig calldata config) external override {
        PoolId poolId = key.toId();
        (uint32 bitmap, address admin) = AccessControlLogic.initPoolMeta(
            _poolMeta, poolManager, poolId, key.fee, key.currency0, key.currency1, config, launchpadFactory
        );
        _validateBitmapCompatibility(bitmap);
        _configurePoolStackBlocks(poolId, config, bitmap, admin);
    }

    /// @notice Marks a launchpad pool as graduated and resets its Anti-snipe, WalletCap, and KingOfThePool clocks.
    function notifyPoolGraduated(PoolId poolId) external override {
        AntiSnipeLogic.resetGraduationClocks(
            _poolMeta, _antiSnipeStates, _walletCapStates, _kingStates, poolId, launchpadFactory, true
        );
    }

    function _configurePoolStackBlocks(PoolId poolId, PoolStackConfig calldata config, uint32 bitmap, address admin)
        internal
    {
        DynamicFeeLogic.initFeeAndProtectionBlocks(
            _dynamicFeeStates,
            _managedFeeStates,
            _marketHoursConfigs,
            _antiSnipeStates,
            _mevStates,
            _jitConfigs,
            _arbStates,
            poolId,
            config,
            bitmap,
            admin
        );
        BuySellTaxLogic.initRulesAndRewardsBlocks(
            _accessConfigs,
            _walletCapStates,
            _taxConfigs,
            _autoBurnConfigs,
            _feeSharingConfigs,
            _lpRewardsConfigs,
            _swapRewardsConfigs,
            poolId,
            config,
            bitmap,
            admin
        );
        KingOfThePoolLogic.initExpansionBlocks(
            _kingStates,
            _circuitBreakers,
            _referralConfigs,
            _vestingSellConfigs,
            _autoBuybackStates,
            poolId,
            config,
            bitmap
        );

        BuySellTaxLogic.validateTaxBudget(
            _poolMeta,
            _autoBurnConfigs,
            _feeSharingConfigs,
            _lpRewardsConfigs,
            _kingStates,
            _referralConfigs,
            _autoBuybackStates,
            poolId,
            config.buySellTax.buyTaxBps,
            config.buySellTax.sellTaxBps,
            _protocolRoyaltyBps(),
            false
        );
    }

    /// @notice Updates the Buy/Sell Tax configuration for `poolId` (callable only by `poolAdmin`),
    ///         re-verifying the directional `2500 bps` aggregate return-delta budget.
    function setBuySellTax(PoolId poolId, uint16 buyTaxBps, uint16 sellTaxBps, address taxRecipient) external override {
        BuySellTaxLogic.validateTaxBudget(
            _poolMeta,
            _autoBurnConfigs,
            _feeSharingConfigs,
            _lpRewardsConfigs,
            _kingStates,
            _referralConfigs,
            _autoBuybackStates,
            poolId,
            buyTaxBps,
            sellTaxBps,
            _protocolRoyaltyBps(),
            true
        );
        _updateBuySellTax(poolId, buyTaxBps, sellTaxBps, taxRecipient);
    }

    // =========================================================================
    // Uniswap v4 Hook Lifecycle Callbacks
    // =========================================================================

    function _beforeInitialize(address sender, PoolKey calldata key, uint160)
        internal
        virtual
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        PoolRuntimeMeta storage meta = _poolMeta[poolId];
        if (!meta.configured) {
            revert PoolNotConfigured(poolId);
        }

        if (meta.isLaunchpadPool && sender != meta.authorizedCurve && sender != launchpadFactory) {
            revert UnauthorizedPoolInitializer(sender);
        }

        if ((meta.enabledBlocksBitmap & HookPermissionMasks.BIT_TWAMM) != 0) {
            _validateTWAMMBeforeInitialize(key.tickSpacing);
        }

        return IHooks.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        virtual
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        uint32 bitmap = _poolMeta[poolId].enabledBlocksBitmap;

        AntiSnipeLogic.resetGraduationClocks(
            _poolMeta, _antiSnipeStates, _walletCapStates, _kingStates, poolId, launchpadFactory, false
        );

        OracleLogic.initAfterInitialize(
            _oracleObservations,
            _twammStates,
            _limitOrderLastTick,
            _dynamicFeeStates,
            _managedFeeStates,
            _arbStates,
            poolManager,
            key,
            bitmap,
            tick
        );

        return IHooks.afterInitialize.selector;
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal virtual override returns (bytes4) {
        PoolId poolId = key.toId();
        PoolRuntimeMeta storage meta = _poolMeta[poolId];
        uint32 bitmap = meta.enabledBlocksBitmap;
        address user = _resolveUser(sender, hookData);

        if (
            (bitmap & HookPermissionMasks.BIT_ACCESS_CONTROL) != 0
                && !(meta.isLaunchpadPool && sender == meta.authorizedCurve)
        ) {
            _verifyAccess(poolId, user, hookData, true);
        }

        if ((bitmap & (HookPermissionMasks.BIT_ORACLE | HookPermissionMasks.BIT_TWAMM)) != 0) {
            (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
            if ((bitmap & HookPermissionMasks.BIT_ORACLE) != 0) {
                _updateOracleCheckpoint(poolId, currentTick);
            }
            if ((bitmap & HookPermissionMasks.BIT_TWAMM) != 0) {
                _executePendingTWAMMOrders(poolId);
            }
        }

        if (
            (bitmap & (HookPermissionMasks.BIT_MEV_PROTECTION | HookPermissionMasks.BIT_JIT_GUARD)) != 0
                && !(meta.isLaunchpadPool && sender == meta.authorizedCurve)
        ) {
            _recordLPAddition(poolId, sender, user, params);
        }

        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal virtual override returns (bytes4) {
        PoolId poolId = key.toId();
        uint32 bitmap = _poolMeta[poolId].enabledBlocksBitmap;
        address user = _resolveUser(sender, hookData);

        if ((bitmap & HookPermissionMasks.BIT_ORACLE) != 0) {
            (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
            _updateOracleCheckpoint(poolId, currentTick);
        }

        if ((bitmap & (HookPermissionMasks.BIT_MEV_PROTECTION | HookPermissionMasks.BIT_JIT_GUARD)) != 0) {
            _enforceJITGuardOnRemove(poolId, sender, user, params);
        }

        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        if (TransientContext.isInternalHookExecution(poolId)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint32 bitmap = _poolMeta[poolId].enabledBlocksBitmap;
        address trader = _resolveUser(sender, hookData);

        if ((bitmap & HookPermissionMasks.BIT_ACCESS_CONTROL) != 0) {
            _verifyAccess(poolId, trader, hookData, false);
        }

        (uint160 preSqrtPriceX96, int24 preTick,,) = StateLibrary.getSlot0(poolManager, poolId);

        if ((bitmap & HookPermissionMasks.BIT_ORACLE) != 0) {
            _updateOracleCheckpoint(poolId, preTick);
        }
        if ((bitmap & HookPermissionMasks.BIT_TWAMM) != 0) {
            _executePendingTWAMMOrders(poolId);
        }

        TransientContext.storePreSwapSnapshot(poolId, preSqrtPriceX96, preTick);

        uint24 lpFeeOverride = _resolveBeforeSwapFee(poolId, bitmap, preTick);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeeOverride);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        if (TransientContext.isInternalHookExecution(poolId)) {
            return (IHooks.afterSwap.selector, 0);
        }

        int128 hookDeltaUnspecified =
            _runAfterSwapPipeline(poolId, _resolveUser(sender, hookData), key, params, swapDelta);
        return (IHooks.afterSwap.selector, hookDeltaUnspecified);
    }

    function _runAfterSwapPipeline(
        PoolId poolId,
        address trader,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta
    ) internal returns (int128 hookDeltaUnspecified) {
        uint32 bitmap = _poolMeta[poolId].enabledBlocksBitmap;
        PoolTokenDir.SwapContext memory ctx =
            PoolTokenDir.resolveSwapContext(key, params, swapDelta, _poolMeta[poolId].isToken0ProjectToken);
        ctx.trader = trader;
        {
            TransientContext.PreSwapSnapshot memory snap = TransientContext.loadAndClearPreSwapSnapshot(poolId);
            (, int24 postTick,,) = StateLibrary.getSlot0(poolManager, poolId);
            int24 preTick = snap.active ? snap.tick : postTick;

            if ((bitmap & HookPermissionMasks.BIT_MEV_PROTECTION) != 0) {
                _enforceMEVAfterSwap(poolId, preTick, postTick, params.zeroForOne);
            }
            if ((bitmap & HookPermissionMasks.BIT_CIRCUIT_BREAKER) != 0) {
                _checkAndAdvanceCircuitBreaker(poolId, preTick, postTick);
            }
            ctx.preSwapTick = preTick;
            ctx.postSwapTick = postTick;
        }

        uint256 totalCutAmount;
        (hookDeltaUnspecified, totalCutAmount) =
            _executeAfterSwapDeltaWaterfall(poolClaims, poolManager, key, poolId, bitmap, ctx);

        if ((bitmap & HookPermissionMasks.BIT_WALLET_CAP) != 0) {
            _enforceWalletCapAfterSwap(
                poolId,
                ctx.projectCurrency,
                ctx.trader,
                ctx.isBuy,
                ctx.isExactInput,
                ctx.grossUnspecifiedAmount,
                ctx.settledSpecifiedAmount,
                totalCutAmount
            );
        }

        if ((bitmap & HookPermissionMasks.BIT_VESTING_SELL_CAP) != 0 && !ctx.isBuy) {
            uint256 projectTokensSold =
                ctx.isExactInput ? ctx.settledSpecifiedAmount : (ctx.grossUnspecifiedAmount + totalCutAmount);
            _enforceVestingSellCap(poolId, ctx.projectCurrency, ctx.trader, projectTokensSold);
        }

        if ((bitmap & HookPermissionMasks.BIT_SWAP_REWARDS) != 0) {
            uint256 netRewardVolume =
                ctx.grossUnspecifiedAmount > totalCutAmount ? ctx.grossUnspecifiedAmount - totalCutAmount : 0;
            _accrueSwapRewards(poolId, ctx.trader, netRewardVolume);
        }

        if ((bitmap & HookPermissionMasks.BIT_LIMIT_ORDERS) != 0) {
            _processCrossedLimitOrderTicks(poolId, key.tickSpacing, ctx.postSwapTick);
        }
    }

    // =========================================================================
    // King of the Pool Pull Claim & Internal Bridge Overrides
    // =========================================================================

    /// @notice Pull-based jackpot claim for finalized King of the Pool rounds.
    function claimKingPot(PoolId poolId, uint64 roundId, address to) external nonReentrant {
        (Currency currency, uint256 reward) = _validateKingClaim(poolId, roundId);
        address recipient = to == address(0) ? msg.sender : to;
        _payoutERC6909Claim(currency, recipient, reward);
    }

    /// @notice Allows an authorized LaunchCurve to seed initial sniper surcharges into Round #1 King of the Pool pot
    ///         (or into `poolAdmin` ERC-6909 claims if `currency` is not the pool's project token).
    function seedKingPotFromLaunchCurve(PoolId poolId, Currency currency, uint256 amount) external override {
        KingOfThePoolLogic.seedPotFromLaunchCurve(
            _kingStates, _poolMeta, poolClaims, poolId, currency, amount, launchpadFactory, owner()
        );
    }

    function _protocolRoyaltyBps() internal view virtual override returns (uint16) {
        return PROTOCOL_ROYALTY_BPS;
    }

    function _protocolRoyaltyRecipient() internal view virtual override returns (address) {
        return PROTOCOL_ROYALTY_RECIPIENT;
    }

    function _updatePoolManagerDynamicFee(PoolKey calldata key, uint24 newFee) internal override {
        poolManager.updateDynamicLPFee(key, newFee);
    }
}
