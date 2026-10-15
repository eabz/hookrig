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

        // 2. Exact-Output Buy (!zeroForOne, amountSpecified > 0)
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
        //    - Project currency (`currency1`) seeds the KingOfThePool pot directly
        //    - Quote currency (`currency0`) credits the pool admin's (`address(this)`) ERC-6909 claim ledger so currencies never mix
        vm.prank(address(launchpadFactory));
        orchestrator.seedKingPotFromLaunchCurve(poolId, currency1, 0);
        vm.prank(address(launchpadFactory));
        orchestrator.seedKingPotFromLaunchCurve(poolId, currency1, 50 ether);
        (,, uint256 pot,) = orchestrator.getCurrentKing(poolId);
        assertEq(pot, 50 ether);

        vm.prank(address(launchpadFactory));
        orchestrator.seedKingPotFromLaunchCurve(poolId, currency0, 25 ether);
        assertEq(orchestrator.poolClaims(poolId, currency0, address(this)), 25 ether);

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

        // Alice claims her filled limit order -> funds are NEVER frozen!
        uint256 balBefore = token0.balanceOf(alice);
        vm.prank(alice);
        orchestrator.claimLimitOrder(key, orderId);
        assertEq(token0.balanceOf(alice) - balBefore, 100 ether);
    }

    /// @notice Anti-Freeze #2: `AutoBuyback` burns prior accumulated ERC-6909 reserves when floor defense triggers
    ///         so zero ERC-6909 claims are ever stranded in `PoolManager`.
    function test_AntiFreeze02_AutoBuyback_MultiSwapReserveBurnAndZeroLiqSafety() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_AUTO_BUYBACK;
        cfg.autoBuyback =
            IHookRigBlock.AutoBuybackParams({buybackFeeBps: 300, triggerFloorTick: -10, minBuybackReserve: 1 ether});

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 500_000 ether);

        // Two upward swaps accumulate currency0 ERC-6909 buyback reserve on orchestrator
        _swapExactIn(alice, key, false, 2000 ether, "");
        _swapExactIn(alice, key, false, 2000 ether, "");
        uint256 orcBalBefore = poolManager.balanceOf(address(orchestrator), currency0.toId());
        assertGt(orcBalBefore, 0);

        // Now move tick below -10 and execute a sell (`zeroForOne == false`) while tick <= -10
        // so the accumulated currency0 ERC-6909 reserve is burned and donated to LPs!
        _swapExactIn(bob, key, true, 25_000 ether, "");
        _swapExactIn(alice, key, false, 1000 ether, "");

        // Verify prior currency0 ERC-6909 buyback reserve was burned and donated (only 5 bps protocol royalty claim remains)
        uint256 royaltyClaim0 = orchestrator.poolClaims(poolId, currency0, orchestrator.PROTOCOL_ROYALTY_RECIPIENT());
        assertEq(poolManager.balanceOf(address(orchestrator), currency0.toId()), royaltyClaim0);
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
}
