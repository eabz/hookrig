// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookRigTestBase} from "../utils/HookRigTestBase.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";

import {IHookRigBlock} from "../../src/interfaces/IHookRigBlock.sol";
import {IHookRigOrchestrator} from "../../src/interfaces/IHookRigOrchestrator.sol";
import {HookPermissionMasks} from "../../src/libraries/HookPermissionMasks.sol";
import {TransientContext} from "../../src/libraries/TransientContext.sol";
import {HookRigBase} from "../../src/base/HookRigBase.sol";
import {LimitOrdersLogic} from "../../src/blocks/trading/LimitOrdersBlock.sol";
import {KingOfThePoolLogic} from "../../src/blocks/rewards/KingOfThePoolBlock.sol";
import {TWAMMLogic} from "../../src/blocks/trading/TWAMMBlock.sol";
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
} from "../../src/presets/HookRigPresets.sol";

/// @title PresetsAndSecurityVectorsTest
/// @notice Tests all 12 curated presets, Exact-In / Exact-Out symmetry, and every documented Uniswap v4 attack vector.
contract PresetsAndSecurityVectorsTest is HookRigTestBase {
    using PoolIdLibrary for PoolKey;

    // =========================================================================
    // 1. All 12 Curated Presets Deployment, Permissions & End-to-End Execution
    // =========================================================================

    function test_All12PresetHookContracts_PermissionsAndBitmaps() public {
        _verifyPresetDeployment(
            "HookRigPresets.sol:FairLaunchPresetHook",
            IHookRigBlock.PresetId.FairLaunch,
            HookPermissionMasks.PRESET_FAIR_LAUNCH,
            0x5001
        );
        _verifyPresetDeployment(
            "HookRigPresets.sol:KingOfThePoolLaunchPresetHook",
            IHookRigBlock.PresetId.KingOfThePoolLaunch,
            HookPermissionMasks.PRESET_KING_OF_THE_POOL_LAUNCH,
            0x5002
        );
        _verifyPresetDeployment(
            "HookRigPresets.sol:WeeklyKingBuyRewardsPresetHook",
            IHookRigBlock.PresetId.WeeklyKingWithBuyRewards,
            HookPermissionMasks.PRESET_WEEKLY_KING_BUY_REWARDS,
            0x5003
        );
        _verifyPresetDeployment(
            "HookRigPresets.sol:CreatorEconomyPresetHook",
            IHookRigBlock.PresetId.CreatorEconomyToken,
            HookPermissionMasks.PRESET_CREATOR_ECONOMY,
            0x5004
        );
        _verifyPresetDeployment(
            "HookRigPresets.sol:CharityTokenPresetHook",
            IHookRigBlock.PresetId.CharityToken,
            HookPermissionMasks.PRESET_CHARITY_TOKEN,
            0x5005
        );
        _verifyPresetDeployment(
            "HookRigPresets.sol:TreasuryBackedPresetHook",
            IHookRigBlock.PresetId.TreasuryBackedToken,
            HookPermissionMasks.PRESET_TREASURY_BACKED,
            0x5006
        );
        _verifyPresetDeployment(
            "HookRigPresets.sol:StockQuotedPresetHook",
            IHookRigBlock.PresetId.StockQuotedToken,
            HookPermissionMasks.PRESET_STOCK_QUOTED,
            0x5007
        );
        _verifyPresetDeployment(
            "HookRigPresets.sol:DeepLiquidityPresetHook",
            IHookRigBlock.PresetId.DeepLiquidityExistingToken,
            HookPermissionMasks.PRESET_DEEP_LIQUIDITY,
            0x5008
        );
        _verifyPresetDeployment(
            "HookRigPresets.sol:TraderFirstPresetHook",
            IHookRigBlock.PresetId.TraderFirstPool,
            HookPermissionMasks.PRESET_TRADER_FIRST,
            0x5009
        );
        _verifyPresetDeployment(
            "HookRigPresets.sol:StablePairProjectFeePresetHook",
            IHookRigBlock.PresetId.StablePairProjectFee,
            HookPermissionMasks.PRESET_STABLE_PAIR_PROJECT_FEE,
            0x500A
        );
        _verifyPresetDeployment(
            "HookRigPresets.sol:PrivatePoolPresetHook",
            IHookRigBlock.PresetId.PrivatePool,
            HookPermissionMasks.PRESET_PRIVATE_POOL,
            0x500B
        );
        _verifyPresetDeployment(
            "HookRigPresets.sol:ProTradingPoolPresetHook",
            IHookRigBlock.PresetId.ProTradingPool,
            HookPermissionMasks.PRESET_PRO_TRADING_POOL,
            0x500C
        );
    }

    function _verifyPresetDeployment(
        string memory artifact,
        IHookRigBlock.PresetId presetId,
        uint32 expectedBitmap,
        uint160 prefix
    ) internal {
        Hooks.Permissions memory expectedPerms = HookPermissionMasks.permissionsForBitmap(expectedBitmap);
        uint160 flags = _flagsFromPermissions(expectedPerms);
        address targetAddr = address((prefix << 64) | flags);

        deployCodeTo(artifact, abi.encode(poolManager, owner), targetAddr);
        Hooks.Permissions memory actualPerms = BaseHook(targetAddr).getHookPermissions();
        assertEq(_flagsFromPermissions(actualPerms), flags);
        assertEq(HookPermissionMasks.getPresetBitmap(presetId), expectedBitmap);
    }

    function test_Presets_ExecutionThroughOrchestrator() public {
        // Test WeeklyKingWithBuyRewards preset (auto-defaults roundDurationSeconds to 168 hours when 0)
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.presetId = IHookRigBlock.PresetId.WeeklyKingWithBuyRewards;
        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 3000, maxFee: 10_000, volatilityTickThreshold: 50});
        cfg.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 50_000, normalFee: 3000, decayBlocks: 20});
        cfg.arbRecapture = IHookRigBlock.ArbRecaptureParams({recaptureShareBps: 2000, arbTriggerTickDelta: 10});
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 100});
        cfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 200,
            roundDurationSeconds: 0, // Should default to 168 hours (604800s)
            minBuyAmountForReset: 10 ether
        });
        cfg.swapRewards = IHookRigBlock.SwapRewardsParams({pointsPerUnitVolume: 5e18});

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        uint256 startTs = block.timestamp;
        _swapExactIn(alice, key, true, 500 ether, "");

        (, address king, uint256 pot, uint64 deadline) = orchestrator.getCurrentKing(poolId);
        assertEq(king, alice);
        assertGt(pot, 0);
        assertEq(deadline, startTs + 168 hours);
        assertGt(orchestrator.swapRewardPoints(poolId, alice), 0);
    }

    // =========================================================================
    // 2. Attack Vector Tests (Cork Protocol, Bunni V2, DoS, Spoofing, Caps)
    // =========================================================================

    /// @notice Attack Vector #1 (Cork Protocol ~$12M Vector): Unauthenticated callback invocation & Cross-pool claim drain.
    function test_AttackVector01_UnauthenticatedCallbackAndCrossPoolClaimIsolation() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.presetId = IHookRigBlock.PresetId.CreatorEconomyToken;
        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 3000, maxFee: 10_000, volatilityTickThreshold: 50});
        cfg.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 10_000, normalFee: 3000, decayBlocks: 10});
        cfg.buySellTax =
            IHookRigBlock.BuySellTaxParams({buyTaxBps: 200, sellTaxBps: 200, taxRecipient: treasury, decayOnly: true});
        cfg.feeSharing = IHookRigBlock.FeeSharingParams({
            feeShareBps: 100, primaryRecipient: charity, secondaryRecipient: address(0), secondaryShareBps: 0
        });
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 100});

        (PoolKey memory keyA, PoolId poolIdA) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(keyA, 1_000_000 ether);

        // 1a. Attacker attempts to spoof PoolManager by calling beforeSwap / afterSwap / unlockCallback directly
        vm.startPrank(alice);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        orchestrator.beforeSwap(
            alice, keyA, SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: MIN_PRICE_LIMIT}), ""
        );

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        orchestrator.afterSwap(
            alice,
            keyA,
            SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            BalanceDelta.wrap(0),
            ""
        );

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        orchestrator.unlockCallback(abi.encode(currency1, alice, 100 ether));
        vm.stopPrank();

        // 1b. Execute legitimate swap on Pool A so treasury accrues claims on Pool A
        _swapExactIn(alice, keyA, true, 1000 ether, "");
        uint256 claimPoolA = orchestrator.poolClaims(poolIdA, currency1, treasury);
        assertGt(claimPoolA, 0);

        // Register Pool B with the same currencies (different tickSpacing)
        PoolKey memory keyB = keyA;
        keyB.tickSpacing = 120;
        PoolId poolIdB = keyB.toId();
        orchestrator.registerPoolStack(keyB, cfg);
        poolManager.initialize(keyB, SQRT_PRICE_1_1);

        // Treasury cannot withdraw Pool A's claims from Pool B's isolated ledger
        assertEq(orchestrator.poolClaims(poolIdB, currency1, treasury), 0);
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(IHookRigOrchestrator.InsufficientClaimBalance.selector, claimPoolA, 0));
        orchestrator.withdrawClaim(poolIdB, currency1, claimPoolA, treasury);
    }

    /// @notice Attack Vector #2 (Bunni V2 ~$8.4M Vector): 1-Wei and dust swap rounding manipulation.
    function test_AttackVector02_BunniV2_OneWeiDustRoundingSafety() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.presetId = IHookRigBlock.PresetId.Blank;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_ARB_RECAPTURE | HookPermissionMasks.BIT_BUY_SELL_TAX
            | HookPermissionMasks.BIT_AUTO_BURN | HookPermissionMasks.BIT_FEE_SHARING
            | HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_KING_OF_THE_POOL;
        cfg.arbRecapture = IHookRigBlock.ArbRecaptureParams({recaptureShareBps: 5000, arbTriggerTickDelta: 1});
        cfg.buySellTax =
            IHookRigBlock.BuySellTaxParams({buyTaxBps: 500, sellTaxBps: 500, taxRecipient: treasury, decayOnly: true});
        cfg.autoBurn = IHookRigBlock.AutoBurnParams({burnOnBuyBps: 500, useTokenBurnCall: true});
        cfg.feeSharing = IHookRigBlock.FeeSharingParams({
            feeShareBps: 500, primaryRecipient: charity, secondaryRecipient: owner, secondaryShareBps: 3333
        });
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 500});
        cfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 495, roundDurationSeconds: 3600, minBuyAmountForReset: 1 ether
        });

        (PoolKey memory key,) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        // Execute 1-wei and 7-wei dust swaps: Math.Rounding.Floor guarantees cuts round down to 0 rather than underflowing pool
        _swapExactIn(alice, key, true, 1, "");
        _swapExactIn(alice, key, true, 7, "");
        _swapExactIn(alice, key, false, 1, "");
    }

    /// @notice Attack Vector #3: Aggregate afterSwapReturnDelta > 25% (2500 bps) over-deduction protection.
    function test_AttackVector03_AggregateReturnDeltaBpsCapEnforced() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.presetId = IHookRigBlock.PresetId.Blank;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_BUY_SELL_TAX | HookPermissionMasks.BIT_AUTO_BURN
            | HookPermissionMasks.BIT_FEE_SHARING | HookPermissionMasks.BIT_LP_REWARDS
            | HookPermissionMasks.BIT_KING_OF_THE_POOL | HookPermissionMasks.BIT_AUTO_BUYBACK;

        // Directional buyBps = 5 (royalty) + 1000 (buyTax) + 500 (autoBurn) + 500 (feeSharing) + 500 (lpRewards) + 500 (kingOfThePool) = 3005 bps (> 2500 bps ceiling)
        cfg.buySellTax = IHookRigBlock.BuySellTaxParams({
            buyTaxBps: 1000, sellTaxBps: 1000, taxRecipient: treasury, decayOnly: false
        });
        cfg.autoBurn = IHookRigBlock.AutoBurnParams({burnOnBuyBps: 500, useTokenBurnCall: true});
        cfg.feeSharing = IHookRigBlock.FeeSharingParams({
            feeShareBps: 500, primaryRecipient: charity, secondaryRecipient: address(0), secondaryShareBps: 0
        });
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 500});
        cfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 500, roundDurationSeconds: 3600, minBuyAmountForReset: 1 ether
        });
        cfg.autoBuyback =
            IHookRigBlock.AutoBuybackParams({buybackFeeBps: 500, triggerFloorTick: -100, minBuybackReserve: 10 ether});

        PoolKey memory key = _defaultPoolKey(IHooks(address(orchestrator)));
        vm.expectRevert(
            abi.encodeWithSelector(IHookRigOrchestrator.AggregateReturnDeltaBpsExceeded.selector, 3505, 2500)
        );
        orchestrator.registerPoolStack(key, cfg);
    }

    /// @notice Attack Vector #4: Zero Active Liquidity `PoolManager.donate()` Revert Prevention.
    function test_AttackVector04_ZeroLiquidityDonateFallbackDoesNotRevert() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.presetId = IHookRigBlock.PresetId.DeepLiquidityExistingToken;
        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 3000, maxFee: 10_000, volatilityTickThreshold: 50});
        cfg.arbRecapture = IHookRigBlock.ArbRecaptureParams({recaptureShareBps: 5000, arbTriggerTickDelta: 1});
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 300});

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);

        // Provide narrow concentrated liquidity only in [-120, 0]
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 0, liquidityDelta: 10_000 ether, salt: bytes32(0)}),
            ""
        );

        // Swap completely through [-120, 0] so post-swap active liquidity at the final tick is 0!
        // Without the zero-liquidity check in AfterSwapDeltaAggregator, PoolManager.donate() would revert!
        _swapExactIn(alice, key, true, 50_000 ether, "");
        assertEq(orchestrator.totalLPRewardsDonated(poolId), 0);
    }

    /// @notice Attack Vector #5: Exact-Input vs. Exact-Output & Token0/Token1 Polarity Symmetry.
    function test_AttackVector05_ExactInAndExactOut_Token0AndToken1Polarity() public {
        // Test with isToken0ProjectToken = true AND Exact-Output swaps
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.presetId = IHookRigBlock.PresetId.FairLaunch;
        cfg.isToken0ProjectToken = true;
        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 3000, maxFee: 10_000, volatilityTickThreshold: 50});
        cfg.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 10_000, normalFee: 3000, decayBlocks: 10});
        cfg.walletCap = IHookRigBlock.WalletCapParams({maxWalletBps: 5000, sunsetBlocks: 100});
        cfg.autoBurn = IHookRigBlock.AutoBurnParams({burnOnBuyBps: 200, useTokenBurnCall: true});
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 200});

        (PoolKey memory key,) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        // When isToken0ProjectToken == true: !zeroForOne (paying token1 for token0) is a BUY
        // 1. Exact-Input Buy (!zeroForOne, amountSpecified < 0)
        _swapExactIn(alice, key, false, 500 ether, "");

        // 2. Exact-Output Buy (!zeroForOne, amountSpecified > 0) reverts: AutoBurn would otherwise be skipped
        vm.expectRevert();
        _swapExactOut(bob, key, false, 200 ether, "");

        // 3. Exact-Input Sell (zeroForOne, amountSpecified < 0)
        _swapExactIn(alice, key, true, 200 ether, "");

        // 4. Exact-Output Sell (zeroForOne, amountSpecified > 0)
        _swapExactOut(bob, key, true, 100 ether, "");
    }

    /// @notice Attack Vector #6: Untrusted Router `hookData` Fallback & Re-Registration Lock.
    function test_AttackVector06_UntrustedRouterResolutionAndDoubleConfigLock() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_SWAP_REWARDS;
        cfg.swapRewards = IHookRigBlock.SwapRewardsParams({pointsPerUnitVolume: 1e18});

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        // Cannot re-register an already configured pool
        vm.expectRevert(abi.encodeWithSelector(IHookRigOrchestrator.PoolAlreadyConfigured.selector, poolId));
        orchestrator.registerPoolStack(key, cfg);

        // Disable trusted router status on `router` -> `_resolveUser` ignores `hookData[:32]` and attributes to `routerSender`
        vm.prank(owner);
        orchestrator.setTrustedRouter(address(router), false);

        // Pass `carol` encoded in hookData[:32]: untrusted router cannot spoof `carol`!
        _swapExactIn(alice, key, true, 100 ether, abi.encode(carol));
        assertEq(orchestrator.swapRewardPoints(poolId, carol), 0);
        assertGt(orchestrator.swapRewardPoints(poolId, address(router)), 0);

        // Empty hookData also attributes to router address
        _swapExactIn(alice, key, true, 100 ether, "");
        assertGt(orchestrator.swapRewardPoints(poolId, address(router)), 0);
    }

    /// @notice Attack Vector #7: Static Fee Pool with Dynamic Fee Blocks Rejection.
    function test_AttackVector07_StaticFeePoolWithDynamicBlocksReverts() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_DYNAMIC_FEE;
        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 3000, maxFee: 10_000, volatilityTickThreshold: 50});

        PoolKey memory staticKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // Missing LPFeeLibrary.DYNAMIC_FEE_FLAG!
            tickSpacing: 60,
            hooks: IHooks(address(orchestrator))
        });

        vm.expectRevert(IHookRigOrchestrator.DynamicFeeFlagRequired.selector);
        orchestrator.registerPoolStack(staticKey, cfg);
    }

    /// @notice Attack Vector #8: Launchpad Curve Authorization & Claim Solvency Guards.
    function test_AttackVector08_LaunchpadAuthAndClaimGuards() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_KING_OF_THE_POOL;
        cfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 200, roundDurationSeconds: 600, minBuyAmountForReset: 10 ether
        });

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);

        // 1. Unauthorized caller cannot register a launchpad pool with authorizedCurve != 0
        PoolKey memory lpKey = key;
        lpKey.tickSpacing = 120;
        cfg.authorizedCurve = address(0xCAFE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HookRigBase.OnlyLaunchpadFactory.selector, alice));
        orchestrator.registerPoolStack(lpKey, cfg);

        // 2. Unauthorized caller cannot call notifyPoolGraduated or seedKingPotFromLaunchCurve
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HookRigBase.OnlyAuthorizedCurve.selector, alice));
        orchestrator.notifyPoolGraduated(poolId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HookRigBase.OnlyAuthorizedCurve.selector, alice));
        orchestrator.seedKingPotFromLaunchCurve(poolId, currency0, 100 ether);

        // 3. Authorized launchpadFactory can call seedKingPotFromLaunchCurve:
        //    - The first seed sets the KingOfThePool pot currency
        //    - A seed in another currency reverts: surcharges never go to the pool admin, and currencies never mix
        vm.prank(address(launchpadFactory));
        orchestrator.seedKingPotFromLaunchCurve(poolId, currency1, 0);
        vm.prank(address(launchpadFactory));
        orchestrator.seedKingPotFromLaunchCurve(poolId, currency1, 50 ether);
        (,, uint256 pot,) = orchestrator.getCurrentKing(poolId);
        assertEq(pot, 50 ether);

        vm.prank(address(launchpadFactory));
        vm.expectRevert(abi.encodeWithSelector(KingOfThePoolLogic.KingPotSeedNotAccepted.selector, poolId));
        orchestrator.seedKingPotFromLaunchCurve(poolId, currency0, 25 ether);
        assertEq(orchestrator.poolClaims(poolId, currency0, address(this)), 0);

        // 4. Withdrawing more claims than available reverts with InsufficientClaimBalance
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookRigOrchestrator.InsufficientClaimBalance.selector, 1 ether, 0));
        orchestrator.withdrawClaim(poolId, currency0, 1 ether, alice);

        // 5. EIP-1153 TransientContext recursive self-swap guard flag lifecycle
        assertFalse(TransientContext.isInternalHookExecution(poolId));
        TransientContext.setInternalHookExecution(poolId, true);
        assertTrue(TransientContext.isInternalHookExecution(poolId));
        TransientContext.setInternalHookExecution(poolId, false);
        assertFalse(TransientContext.isInternalHookExecution(poolId));
    }

    // =========================================================================
    // 3. Custom Block Combinations (Tier 3 Mutex Enforcement & Multi-Block Stacks)
    // =========================================================================

    /// @notice Verifies that contradictory 22-block bitmaps revert with `InvalidBlockBitmap`, while a maximal
    ///         compatible custom stack executes the full pool lifecycle cleanly.
    function test_CustomStack_All22BlocksSimultaneously_KitchenSink() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.presetId = IHookRigBlock.PresetId.Blank;

        // 1. Contradictory all-22-blocks bitmap reverts with InvalidBlockBitmap
        uint32 all22 = uint32((uint256(1) << 22) - 1);
        cfg.enabledBlocksBitmap = all22;
        PoolKey memory badKey = _defaultPoolKey(IHooks(address(orchestrator)));
        vm.expectRevert(abi.encodeWithSelector(IHookRigOrchestrator.InvalidBlockBitmap.selector, all22));
        orchestrator.registerPoolStack(badKey, cfg);

        // 2. Maximal compatible custom stack (14 simultaneous blocks across Fees, Protection, Token Rules, Rewards & Oracle)
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_DYNAMIC_FEE | HookPermissionMasks.BIT_ANTI_SNIPE
            | HookPermissionMasks.BIT_ARB_RECAPTURE | HookPermissionMasks.BIT_JIT_GUARD
            | HookPermissionMasks.BIT_WALLET_CAP | HookPermissionMasks.BIT_BUY_SELL_TAX
            | HookPermissionMasks.BIT_AUTO_BURN | HookPermissionMasks.BIT_FEE_SHARING
            | HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_SWAP_REWARDS
            | HookPermissionMasks.BIT_KING_OF_THE_POOL | HookPermissionMasks.BIT_REFERRAL_SPLIT
            | HookPermissionMasks.BIT_AUTO_BUYBACK | HookPermissionMasks.BIT_ORACLE;

        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 2000, maxFee: 10_000, volatilityTickThreshold: 50});
        cfg.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 30_000, normalFee: 2000, decayBlocks: 10});
        cfg.mevProtection =
            IHookRigBlock.MEVProtectionParams({maxTickDeltaPerSwap: 500, minLPHoldBlocks: 2, jitExitPenaltyBps: 100});
        cfg.arbRecapture = IHookRigBlock.ArbRecaptureParams({recaptureShareBps: 1000, arbTriggerTickDelta: 10});
        cfg.walletCap = IHookRigBlock.WalletCapParams({maxWalletBps: 5000, sunsetBlocks: 100});
        cfg.buySellTax =
            IHookRigBlock.BuySellTaxParams({buyTaxBps: 100, sellTaxBps: 100, taxRecipient: treasury, decayOnly: true});
        cfg.autoBurn = IHookRigBlock.AutoBurnParams({burnOnBuyBps: 100, useTokenBurnCall: true});
        cfg.feeSharing = IHookRigBlock.FeeSharingParams({
            feeShareBps: 100, primaryRecipient: treasury, secondaryRecipient: charity, secondaryShareBps: 5000
        });
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 100});
        cfg.swapRewards = IHookRigBlock.SwapRewardsParams({pointsPerUnitVolume: 1e18});
        cfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 100, roundDurationSeconds: 600, minBuyAmountForReset: 10 ether
        });
        cfg.referralSplit = IHookRigBlock.ReferralSplitParams({referralFeeBps: 100});
        cfg.autoBuyback =
            IHookRigBlock.AutoBuybackParams({buybackFeeBps: 100, triggerFloorTick: -5, minBuybackReserve: 1 ether});

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        // Register referrer
        vm.prank(alice);
        orchestrator.registerReferrer(poolId, bob);

        // Execute buy & sell swaps through all 14 active blocks
        vm.warp(block.timestamp + 60);
        _swapExactIn(alice, key, true, 500 ether, "");
        _swapExactIn(bob, key, false, 200 ether, "");

        // Remove LP after hold blocks
        vm.roll(block.number + 3);
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: -1000 ether, salt: bytes32(0)}),
            ""
        );
    }

    /// @notice Verifies base-fee mutual exclusion and deterministic intra-group fee precedence (`AntiSnipe` + `MarketHoursFee`).
    function test_CustomStack_MultiFeeBlockPrecedenceWaterfall() public {
        IHookRigBlock.PoolStackConfig memory cfg;

        // 1. Combining multiple base fee engines reverts with InvalidBlockBitmap
        uint32 multiBaseFee = HookPermissionMasks.BIT_DYNAMIC_FEE | HookPermissionMasks.BIT_MANAGED_FEE
            | HookPermissionMasks.BIT_MARKET_HOURS_FEE | HookPermissionMasks.BIT_ANTI_SNIPE;
        cfg.enabledBlocksBitmap = multiBaseFee;
        PoolKey memory badKey = _defaultPoolKey(IHooks(address(orchestrator)));
        vm.expectRevert(abi.encodeWithSelector(IHookRigOrchestrator.InvalidBlockBitmap.selector, multiBaseFee));
        orchestrator.registerPoolStack(badKey, cfg);

        // 2. Valid combination: MarketHoursFee + AntiSnipe
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_MARKET_HOURS_FEE | HookPermissionMasks.BIT_ANTI_SNIPE;
        cfg.marketHoursFee = IHookRigBlock.MarketHoursFeeParams({
            openHourUtc: 13, closeHourUtc: 20, openFee: 1500, closedFee: 4000, weekendClosed: true
        });
        cfg.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 50_000, normalFee: 1000, decayBlocks: 10});

        (PoolKey memory key,) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        // At block 0, AntiSnipe (50,000) > MarketHoursFee -> AntiSnipe wins
        _swapExactIn(alice, key, true, 100 ether, "");

        // After 15 blocks, AntiSnipe decays to normalFee (1000), so MarketHoursFee takes over
        vm.roll(block.number + 15);
        _swapExactIn(bob, key, false, 100 ether, "");
    }

    // =========================================================================
    // 4. Core Protocol Failure & Anti-Freeze Liveness Guarantees
    // =========================================================================

    /// @notice Anti-Freeze #1: Limit Order makers can ALWAYS withdraw funds after tick crossing (`claimLimitOrder`),
    ///         and cross-pool `PoolKey` spoofing is rejected (`OrderPoolKeyMismatch`).
    function test_AntiFreeze01_LimitOrders_ClaimFilledOrderAndPoolKeyValidation() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_LIMIT_ORDERS;

        (PoolKey memory key,) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 500_000 ether);

        vm.prank(alice);
        uint256 orderId = orchestrator.placeLimitOrder(key, -60, true, 100 ether);

        // Cannot claim before bucket is filled
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LimitOrdersLogic.BucketNotYetFilled.selector, orderId));
        orchestrator.claimLimitOrder(key, orderId);

        // Cross tick -60 -> bucket is marked filled
        _swapExactIn(bob, key, true, 25_000 ether, "");

        // Mismatched PoolKey reverts with OrderPoolKeyMismatch
        PoolKey memory wrongKey = PoolKey({
            currency0: key.currency0, currency1: key.currency1, fee: key.fee, tickSpacing: 120, hooks: key.hooks
        });
        vm.prank(alice);
        vm.expectRevert(LimitOrdersLogic.OrderPoolKeyMismatch.selector);
        orchestrator.claimLimitOrder(wrongKey, orderId);

        // Alice claims her filled limit order -> funds are NEVER frozen and swap into output currency!
        uint256 balBefore = token1.balanceOf(alice);
        vm.prank(alice);
        orchestrator.claimLimitOrder(key, orderId);
        assertGt(token1.balanceOf(alice) - balBefore, 90 ether);
    }

    /// @notice Anti-Freeze #2: `AutoBuyback` burns prior accumulated ERC-6909 reserves when floor defense triggers
    ///         so zero ERC-6909 claims are ever stranded in `PoolManager`.
    function test_AntiFreeze02_AutoBuyback_MultiSwapReserveBurnAndZeroLiqSafety() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_AUTO_BUYBACK;
        cfg.autoBuyback =
            IHookRigBlock.AutoBuybackParams({buybackFeeBps: 300, triggerFloorTick: 100, minBuybackReserve: 1 ether});

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 500_000 ether);

        // Two small sells accumulate currency0 ERC-6909 buyback reserve on orchestrator while tick < 100
        _swapExactIn(alice, key, false, 1000 ether, "");
        _swapExactIn(alice, key, false, 1000 ether, "");
        uint256 orcBalBefore = poolManager.balanceOf(address(orchestrator), currency0.toId());
        assertGt(orcBalBefore, 0);
        assertEq(orchestrator.pendingLPDonation(poolId, currency0), 0);

        // Now a larger sell pushes postSwapTick >= 100 (project token price drops below floor)
        // so the accumulated currency0 ERC-6909 reserve is queued for LP donation and flushed on a later block's swap!
        _swapExactIn(bob, key, false, 25_000 ether, "");
        assertGt(orchestrator.pendingLPDonation(poolId, currency0), 0);
        vm.roll(block.number + 1);
        _swapExactIn(alice, key, true, 1000 ether, "");

        // Verify prior currency0 ERC-6909 buyback reserve was donated and burned: only the royalty claim
        // and any currency0 pendingLPDonation remain as hook currency0 claims.
        uint256 royaltyClaim0 = orchestrator.poolClaims(poolId, currency0, orchestrator.PROTOCOL_ROYALTY_RECIPIENT());
        assertEq(
            poolManager.balanceOf(address(orchestrator), currency0.toId()),
            royaltyClaim0 + orchestrator.pendingLPDonation(poolId, currency0)
        );
        assertGt(orchestrator.totalLPRewardsDonated(poolId), orcBalBefore - royaltyClaim0);
    }

    /// @notice Anti-Freeze #3: `JITGuard` and `CircuitBreaker` enforce hard upper ceilings on `minLPHoldBlocks`
    ///         (`<= 7200` blocks) and `windowSeconds` (`<= 86,400s`) so a malicious admin cannot freeze a pool forever.
    function test_AntiFreeze03_JITAndCircuitBreaker_HardCeilingsPreventInfiniteLock() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_JIT_GUARD | HookPermissionMasks.BIT_CIRCUIT_BREAKER;
        cfg.mevProtection = IHookRigBlock.MEVProtectionParams({
            maxTickDeltaPerSwap: 0,
            minLPHoldBlocks: type(uint32).max, // Attempt infinite LP lockup -> rejected at registration!
            jitExitPenaltyBps: 0
        });
        cfg.circuitBreaker = IHookRigBlock.CircuitBreakerParams({maxWindowTickDeviation: 20, windowSeconds: 300});

        PoolKey memory badKey = _defaultPoolKey(IHooks(address(orchestrator)));
        vm.expectRevert();
        orchestrator.registerPoolStack(badKey, cfg);

        // Attempt 136-year circuit breaker freeze -> rejected at registration!
        cfg.mevProtection.minLPHoldBlocks = 7200;
        cfg.circuitBreaker.windowSeconds = type(uint32).max;
        vm.expectRevert();
        orchestrator.registerPoolStack(badKey, cfg);

        // Register at the maximum allowed ceilings (7200 blocks / 86,400s)
        cfg.circuitBreaker.windowSeconds = 86_400;
        (PoolKey memory key,) = _initPoolWithStack(cfg);

        vm.prank(alice);
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100_000 ether, salt: bytes32(0)}),
            ""
        );

        // Advance 7201 blocks (just past the 7200-block hard cap) -> Alice can withdraw LP!
        vm.roll(block.number + 7201);
        vm.prank(alice);
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: -50_000 ether, salt: bytes32(0)}),
            ""
        );

        // Trigger circuit breaker, then advance 86,401s (just past 24h hard cap) -> trading resumes!
        _swapExactIn(bob, key, true, 50 ether, "");
        vm.expectRevert();
        _swapExactIn(bob, key, true, 15_000 ether, "");

        vm.warp(block.timestamp + 86_401);
        _swapExactIn(bob, key, true, 50 ether, "");
    }

    // =========================================================================
    // 5. Audit & Stateful Fuzzing Regression Suite
    // =========================================================================

    /// @notice Regression #1: Preset hook permission flag validation (`#40, #42`), `poolAdmin` caller authorization
    ///         on `registerPoolStack` (`#41, #58`), and mandatory `afterInitialize` on all active bitmaps (`#2`).
    function test_Regression01_PresetPermissionEnforcementAndPoolAdminAuth() public {
        // 1. Every non-zero bitmap enables afterInitialize so launchpad pools always run _afterInitialize
        Hooks.Permissions memory twammPerms = HookPermissionMasks.permissionsForBitmap(HookPermissionMasks.BIT_TWAMM);
        assertTrue(twammPerms.beforeInitialize && twammPerms.afterInitialize);

        // 2. Deploying FairLaunchPresetHook (no BEFORE_INITIALIZE_FLAG) and attempting to register BIT_TWAMM reverts
        uint160 fairFlags =
            _flagsFromPermissions(HookPermissionMasks.permissionsForBitmap(HookPermissionMasks.PRESET_FAIR_LAUNCH));
        address presetAddr = address(uint160(0x6666000000000000000000000000000000000000) | fairFlags);
        deployCodeTo("HookRigPresets.sol:FairLaunchPresetHook", abi.encode(poolManager, owner), presetAddr);
        FairLaunchPresetHook fairHook = FairLaunchPresetHook(payable(presetAddr));

        IHookRigBlock.PoolStackConfig memory badTwammCfg;
        badTwammCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_TWAMM;
        PoolKey memory fairKey = _defaultPoolKey(IHooks(presetAddr));
        vm.expectRevert(
            abi.encodeWithSelector(IHookRigOrchestrator.InvalidBlockBitmap.selector, HookPermissionMasks.BIT_TWAMM)
        );
        fairHook.registerPoolStack(fairKey, badTwammCfg);

        // 3. Setting a non-zero poolAdmin requires msg.sender == config.poolAdmin (or launchpadFactory)
        IHookRigBlock.PoolStackConfig memory adminCfg;
        adminCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_DYNAMIC_FEE;
        adminCfg.poolAdmin = alice;
        adminCfg.dynamicFee =
            IHookRigBlock.DynamicFeeParams({baseFee: 3000, maxFee: 10_000, volatilityTickThreshold: 50});

        PoolKey memory adminKey = _defaultPoolKey(IHooks(address(orchestrator)));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HookRigBase.OnlyPoolAdmin.selector, bob));
        orchestrator.registerPoolStack(adminKey, adminCfg);

        vm.prank(alice);
        orchestrator.registerPoolStack(adminKey, adminCfg);
    }

    /// @notice Regression #2: `DynamicFee` EWMA ceiling & intra-block tick preservation (`#56, #57`),
    ///         `MEVProtection` first-swap anchor & dust-swap anti-griefing (`#61, #62`),
    ///         `ArbRecapture` referenceTick preservation (`#11–#13`), and `CircuitBreaker` bounded rollover (`#68`).
    function test_Regression02_DynamicFee_MEVProtection_ArbRecapture_CircuitBreaker_Hardening() public {
        // 1. DynamicFee + ArbRecapture: sub-threshold swaps do not advance ArbRecapture referenceTick,
        //    so cumulative tick displacement across sub-threshold steps still triggers ArbRecapture!
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_DYNAMIC_FEE | HookPermissionMasks.BIT_ARB_RECAPTURE;
        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 3000, maxFee: 10_000, volatilityTickThreshold: 50});
        cfg.arbRecapture = IHookRigBlock.ArbRecaptureParams({recaptureShareBps: 5000, arbTriggerTickDelta: 50});

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        // Two sub-threshold swaps (~20 ticks < 50 trigger) cumulatively cross >= 50 ticks from referenceTick 0
        _swapExactIn(alice, key, true, 1_000 ether, "");
        assertEq(orchestrator.totalLPRewardsDonated(poolId), 0, "First sub-threshold step does not trigger recapture");

        _swapExactIn(alice, key, true, 25_000 ether, "");
        _flushLPDonations(key);
        assertGt(
            orchestrator.totalLPRewardsDonated(poolId),
            0,
            "Second step triggers ArbRecapture because referenceTick was not walked by first sub-threshold step"
        );

        // 2. MEVProtection: 1-tick dust swap does not arm opposite-direction lock for normal traders
        IHookRigBlock.PoolStackConfig memory mevCfg;
        mevCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_MEV_PROTECTION;
        mevCfg.mevProtection =
            IHookRigBlock.MEVProtectionParams({maxTickDeltaPerSwap: 200, minLPHoldBlocks: 5, jitExitPenaltyBps: 100});

        PoolKey memory mevKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(orchestrator))
        });
        orchestrator.registerPoolStack(mevKey, mevCfg);
        poolManager.initialize(mevKey, SQRT_PRICE_1_1);
        _seedFullRangeLiquidity(mevKey, 1_000_000 ether);

        // Tiny dust swap (0 or 1 tick) in direction zeroForOne=true does NOT lock out bob's opposite swap in same block
        _swapExactIn(alice, mevKey, true, 1 wei, "");
        _swapExactIn(bob, mevKey, false, 100 ether, "");
    }

    /// @notice Regression #3: `JITGuard` shared-router default-salt isolation (`#15–#20`) and
    ///         `AutoBuyback` same-transaction JIT liquidity addition guard (`#55`).
    function test_Regression03_JITGuardSharedRouterIsolation_And_AutoBuybackJITSandwichGuard() public {
        // 1. JITGuard: Alice and Bob using the same trusted router with salt=0 have isolated hold timers
        IHookRigBlock.PoolStackConfig memory jitCfg;
        jitCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_JIT_GUARD;
        jitCfg.mevProtection =
            IHookRigBlock.MEVProtectionParams({maxTickDeltaPerSwap: 0, minLPHoldBlocks: 10, jitExitPenaltyBps: 0});

        (PoolKey memory jitKey,) = _initPoolWithStack(jitCfg);
        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 10_000 ether, salt: bytes32(0)});
        ModifyLiquidityParams memory remParams =
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: -5_000 ether, salt: bytes32(0)});

        // Alice adds liquidity at block N
        vm.prank(alice);
        router.modifyLiquidity(jitKey, addParams, "");

        // At block N + 8, Bob adds liquidity with the same ticks and salt=0
        vm.roll(block.number + 8);
        vm.prank(bob);
        router.modifyLiquidity(jitKey, addParams, "");

        // At block N + 11 (past Alice's 10-block hold, despite Bob's add 3 blocks ago), Alice can remove cleanly!
        vm.roll(block.number + 3);
        vm.prank(alice);
        router.modifyLiquidity(jitKey, remParams, "");

        // 2. AutoBuyback: Adding liquidity in the same transaction suppresses floor buyback deployment
        IHookRigBlock.PoolStackConfig memory bbCfg;
        bbCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_AUTO_BUYBACK | HookPermissionMasks.BIT_LP_REWARDS;
        bbCfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 50});
        bbCfg.autoBuyback =
            IHookRigBlock.AutoBuybackParams({buybackFeeBps: 300, triggerFloorTick: -5, minBuybackReserve: 1 ether});

        PoolKey memory bbKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 20,
            hooks: IHooks(address(orchestrator))
        });
        orchestrator.registerPoolStack(bbKey, bbCfg);
        poolManager.initialize(bbKey, SQRT_PRICE_1_1);
        _seedFullRangeLiquidity(bbKey, 500_000 ether);

        // Accumulate currency0 buyback reserve across blocks
        _swapExactIn(alice, bbKey, false, 3000 ether, "");
        vm.roll(block.number + 1);
        _swapExactIn(bob, bbKey, true, 20_000 ether, "");
        uint256 orcBalBefore = poolManager.balanceOf(address(orchestrator), currency0.toId());
        assertGt(orcBalBefore, 1 ether);

        // Add liquidity AND sell in the SAME transaction -> currency0 reserve is NOT burned/deployed to JIT LP!
        vm.roll(block.number + 1);
        this.executeSameTxJITAddAndSell(bbKey, addParams);
        assertGe(
            poolManager.balanceOf(address(orchestrator), currency0.toId()),
            orcBalBefore,
            "AutoBuyback must not deploy accumulated reserve in same tx as liquidity addition"
        );
    }

    function executeSameTxJITAddAndSell(PoolKey memory bbKey, ModifyLiquidityParams memory addParams) external {
        vm.prank(carol);
        router.modifyLiquidity(bbKey, addParams, "");
        _swapExactIn(alice, bbKey, false, 500 ether, "");
    }

    /// @notice Regression #4: `WalletCap` on-chain balance seeding on first sell (`#34–#36`) and
    ///         `VestingSellCap` pre-settlement balance reconstruction at epoch initialization (`#30–#33`).
    function test_Regression04_WalletCapFirstSell_And_VestingSellCapPostSettlementEpochInit() public {
        // 1. WalletCap: Trader with existing ERC-20 balance selling first still has remaining balance enforced on buy
        IHookRigBlock.PoolStackConfig memory wcCfg;
        wcCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_WALLET_CAP;
        wcCfg.walletCap = IHookRigBlock.WalletCapParams({maxWalletBps: 100, sunsetBlocks: 1000}); // 1% cap

        (PoolKey memory wcKey,) = _initPoolWithStack(wcCfg);
        _seedFullRangeLiquidity(wcKey, 500_000 ether);

        address whaleHolder = address(0xBEEF88);
        uint256 onePercent = token1.totalSupply() / 100;
        token0.transfer(whaleHolder, 100_000 ether);
        token1.transfer(whaleHolder, onePercent); // Holds 100% of the 1% wallet cap via direct transfer (without changing totalSupply)
        vm.startPrank(whaleHolder);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();

        // Whale sells 10 ether, then tries to buy 50 ether (pushing above 1% cap) -> reverts because sell seeded balance!
        _swapExactIn(whaleHolder, wcKey, false, 10 ether, "");
        vm.expectRevert();
        _swapExactIn(whaleHolder, wcKey, true, 50 ether, "");

        // 2. VestingSellCap: Trader who received tokens via direct ERC-20 transfer cannot dump > maxDailySellBps on first sell
        IHookRigBlock.PoolStackConfig memory vsCfg;
        vsCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_VESTING_SELL_CAP;
        vsCfg.vestingSellCap = IHookRigBlock.VestingSellCapParams({maxDailySellBps: 1000}); // Max 10% per day

        PoolKey memory vsKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 30,
            hooks: IHooks(address(orchestrator))
        });
        orchestrator.registerPoolStack(vsKey, vsCfg);
        poolManager.initialize(vsKey, SQRT_PRICE_1_1);
        _seedFullRangeLiquidity(vsKey, 500_000 ether);

        address freshHolder = address(0xDEAD99);
        token1.mint(freshHolder, 1000 ether);
        vm.prank(freshHolder);
        token1.approve(address(router), type(uint256).max);

        // Attempting to sell 600 ether (60% of 1000 ether balance, leaving 400 ether post-settlement) must revert!
        vm.expectRevert();
        _swapExactIn(freshHolder, vsKey, false, 600 ether, "");

        // Selling 60 ether (6% <= 10% cap) succeeds, and a second sell of 60 ether (total 120 > 100 ether cap) reverts!
        _swapExactIn(freshHolder, vsKey, false, 60 ether, "");
        vm.expectRevert();
        _swapExactIn(freshHolder, vsKey, false, 60 ether, "");
    }

    /// @notice Regression #5: `LimitOrders` re-opening a filled tick bucket after price returns (`#25–#27`)
    ///         and `TWAMM` 100% unswapped refund + dust order eviction (`#7–#9, #50, #66`).
    function test_Regression05_LimitOrdersBucketReopen_And_TWAMMDustEvictionAndFullRefund() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap =
            HookPermissionMasks.BIT_LIMIT_ORDERS | HookPermissionMasks.BIT_TWAMM | HookPermissionMasks.BIT_ORACLE;

        (PoolKey memory key,) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 500_000 ether);

        // 1. Place limit order at tick -60, cross it, claim it, move tick back above -60, and place a new order at -60
        vm.prank(alice);
        uint256 id1 = orchestrator.placeLimitOrder(key, -60, true, 50 ether);

        _swapExactIn(bob, key, true, 25_000 ether, "");

        vm.prank(alice);
        orchestrator.claimLimitOrder(key, id1);

        // Swap back so currentTick > -60
        _swapExactIn(bob, key, false, 30_000 ether, "");

        // Alice can now place a new limit order at tick -60 AND cancel it before fill (proving bucket re-opened!)
        vm.prank(alice);
        uint256 id2 = orchestrator.placeLimitOrder(key, -60, true, 50 ether);
        vm.prank(alice);
        orchestrator.cancelLimitOrder(key, id2);

        // 2. TWAMM: submit order, stream partial volume, claim output, and cancel remaining unstreamed input
        vm.prank(alice);
        uint256 twammId = orchestrator.submitTWAMMOrder(key, true, 3600 ether, 3600);
        vm.warp(block.timestamp + 1800);
        _swapExactIn(bob, key, true, 100 ether, "");

        uint256 outBefore = token1.balanceOf(alice);
        vm.prank(alice);
        (uint256 claimedOut,) = orchestrator.claimTWAMMOrder(key, twammId);
        assertGt(claimedOut, 0);
        assertEq(token1.balanceOf(alice) - outBefore, claimedOut);

        uint256 inBefore = token0.balanceOf(alice);
        vm.prank(alice);
        uint256 refundedIn = orchestrator.cancelTWAMMOrder(key, twammId);
        assertEq(refundedIn, 1800 ether);
        assertEq(token0.balanceOf(alice) - inBefore, 1800 ether);
    }

    /// @notice Regression #6: `KingOfThePool` zero-cut buy guard (`#43–#45`) and single-currency pot purity (`#3–#6, #10`).
    function test_Regression06_KingOfThePoolSingleCurrencyPurityAndZeroCutGuard() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_KING_OF_THE_POOL | HookPermissionMasks.BIT_LP_REWARDS;
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 50});
        cfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 100, roundDurationSeconds: 600, minBuyAmountForReset: 1 wei
        });

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 500_000 ether);

        // Alice makes a real buy -> becomes King of Round 1
        _swapExactIn(alice, key, true, 100 ether, "");
        (, address king1, uint256 pot1, uint64 deadline1) = orchestrator.getCurrentKing(poolId);
        assertEq(king1, alice);
        assertGt(pot1, 0);

        // Advance time by 100s; Bob makes a 1-wei buy where potContribution rounds to 0 -> cannot steal crown or reset timer!
        vm.warp(block.timestamp + 100);
        _swapExactIn(bob, key, true, 1 wei, "");
        (, address kingAfter,, uint64 deadlineAfter) = orchestrator.getCurrentKing(poolId);
        assertEq(kingAfter, alice, "Zero-contribution dust buy must not steal King crown");
        assertEq(deadlineAfter, deadline1, "Zero-contribution dust buy must not reset round deadline");
    }
}

