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
import {MEVProtectionBlock} from "./blocks/protection/MEVProtectionBlock.sol";
import {AccessControlBlock} from "./blocks/protection/AccessControlBlock.sol";
import {CircuitBreakerBlock} from "./blocks/protection/CircuitBreakerBlock.sol";
import {WalletCapBlock} from "./blocks/token-rules/WalletCapBlock.sol";
import {SwapRewardsBlock} from "./blocks/rewards/SwapRewardsBlock.sol";
import {LimitOrdersBlock} from "./blocks/trading/LimitOrdersBlock.sol";
import {TWAMMBlock} from "./blocks/trading/TWAMMBlock.sol";
import {OracleBlock} from "./blocks/trading/OracleBlock.sol";

/// @title HookRigOrchestrator
/// @notice Composable Uniswap v4 Hook Orchestrator uniting all 17 core blocks (+ expansion blocks) and 12 presets.
/// @dev Enforces deterministic callback ordering (`docs/03-hooks-flow.md`) and security invariants (`docs/04-security-mechanics-and-caveats.md`).
contract HookRigOrchestrator is
    HookRigBase,
    FeeAggregator,
    AfterSwapDeltaAggregator,
    MEVProtectionBlock,
    AccessControlBlock,
    CircuitBreakerBlock,
    WalletCapBlock,
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

    /// @notice Registers a composable block stack or preset for a standard or launchpad Uniswap v4 pool.
    function registerPoolStack(PoolKey calldata key, PoolStackConfig calldata config) external override {
        PoolId poolId = key.toId();
        if (_poolMeta[poolId].configured) revert PoolAlreadyConfigured(poolId);
        bool isLaunchpad = config.authorizedCurve != address(0);
        if (isLaunchpad && msg.sender != launchpadFactory) {
            revert OnlyLaunchpadFactory(msg.sender);
        }
        _configurePoolStackInternal(key, poolId, config, isLaunchpad, config.authorizedCurve);
    }

    /// @notice Marks a launchpad pool as graduated and resets its Anti-snipe decay clock to `block.number`.
    function notifyPoolGraduated(PoolId poolId) external override {
        PoolRuntimeMeta storage meta = _poolMeta[poolId];
        if (msg.sender != meta.authorizedCurve && msg.sender != launchpadFactory) {
            revert OnlyAuthorizedCurve(msg.sender);
        }
        meta.launchpadGraduated = true;
        if ((meta.enabledBlocksBitmap & HookPermissionMasks.BIT_ANTI_SNIPE) != 0) {
            _resetAntiSnipeGraduationClock(poolId);
        }
    }

    function _configurePoolStackInternal(
        PoolKey calldata key,
        PoolId poolId,
        PoolStackConfig calldata config,
        bool isLaunchpad,
        address authorizedCurve
    ) internal {
        uint32 bitmap = config.presetId == PresetId.Blank
            ? config.enabledBlocksBitmap
            : HookPermissionMasks.getPresetBitmap(config.presetId);

        if (bitmap == 0) revert InvalidBlockBitmap(bitmap);

        if ((bitmap & HookPermissionMasks.FEE_BLOCKS_MASK) != 0 && !key.fee.isDynamicFee()) {
            revert DynamicFeeFlagRequired();
        }

        uint256 maxDeltaBps = _validateAggregateReturnDeltaBudget(config, bitmap);
        if (maxDeltaBps > MAX_AGGREGATE_AFTER_SWAP_BPS) {
            revert AggregateReturnDeltaBpsExceeded(maxDeltaBps, MAX_AGGREGATE_AFTER_SWAP_BPS);
        }

        address admin = config.poolAdmin != address(0) ? config.poolAdmin : msg.sender;
        _poolMeta[poolId] = PoolRuntimeMeta({
            presetId: config.presetId,
            enabledBlocksBitmap: bitmap,
            isToken0ProjectToken: config.isToken0ProjectToken,
            configured: true,
            isLaunchpadPool: isLaunchpad,
            launchpadGraduated: !isLaunchpad,
            authorizedCurve: authorizedCurve,
            poolAdmin: admin
        });

        if ((bitmap & HookPermissionMasks.BIT_DYNAMIC_FEE) != 0) {
            _stageDynamicFee(poolId, config.dynamicFee);
        }
        if ((bitmap & HookPermissionMasks.BIT_MANAGED_FEE) != 0) {
            _stageManagedFee(poolId, config.managedFee);
        }
        if ((bitmap & HookPermissionMasks.BIT_MARKET_HOURS_FEE) != 0) {
            _initMarketHoursFee(poolId, config.marketHoursFee);
        }
        if ((bitmap & HookPermissionMasks.BIT_ANTI_SNIPE) != 0) {
            _initAntiSnipe(poolId, config.antiSnipe);
        }
        if ((bitmap & (HookPermissionMasks.BIT_MEV_PROTECTION | HookPermissionMasks.BIT_JIT_GUARD)) != 0) {
            _initMEVProtection(poolId, config.mevProtection);
        }
        if ((bitmap & HookPermissionMasks.BIT_ARB_RECAPTURE) != 0) {
            _stageArbRecapture(poolId, config.arbRecapture);
        }
        if ((bitmap & HookPermissionMasks.BIT_ACCESS_CONTROL) != 0) {
            _initAccessControl(poolId, config.accessControl);
        }
        if ((bitmap & HookPermissionMasks.BIT_WALLET_CAP) != 0) {
            _initWalletCap(poolId, config.walletCap);
        }
        if ((bitmap & HookPermissionMasks.BIT_BUY_SELL_TAX) != 0) {
            _initBuySellTax(poolId, config.buySellTax);
        }
        if ((bitmap & HookPermissionMasks.BIT_AUTO_BURN) != 0) {
            _initAutoBurn(poolId, config.autoBurn);
        }
        if ((bitmap & HookPermissionMasks.BIT_FEE_SHARING) != 0) {
            _initFeeSharing(poolId, config.feeSharing);
        }
        if ((bitmap & HookPermissionMasks.BIT_LP_REWARDS) != 0) {
            _initLPRewards(poolId, config.lpRewards);
        }
        if ((bitmap & HookPermissionMasks.BIT_SWAP_REWARDS) != 0) {
            _initSwapRewards(poolId, config.swapRewards);
        }
        if ((bitmap & HookPermissionMasks.BIT_KING_OF_THE_POOL) != 0) {
            uint32 overrideDuration = (config.presetId == PresetId.WeeklyKingWithBuyRewards
                    && config.kingOfThePool.roundDurationSeconds == 0)
                ? uint32(168 hours)
                : 0;
            _initKingOfThePool(poolId, config.kingOfThePool, overrideDuration);
        }

        emit PoolStackConfigured(poolId, config.presetId, bitmap, admin);
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

        if ((bitmap & HookPermissionMasks.BIT_ORACLE) != 0) {
            _initOracle(poolId, tick);
        }
        if ((bitmap & HookPermissionMasks.BIT_TWAMM) != 0) {
            _initTWAMM(poolId);
        }
        if ((bitmap & HookPermissionMasks.BIT_LIMIT_ORDERS) != 0) {
            _initLimitOrders(poolId, tick);
        }
        if ((bitmap & HookPermissionMasks.BIT_DYNAMIC_FEE) != 0) {
            _anchorDynamicFeeTick(poolId, tick);
        }
        if ((bitmap & HookPermissionMasks.BIT_MANAGED_FEE) != 0) {
            _applyInitialManagedFee(poolManager, key, poolId);
        }
        if ((bitmap & HookPermissionMasks.BIT_ARB_RECAPTURE) != 0) {
            _anchorArbRecaptureTick(poolId, tick);
        }

        return IHooks.afterInitialize.selector;
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal virtual override returns (bytes4) {
        PoolId poolId = key.toId();
        uint32 bitmap = _poolMeta[poolId].enabledBlocksBitmap;
        address user = _resolveUser(sender, hookData);

        if ((bitmap & HookPermissionMasks.BIT_ACCESS_CONTROL) != 0) {
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

        if ((bitmap & (HookPermissionMasks.BIT_MEV_PROTECTION | HookPermissionMasks.BIT_JIT_GUARD)) != 0) {
            _recordLPAddition(poolId, user, params);
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
            _enforceJITGuardOnRemove(poolId, user, params);
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
        bool isToken0Project = _poolMeta[poolId].isToken0ProjectToken;

        TransientContext.PreSwapSnapshot memory snap = TransientContext.loadAndClearPreSwapSnapshot(poolId);
        (, int24 postTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        int24 preTick = snap.active ? snap.tick : postTick;

        if ((bitmap & HookPermissionMasks.BIT_MEV_PROTECTION) != 0) {
            _enforceMEVAfterSwap(poolId, preTick, postTick, params.zeroForOne);
        }
        if ((bitmap & HookPermissionMasks.BIT_CIRCUIT_BREAKER) != 0) {
            _checkAndAdvanceCircuitBreaker(poolId, preTick, postTick);
        }

        PoolTokenDir.SwapContext memory ctx = PoolTokenDir.resolveSwapContext(key, params, swapDelta, isToken0Project);
        ctx.trader = trader;
        ctx.preSwapTick = preTick;
        ctx.postSwapTick = postTick;

        uint256 totalCutAmount;
        (hookDeltaUnspecified, totalCutAmount) = _executeAfterSwapDeltaWaterfall(poolManager, key, poolId, bitmap, ctx);

        if ((bitmap & HookPermissionMasks.BIT_WALLET_CAP) != 0 && ctx.isBuy) {
            uint256 netTokensToBuyer = 0;
            if (ctx.isExactInput && ctx.grossUnspecifiedAmount > totalCutAmount) {
                netTokensToBuyer = ctx.grossUnspecifiedAmount - totalCutAmount;
            } else if (!ctx.isExactInput && params.amountSpecified > 0) {
                netTokensToBuyer = uint256(params.amountSpecified);
            }
            _enforceWalletCapAfterBuy(poolId, ctx.projectCurrency, ctx.trader, netTokensToBuyer);
        }

        if ((bitmap & HookPermissionMasks.BIT_SWAP_REWARDS) != 0) {
            _accrueSwapRewards(poolId, ctx.trader, ctx.grossUnspecifiedAmount);
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
        _claimKingPot(poolManager, poolId, roundId, to);
    }

    /// @notice Allows an authorized LaunchCurve to seed initial sniper surcharges into Round #1 King of the Pool pot.
    function seedKingPotFromLaunchCurve(PoolId poolId, Currency currency, uint256 amount) external {
        PoolRuntimeMeta storage meta = _poolMeta[poolId];
        if (msg.sender != meta.authorizedCurve && msg.sender != launchpadFactory) {
            revert OnlyAuthorizedCurve(msg.sender);
        }
        if (amount == 0) return;
        _kingStates[poolId].potCurrency = currency;
        _kingStates[poolId].currentPotAmount += amount;
    }

    function _creditClaimInternal(PoolId poolId, Currency currency, address beneficiary, uint256 amount)
        internal
        override
    {
        _creditPoolClaim(poolId, currency, beneficiary, amount);
    }

    function _updatePoolManagerDynamicFee(PoolKey calldata key, uint24 newFee) internal override {
        poolManager.updateDynamicLPFee(key, newFee);
    }
}
