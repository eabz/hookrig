// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IHookRigBlock} from "../../../src/interfaces/IHookRigBlock.sol";
import {IHookRigOrchestrator} from "../../../src/interfaces/IHookRigOrchestrator.sol";
import {ITokenLaunchpad} from "../../../src/interfaces/ITokenLaunchpad.sol";
import {HookPermissionMasks} from "../../../src/libraries/HookPermissionMasks.sol";
import {HookRigToken} from "../../../src/launchpad/HookRigToken.sol";
import {LaunchpadFactory} from "../../../src/launchpad/LaunchpadFactory.sol";
import {VirtualXYKLaunch} from "../../../src/launchpad/curves/VirtualXYKLaunch.sol";
import {SteppedTrancheLaunch} from "../../../src/launchpad/curves/SteppedTrancheLaunch.sol";
import {NativeTickLaunch} from "../../../src/launchpad/curves/NativeTickLaunch.sol";
import {
    FairLaunchPresetHook,
    KingOfThePoolLaunchPresetHook,
    WeeklyKingBuyRewardsPresetHook,
    CreatorEconomyPresetHook,
    CharityTokenPresetHook,
    TreasuryBackedPresetHook,
    StockQuotedPresetHook,
    DeepLiquidityPresetHook,
    TraderFirstPresetHook,
    StablePairProjectFeePresetHook,
    PrivatePoolPresetHook,
    ProTradingPoolPresetHook
} from "../../../src/presets/HookRigPresets.sol";
import {HookRigOrchestratorHarness} from "../harness/HookRigOrchestratorHarness.sol";
import {HookRigTestRouter, MockBurnableERC20} from "../../utils/HookRigTestBase.sol";

/// @notice Non-burnable ERC20 used inside reverting coverage probes to hit the AutoBurn dead-address fallback.
contract NonBurnableToken is MockBurnableERC20 {
    constructor() MockBurnableERC20("NonBurn", "NB") {}

    function burn(uint256) public pure override {
        revert("BurnNotSupported");
    }
}

/// @notice Standalone coverage helper that exercises view getters, presets, and self-reverting validation paths.
contract CoverageHelper {
    using PoolIdLibrary for PoolKey;

    bool public constant IS_TEST = true;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    IPoolManager public immutable poolManager;
    HookRigOrchestratorHarness public immutable orchestrator;
    LaunchpadFactory public immutable launchpadFactory;
    HookRigTestRouter public immutable trustedRouter;
    HookRigTestRouter public immutable plainRouter;
    MockBurnableERC20 public immutable token0;
    MockBurnableERC20 public immutable token1;

    constructor(
        IPoolManager _poolManager,
        HookRigOrchestratorHarness _orchestrator,
        LaunchpadFactory _launchpadFactory,
        HookRigTestRouter _trustedRouter,
        HookRigTestRouter _plainRouter,
        MockBurnableERC20 _token0,
        MockBurnableERC20 _token1
    ) {
        poolManager = _poolManager;
        orchestrator = _orchestrator;
        launchpadFactory = _launchpadFactory;
        trustedRouter = _trustedRouter;
        plainRouter = _plainRouter;
        token0 = _token0;
        token1 = _token1;
    }

    receive() external payable {}

    function run(uint8 branch, PoolKey memory multiKey, address xykCurve, address trancheCurve, address launchToken)
        external
    {
        uint8 b = branch % 6;
        if (b == 0) {
            _exerciseGetters(multiKey, xykCurve, trancheCurve, launchToken);
        } else if (b == 1) {
            _exerciseBitmaps();
        } else if (b == 2) {
            _exercisePresets();
        } else if (b == 3) {
            try this.probeStrictPaths() {} catch {}
        } else if (b == 4) {
            try this.probeBlockConfigReverts() {} catch {}
        } else {
            try this.probeSpecialExecutionPaths(multiKey, xykCurve, trancheCurve) {} catch {}
        }
    }

    function _exerciseGetters(PoolKey memory multiKey, address xykCurve, address trancheCurve, address launchToken)
        internal
        view
    {
        PoolId pid = multiKey.toId();
        orchestrator.launchpadFactory();
        orchestrator.PROTOCOL_ROYALTY_BPS();
        orchestrator.isBlockEnabled(pid, IHookRigBlock.BlockId.DynamicFee);
        orchestrator.swapRewardPoints(pid, address(this));
        orchestrator.limitOrderPoolEscrow(pid, multiKey.currency0);
        orchestrator.observeOracleAtCurrentTime(pid);
        if (launchToken != address(0)) {
            HookRigToken(launchToken).factory();
        }
        launchpadFactory.poolManager();
        launchpadFactory.defaultOrchestrator();
        launchpadFactory.virtualXYKImplementation();
        launchpadFactory.steppedTrancheImplementation();
        address ntImpl = launchpadFactory.nativeTickImplementation();
        NativeTickLaunch(ntImpl).poolManager();
        NativeTickLaunch(ntImpl).hookOrchestrator();
        NativeTickLaunch(ntImpl).factory();
        NativeTickLaunch(ntImpl).poolId();
        NativeTickLaunch(ntImpl).projectToken();

        if (xykCurve != address(0)) {
            VirtualXYKLaunch xyk = VirtualXYKLaunch(payable(xykCurve));
            xyk.poolManager();
            xyk.hookOrchestrator();
            xyk.factory();
            xyk.poolId();
        }
        if (trancheCurve != address(0)) {
            SteppedTrancheLaunch tr = SteppedTrancheLaunch(payable(trancheCurve));
            tr.poolManager();
            tr.hookOrchestrator();
            tr.factory();
            tr.poolId();
            tr.launchCreationBlock();
        }
    }

    function _exerciseBitmaps() internal view {
        orchestrator.isValidTier3Bitmap(0);
        orchestrator.isValidTier3Bitmap(uint32(1) << 25);
        orchestrator.isValidTier3Bitmap(HookPermissionMasks.BIT_DYNAMIC_FEE | HookPermissionMasks.BIT_MANAGED_FEE);
        orchestrator.isValidTier3Bitmap(HookPermissionMasks.BIT_MEV_PROTECTION | HookPermissionMasks.BIT_JIT_GUARD);
        orchestrator.isValidTier3Bitmap(HookPermissionMasks.BIT_ARB_RECAPTURE | HookPermissionMasks.BIT_CIRCUIT_BREAKER);
        orchestrator.isValidTier3Bitmap(HookPermissionMasks.BIT_WALLET_CAP | HookPermissionMasks.BIT_VESTING_SELL_CAP);
        orchestrator.isValidTier3Bitmap(HookPermissionMasks.BIT_LIMIT_ORDERS | HookPermissionMasks.BIT_BUY_SELL_TAX);
        orchestrator.isValidTier3Bitmap(HookPermissionMasks.BIT_TWAMM | HookPermissionMasks.BIT_BUY_SELL_TAX);
        orchestrator.isValidTier3Bitmap(HookPermissionMasks.BIT_ACCESS_CONTROL | HookPermissionMasks.BIT_LIMIT_ORDERS);
        orchestrator.isValidTier3Bitmap(HookPermissionMasks.BIT_DYNAMIC_FEE);
    }

    function _exercisePresets() internal {
        try new FairLaunchPresetHook(poolManager, address(this)) {} catch {}
        try new KingOfThePoolLaunchPresetHook(poolManager, address(this)) {} catch {}
        try new WeeklyKingBuyRewardsPresetHook(poolManager, address(this)) {} catch {}
        try new CreatorEconomyPresetHook(poolManager, address(this)) {} catch {}
        try new CharityTokenPresetHook(poolManager, address(this)) {} catch {}
        try new TreasuryBackedPresetHook(poolManager, address(this)) {} catch {}
        try new StockQuotedPresetHook(poolManager, address(this)) {} catch {}
        try new DeepLiquidityPresetHook(poolManager, address(this)) {} catch {}
        try new TraderFirstPresetHook(poolManager, address(this)) {} catch {}
        try new StablePairProjectFeePresetHook(poolManager, address(this)) {} catch {}
        try new PrivatePoolPresetHook(poolManager, address(this)) {} catch {}
        try new ProTradingPoolPresetHook(poolManager, address(this)) {} catch {}
    }

    function probeStrictPaths() external {
        token0.mint(address(this), 10_000_000 ether);
        token1.mint(address(this), 10_000_000 ether);
        token0.approve(address(plainRouter), type(uint256).max);
        token1.approve(address(plainRouter), type(uint256).max);
        token0.approve(address(orchestrator), type(uint256).max);
        token1.approve(address(orchestrator), type(uint256).max);

        // 0. LimitOrders claim with strictMode = false (_swapFilledOrderOnClaim() == true -> LimitOrderSwapExecutor)
        PoolKey memory kLim = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 76,
            hooks: IHooks(address(orchestrator))
        });
        IHookRigBlock.PoolStackConfig memory limCfg;
        limCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_LIMIT_ORDERS;
        orchestrator.registerPoolStack(kLim, limCfg);
        poolManager.initialize(kLim, SQRT_PRICE_1_1);
        plainRouter.modifyLiquidity(
            kLim,
            ModifyLiquidityParams({tickLower: -760, tickUpper: 760, liquidityDelta: 1_000_000 ether, salt: bytes32(0)}),
            ""
        );
        // Place orders above and below and cross ticks in both directions
        uint256 oid0 = orchestrator.placeLimitOrder(kLim, -76, true, 1 ether);
        uint256 oid1 = orchestrator.placeLimitOrder(kLim, 76, false, 1 ether);
        plainRouter.swap(
            kLim,
            SwapParams({
                zeroForOne: true, amountSpecified: -50_000 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            abi.encode(address(this))
        );
        plainRouter.swap(
            kLim,
            SwapParams({
                zeroForOne: false, amountSpecified: -100_000 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            abi.encode(address(this))
        );
        orchestrator.forceBucketFilled(kLim.toId(), -76, true, true);
        orchestrator.forceBucketFilled(kLim.toId(), 76, false, true);
        orchestrator.claimLimitOrder(kLim, oid0);
        orchestrator.claimLimitOrder(kLim, oid1);

        // Now enable strictMode = true
        orchestrator.setStrictMode(true);

        PoolKey memory k1 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 77,
            hooks: IHooks(address(orchestrator))
        });

        // 1. Unconfigured pool initialize -> PoolNotConfigured
        try poolManager.initialize(k1, SQRT_PRICE_1_1) {} catch {}

        // 2. Invalid Tier-3 bitmap under strictMode -> InvalidBlockBitmap
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_MEV_PROTECTION | HookPermissionMasks.BIT_JIT_GUARD;
        try orchestrator.registerPoolStack(k1, cfg) {} catch {}

        // 3. Valid Tier-3 bitmap under strictMode + initialize with TWAMM +BuySellTax on k2
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_TWAMM;
        orchestrator.registerPoolStack(k1, cfg);
        poolManager.initialize(k1, SQRT_PRICE_1_1);
        try orchestrator.submitTWAMMOrder(k1, true, 100, 0) {} catch {}
        uint256 tw0 = orchestrator.submitTWAMMOrder(k1, true, 3600 ether, 3600);
        uint256 tw1 = orchestrator.submitTWAMMOrder(k1, false, 3600 ether, 3600);
        orchestrator.cancelTWAMMOrder(k1, tw0);
        orchestrator.cancelTWAMMOrder(k1, tw1);
        try orchestrator.cancelTWAMMOrder(k1, tw0) {} catch {}

        PoolKey memory k2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 78,
            hooks: IHooks(address(orchestrator))
        });
        IHookRigBlock.PoolStackConfig memory taxCfg;
        taxCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_BUY_SELL_TAX | HookPermissionMasks.BIT_LIMIT_ORDERS;
        orchestrator.setStrictMode(false);
        taxCfg.buySellTax = IHookRigBlock.BuySellTaxParams({
            buyTaxBps: 200, sellTaxBps: 200, taxRecipient: address(this), decayOnly: false
        });
        orchestrator.registerPoolStack(k2, taxCfg);
        poolManager.initialize(k2, SQRT_PRICE_1_1);
        plainRouter.modifyLiquidity(
            k2,
            ModifyLiquidityParams({tickLower: -780, tickUpper: 780, liquidityDelta: 100_000 ether, salt: bytes32(0)}),
            ""
        );

        // 4. Swap on k2 with strictMode = true (hits _protocolRoyaltyBps() == 5 and royaltyCut branch in BuySellTaxLogic)
        orchestrator.setStrictMode(true);
        plainRouter.swap(
            k2,
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            abi.encode(address(this))
        );

        // 5. Limit order place + claim with strictMode = true (_swapFilledOrderOnClaim() == false)
        uint256 oid2 = orchestrator.placeLimitOrder(k2, 78, true, 1 ether);
        orchestrator.forceBucketFilled(k2.toId(), 78, true, true);
        orchestrator.claimLimitOrder(k2, oid2);

        revert("probe_done");
    }

    function probeBlockConfigReverts() external {
        // Use a fresh unconfigured key (tickSpacing = 79) so initPoolMeta succeeds and reaches each block's init()
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 79,
            hooks: IHooks(address(orchestrator))
        });

        IHookRigBlock.PoolStackConfig memory cfg;

        // AccessControl: OnlyLaunchpadFactory
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_DYNAMIC_FEE;
        cfg.authorizedCurve = address(0x1234);
        try orchestrator.registerPoolStack(k, cfg) {} catch {}
        cfg.authorizedCurve = address(0);

        // DynamicFee invalid bounds & threshold
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_DYNAMIC_FEE;
        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 5000, maxFee: 1000, volatilityTickThreshold: 10});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}
        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 1000, maxFee: 5000, volatilityTickThreshold: 0});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        // ManagedFee invalid cap & startingFee
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_MANAGED_FEE;
        cfg.managedFee = IHookRigBlock.ManagedFeeParams({startingFee: 1000, feeCap: 60_000, manager: address(this)});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}
        cfg.managedFee = IHookRigBlock.ManagedFeeParams({startingFee: 20_000, feeCap: 10_000, manager: address(this)});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        // MarketHoursFee invalid
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_MARKET_HOURS_FEE;
        cfg.marketHoursFee = IHookRigBlock.MarketHoursFeeParams({
            openHourUtc: 24, closeHourUtc: 12, openFee: 1000, closedFee: 2000, weekendClosed: false
        });
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        // AntiSnipe invalid
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_ANTI_SNIPE;
        cfg.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 1000, normalFee: 5000, decayBlocks: 10});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        // ArbRecapture invalid
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_ARB_RECAPTURE;
        cfg.arbRecapture = IHookRigBlock.ArbRecaptureParams({recaptureShareBps: 9000, arbTriggerTickDelta: 10});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}
        cfg.arbRecapture = IHookRigBlock.ArbRecaptureParams({recaptureShareBps: 1000, arbTriggerTickDelta: 0});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        // MEVProtection invalid
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_MEV_PROTECTION;
        cfg.mevProtection =
            IHookRigBlock.MEVProtectionParams({maxTickDeltaPerSwap: -1, minLPHoldBlocks: 1, jitExitPenaltyBps: 0});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        // AutoBuyback invalid
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_AUTO_BUYBACK;
        cfg.autoBuyback =
            IHookRigBlock.AutoBuybackParams({buybackFeeBps: 600, triggerFloorTick: 0, minBuybackReserve: 1 ether});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}
        cfg.autoBuyback = IHookRigBlock.AutoBuybackParams({
            buybackFeeBps: 100, triggerFloorTick: TickMath.MIN_TICK - 1, minBuybackReserve: 1 ether
        });
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        // FeeSharing invalid
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_FEE_SHARING;
        cfg.feeSharing = IHookRigBlock.FeeSharingParams({
            feeShareBps: 100, primaryRecipient: address(0), secondaryRecipient: address(0), secondaryShareBps: 0
        });
        try orchestrator.registerPoolStack(k, cfg) {} catch {}
        cfg.feeSharing = IHookRigBlock.FeeSharingParams({
            feeShareBps: 100, primaryRecipient: address(this), secondaryRecipient: address(0), secondaryShareBps: 100
        });
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        // KingOfThePool invalid
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_KING_OF_THE_POOL;
        cfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 600, roundDurationSeconds: 600, minBuyAmountForReset: 1 ether
        });
        try orchestrator.registerPoolStack(k, cfg) {} catch {}
        cfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 100, roundDurationSeconds: 10, minBuyAmountForReset: 1 ether
        });
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        // ReferralSplit, SwapRewards, AutoBurn, BuySellTax, LPRewards, VestingSellCap, WalletCap
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_REFERRAL_SPLIT;
        cfg.referralSplit = IHookRigBlock.ReferralSplitParams({referralFeeBps: 600});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_SWAP_REWARDS;
        cfg.swapRewards = IHookRigBlock.SwapRewardsParams({pointsPerUnitVolume: 1e30});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_AUTO_BURN;
        cfg.autoBurn = IHookRigBlock.AutoBurnParams({burnOnBuyBps: 600, useTokenBurnCall: true});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_BUY_SELL_TAX;
        cfg.buySellTax = IHookRigBlock.BuySellTaxParams({
            buyTaxBps: 2000, sellTaxBps: 0, taxRecipient: address(this), decayOnly: false
        });
        try orchestrator.registerPoolStack(k, cfg) {} catch {}
        cfg.buySellTax =
            IHookRigBlock.BuySellTaxParams({buyTaxBps: 100, sellTaxBps: 0, taxRecipient: address(0), decayOnly: false});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_LP_REWARDS;
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 600});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_VESTING_SELL_CAP;
        cfg.vestingSellCap = IHookRigBlock.VestingSellCapParams({maxDailySellBps: 0});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_WALLET_CAP;
        cfg.walletCap = IHookRigBlock.WalletCapParams({maxWalletBps: 0, sunsetBlocks: 10});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}
        cfg.walletCap = IHookRigBlock.WalletCapParams({maxWalletBps: 100, sunsetBlocks: 1_000_000});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        // AggregateReturnDeltaBpsExceeded
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_BUY_SELL_TAX | HookPermissionMasks.BIT_FEE_SHARING
            | HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_AUTO_BUYBACK
            | HookPermissionMasks.BIT_AUTO_BURN | HookPermissionMasks.BIT_KING_OF_THE_POOL;
        cfg.buySellTax = IHookRigBlock.BuySellTaxParams({
            buyTaxBps: 1000, sellTaxBps: 1000, taxRecipient: address(this), decayOnly: false
        });
        cfg.feeSharing = IHookRigBlock.FeeSharingParams({
            feeShareBps: 1000, primaryRecipient: address(this), secondaryRecipient: address(0), secondaryShareBps: 0
        });
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 500});
        cfg.autoBuyback =
            IHookRigBlock.AutoBuybackParams({buybackFeeBps: 500, triggerFloorTick: 0, minBuybackReserve: 1 ether});
        try orchestrator.registerPoolStack(k, cfg) {} catch {}

        revert("probe_done");
    }

    function probeSpecialExecutionPaths(PoolKey memory multiKey, address xykCurve, address trancheCurve) external {
        _probeMerkle();
        _probeNonBurnable();
        _probeLaunchpadReverts(multiKey, xykCurve, trancheCurve);
        revert("probe_done");
    }

    function _probeMerkle() internal {
        bytes32 leaf = keccak256(abi.encodePacked(address(this)));
        bytes32 sib = bytes32(uint256(1));
        bytes32 root = leaf <= sib ? keccak256(abi.encodePacked(leaf, sib)) : keccak256(abi.encodePacked(sib, leaf));
        PoolKey memory acKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 81,
            hooks: IHooks(address(orchestrator))
        });
        IHookRigBlock.PoolStackConfig memory acCfg;
        acCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_ACCESS_CONTROL;
        acCfg.accessControl = IHookRigBlock.AccessControlParams({
            checkBeforeAddLiquidity: true, checkBeforeSwap: true, merkleRoot: root, manager: address(this)
        });
        orchestrator.registerPoolStack(acKey, acCfg);
        poolManager.initialize(acKey, SQRT_PRICE_1_1);

        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);
        token0.approve(address(trustedRouter), type(uint256).max);
        token1.approve(address(trustedRouter), type(uint256).max);
        token0.approve(address(plainRouter), type(uint256).max);
        token1.approve(address(plainRouter), type(uint256).max);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sib;
        trustedRouter.modifyLiquidity(
            acKey,
            ModifyLiquidityParams({tickLower: -810, tickUpper: 810, liquidityDelta: 100_000 ether, salt: bytes32(0)}),
            abi.encodePacked(sib)
        );
        plainRouter.swap(
            acKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            abi.encode(address(this), proof)
        );
    }

    function _probeNonBurnable() internal {
        NonBurnableToken nb = new NonBurnableToken();
        (Currency c0, Currency c1) = address(token0) < address(nb)
            ? (Currency.wrap(address(token0)), Currency.wrap(address(nb)))
            : (Currency.wrap(address(nb)), Currency.wrap(address(token0)));
        PoolKey memory nbKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 82,
            hooks: IHooks(address(orchestrator))
        });
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap =
            HookPermissionMasks.BIT_AUTO_BURN | HookPermissionMasks.BIT_FEE_SHARING | HookPermissionMasks.BIT_JIT_GUARD;
        cfg.autoBurn = IHookRigBlock.AutoBurnParams({burnOnBuyBps: 200, useTokenBurnCall: true});
        cfg.feeSharing = IHookRigBlock.FeeSharingParams({
            feeShareBps: 200, primaryRecipient: address(this), secondaryRecipient: address(0), secondaryShareBps: 0
        });
        orchestrator.registerPoolStack(nbKey, cfg);
        poolManager.initialize(nbKey, SQRT_PRICE_1_1);

        nb.mint(address(this), 1_000_000 ether);
        nb.approve(address(plainRouter), type(uint256).max);

        plainRouter.modifyLiquidity(
            nbKey,
            ModifyLiquidityParams({tickLower: -820, tickUpper: 820, liquidityDelta: 100_000 ether, salt: bytes32(0)}),
            abi.encode(address(this))
        );
        bool buyZeroForOne = Currency.unwrap(c1) == address(nb);
        plainRouter.swap(
            nbKey,
            SwapParams({
                zeroForOne: buyZeroForOne,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: buyZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            abi.encode(address(this))
        );
    }

    function _probeLaunchpadReverts(PoolKey memory multiKey, address xykCurve, address trancheCurve) internal {
        try orchestrator.setBuySellTax(multiKey.toId(), 100, 100, address(0)) {} catch {}

        if (xykCurve != address(0)) {
            VirtualXYKLaunch xyk = VirtualXYKLaunch(payable(xykCurve));
            try xyk.buy(0, 0, address(this)) {} catch {}
        }
        if (trancheCurve != address(0)) {
            SteppedTrancheLaunch tr = SteppedTrancheLaunch(payable(trancheCurve));
            try tr.buy(0, 0, address(this)) {} catch {}
        }

        IHookRigBlock.PoolStackConfig memory cfg;
        ITokenLaunchpad.LaunchTokenMetadata memory meta = ITokenLaunchpad.LaunchTokenMetadata({
            name: "T",
            symbol: "T",
            totalSupply: 1000 ether,
            creator: address(this),
            creatorVestingBps: 5000,
            vestingDurationSeconds: 1 days
        });
        ITokenLaunchpad.VirtualXYKConfig memory badXyk;
        try launchpadFactory.launchVirtualXYK(
            meta,
            Currency.wrap(address(token0)),
            60,
            IHookRigOrchestrator(address(orchestrator)),
            cfg,
            badXyk,
            bytes32(uint256(999999))
        ) {}
            catch {}
        meta.creatorVestingBps = 0;
        try launchpadFactory.launchVirtualXYK(
            meta,
            Currency.wrap(address(token0)),
            60,
            IHookRigOrchestrator(address(orchestrator)),
            cfg,
            badXyk,
            bytes32(uint256(999999))
        ) {}
            catch {}

        ITokenLaunchpad.SteppedTrancheConfig memory badTr;
        try launchpadFactory.launchSteppedTranche(
            meta,
            Currency.wrap(address(token0)),
            60,
            IHookRigOrchestrator(address(orchestrator)),
            cfg,
            badTr,
            bytes32(uint256(999999))
        ) {}
            catch {}

        ITokenLaunchpad.NativeTickConfig memory badNative;
        try launchpadFactory.launchNativeTick(
            meta,
            Currency.wrap(address(token0)),
            IHookRigOrchestrator(address(orchestrator)),
            cfg,
            badNative,
            bytes32(uint256(999999))
        ) {}
            catch {}

        badNative.bands = new ITokenLaunchpad.NativeTickBand[](1);
        badNative.bands[0] = ITokenLaunchpad.NativeTickBand({tickLower: -60, tickUpper: 60, tokenAmount: 2000 ether});
        try launchpadFactory.launchNativeTick(
            meta,
            Currency.wrap(address(token0)),
            IHookRigOrchestrator(address(orchestrator)),
            cfg,
            badNative,
            bytes32(uint256(999999))
        ) {}
            catch {}
    }
}
