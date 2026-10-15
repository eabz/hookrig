// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookRigTestBase} from "../utils/HookRigTestBase.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHookRigBlock} from "../../src/interfaces/IHookRigBlock.sol";
import {HookPermissionMasks} from "../../src/libraries/HookPermissionMasks.sol";

import {DynamicFeeLogic} from "../../src/blocks/fees/DynamicFeeBlock.sol";
import {ManagedFeeBlock} from "../../src/blocks/fees/ManagedFeeBlock.sol";
import {MarketHoursFeeLogic} from "../../src/blocks/fees/MarketHoursFeeBlock.sol";
import {AntiSnipeLogic} from "../../src/blocks/protection/AntiSnipeBlock.sol";
import {JITGuardLogic} from "../../src/blocks/protection/JITGuardBlock.sol";
import {MEVProtectionBlock} from "../../src/blocks/protection/MEVProtectionBlock.sol";
import {ArbRecaptureLogic} from "../../src/blocks/protection/ArbRecaptureBlock.sol";
import {AccessControlBlock, AccessControlLogic} from "../../src/blocks/protection/AccessControlBlock.sol";
import {CircuitBreakerLogic} from "../../src/blocks/protection/CircuitBreakerBlock.sol";
import {WalletCapLogic} from "../../src/blocks/token-rules/WalletCapBlock.sol";
import {BuySellTaxBlock, BuySellTaxLogic} from "../../src/blocks/token-rules/BuySellTaxBlock.sol";
import {AutoBurnBlock} from "../../src/blocks/token-rules/AutoBurnBlock.sol";
import {VestingSellCapLogic} from "../../src/blocks/token-rules/VestingSellCapBlock.sol";
import {FeeSharingLogic} from "../../src/blocks/rewards/FeeSharingBlock.sol";
import {LPRewardsBlock} from "../../src/blocks/rewards/LPRewardsBlock.sol";
import {KingOfThePoolLogic} from "../../src/blocks/rewards/KingOfThePoolBlock.sol";
import {ReferralSplitLogic} from "../../src/blocks/rewards/ReferralSplitBlock.sol";
import {AutoBuybackLogic} from "../../src/blocks/rewards/AutoBuybackBlock.sol";
import {LimitOrdersLogic} from "../../src/blocks/trading/LimitOrdersBlock.sol";
import {TWAMMLogic} from "../../src/blocks/trading/TWAMMBlock.sol";

contract BuySellTaxHarness is BuySellTaxBlock {
    function initTax(PoolId poolId, BuySellTaxParams calldata params) external {
        _initBuySellTax(poolId, params);
    }

    function updateTax(PoolId poolId, uint16 newBuyTaxBps, uint16 newSellTaxBps, address newRecipient) external {
        _updateBuySellTax(poolId, newBuyTaxBps, newSellTaxBps, newRecipient);
    }

    function getTax(PoolId poolId, bool isBuy) external view returns (uint16, address) {
        return _getApplicableTaxBps(poolId, isBuy);
    }
}

/// @title BlocksUnitTest
/// @notice Unit and security-revert tests for all 22 HookRig blocks (17 Core + 5 Expansion).
contract BlocksUnitTest is HookRigTestBase {
    using PoolIdLibrary for PoolKey;

    // =========================================================================
    // Group 1: Fees (Blocks #1, #2, #3)
    // =========================================================================

    function test_Block01_DynamicFee_VolatilityScalingAndBounds() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_DYNAMIC_FEE;
        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 3000, maxFee: 10_000, volatilityTickThreshold: 40});

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        assertTrue(orchestrator.isBlockEnabled(poolId, IHookRigBlock.BlockId.DynamicFee));
        assertEq(orchestrator.getPoolEnabledBlocks(poolId), HookPermissionMasks.BIT_DYNAMIC_FEE);

        _seedFullRangeLiquidity(key, 1_000_000 ether);

        // First swap at zero volatility uses baseFee
        _swapExactIn(alice, key, true, 10_000 ether, "");

        // Advance block and swap again so EMA rolling volatility > 0
        vm.roll(block.number + 1);
        _swapExactIn(bob, key, false, 25_000 ether, "");

        // Same-block spike swap
        _swapExactIn(alice, key, true, 30_000 ether, "");

        // Revert on invalid bounds (maxFee > 50_000 or baseFee > maxFee)
        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 60_000, maxFee: 50_000, volatilityTickThreshold: 40});
        PoolKey memory badKey = key;
        badKey.tickSpacing = 120;
        vm.expectRevert(abi.encodeWithSelector(DynamicFeeLogic.InvalidDynamicFeeBounds.selector, 60_000, 50_000));
        orchestrator.registerPoolStack(badKey, cfg);
    }

    function test_Block02_ManagedFee_UpdateAndHardCap() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_MANAGED_FEE;
        cfg.managedFee = IHookRigBlock.ManagedFeeParams({startingFee: 2500, feeCap: 15_000, manager: alice});

        (PoolKey memory key,) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        // Non-manager cannot update fee
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ManagedFeeBlock.UnauthorizedFeeManager.selector, bob));
        orchestrator.setManagedPoolFee(key, 5000);

        // Manager cannot exceed feeCap
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ManagedFeeBlock.ManagedFeeExceedsCap.selector, 20_000, 15_000));
        orchestrator.setManagedPoolFee(key, 20_000);

        // Valid manager update succeeds
        vm.prank(alice);
        orchestrator.setManagedPoolFee(key, 8000);
        _swapExactIn(bob, key, true, 100 ether, "");
    }

    function test_Block03_MarketHoursFee_OpenClosedWeekendAndWraparound() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_MARKET_HOURS_FEE;
        cfg.marketHoursFee = IHookRigBlock.MarketHoursFeeParams({
            openFee: 1000, closedFee: 10_000, openHourUtc: 13, closeHourUtc: 20, weekendClosed: true
        });

        (PoolKey memory key,) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        // 2023-11-15 15:00 UTC (Wednesday, inside 13..20 open hours)
        vm.warp(1_700_060_400);
        _swapExactIn(alice, key, true, 100 ether, "");

        // 2023-11-15 22:00 UTC (Wednesday, outside open hours -> closedFee)
        vm.warp(1_700_085_600);
        _swapExactIn(alice, key, true, 100 ether, "");

        // 2023-11-18 15:00 UTC (Saturday -> weekendClosed)
        vm.warp(1_700_319_600);
        _swapExactIn(alice, key, true, 100 ether, "");

        // Overnight wraparound schedule (openHourUtc = 22, closeHourUtc = 6)
        PoolKey memory keyWrap = key;
        keyWrap.tickSpacing = 120;
        cfg.marketHoursFee.openHourUtc = 22;
        cfg.marketHoursFee.closeHourUtc = 6;
        cfg.marketHoursFee.weekendClosed = false;
        orchestrator.registerPoolStack(keyWrap, cfg);
        poolManager.initialize(keyWrap, SQRT_PRICE_1_1);
        _seedFullRangeLiquidity(keyWrap, 1_000_000 ether);
        vm.warp(1_700_089_200); // 23:00 UTC
        _swapExactIn(alice, keyWrap, true, 100 ether, "");

        // Invalid config (openHourUtc >= 24)
        PoolKey memory badKey = key;
        badKey.tickSpacing = 180;
        cfg.marketHoursFee.openHourUtc = 25;
        vm.expectRevert(MarketHoursFeeLogic.InvalidMarketHoursConfig.selector);
        orchestrator.registerPoolStack(badKey, cfg);
    }

    // =========================================================================
    // Group 2: Protection & Access (Blocks #4, #5 + #18, #6, #7, #19)
    // =========================================================================

    function test_Block04_AntiSnipe_LinearDecayAndGraduationReset() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_ANTI_SNIPE;
        cfg.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 500_000, normalFee: 3000, decayBlocks: 100});

        (PoolKey memory key,) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        // Block 0 of launch: high fee
        BalanceDelta d0 = _swapExactIn(alice, key, true, 1000 ether, "");

        // Block +50: half decayed fee -> trader receives more output for same input
        vm.roll(block.number + 50);
        BalanceDelta d50 = _swapExactIn(bob, key, true, 1000 ether, "");
        assertGt(d50.amount1(), d0.amount1());

        // Block +150: fully decayed to normalFee
        vm.roll(block.number + 100);
        BalanceDelta d150 = _swapExactIn(carol, key, true, 1000 ether, "");
        assertGt(d150.amount1(), d50.amount1());

        // Invalid config revert
        PoolKey memory badKey = key;
        badKey.tickSpacing = 120;
        cfg.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 900_000, normalFee: 3000, decayBlocks: 10});
        vm.expectRevert(abi.encodeWithSelector(AntiSnipeLogic.InvalidAntiSnipeConfig.selector, 900_000, 3000));
        orchestrator.registerPoolStack(badKey, cfg);
    }

    function test_Block05_And_18_MEVProtection_PriceImpactAndJITGuard() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_MEV_PROTECTION;
        cfg.mevProtection =
            IHookRigBlock.MEVProtectionParams({maxTickDeltaPerSwap: 50, minLPHoldBlocks: 5, jitExitPenaltyBps: 100});

        (PoolKey memory key,) = _initPoolWithStack(cfg);

        // Alice adds liquidity at block 10_000
        vm.prank(alice);
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100_000 ether, salt: bytes32(0)}),
            ""
        );

        // Same-block JIT removal reverts with JITLiquidityCooldownActive
        vm.prank(alice);
        vm.expectRevert();
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: -50_000 ether, salt: bytes32(0)}),
            ""
        );

        // Huge swap exceeding maxTickDeltaPerSwap (50 ticks) reverts with SwapPriceImpactExceeded
        vm.expectRevert();
        _swapExactIn(bob, key, true, 50_000 ether, "");

        // Small swap within 50 ticks succeeds
        _swapExactIn(bob, key, true, 100 ether, "");

        // Advance 5 blocks -> Alice can now remove LP freely
        vm.roll(block.number + 5);
        vm.prank(alice);
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: -50_000 ether, salt: bytes32(0)}),
            ""
        );
    }

    function test_Block06_ArbRecapture_DislocationSpreadToLPs() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_ARB_RECAPTURE;
        cfg.arbRecapture = IHookRigBlock.ArbRecaptureParams({recaptureShareBps: 5000, arbTriggerTickDelta: 5});

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 500_000 ether);

        // Large dislocation swap triggers arb recapture and donates to LPs
        _swapExactIn(alice, key, true, 15_000 ether, "");
        assertEq(orchestrator.totalLPRewardsDonated(poolId), 0, "donation is queued, not paid in the same swap");
        assertGt(orchestrator.pendingLPDonation(poolId, currency1), 0);
        _flushLPDonations(key);
        assertGt(orchestrator.totalLPRewardsDonated(poolId), 0);

        // Advance block and swap again to update referenceTick
        vm.roll(block.number + 1);
        _swapExactIn(bob, key, false, 20_000 ether, "");

        // Revert if recaptureShareBps > 8000
        PoolKey memory badKey = key;
        badKey.tickSpacing = 120;
        cfg.arbRecapture.recaptureShareBps = 9000;
        vm.expectRevert(abi.encodeWithSelector(ArbRecaptureLogic.ArbRecaptureShareTooHigh.selector, 9000));
        orchestrator.registerPoolStack(badKey, cfg);
    }

    function test_Block07_AccessControl_AllowlistAndMerkleProof() public {
        bytes32 leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice))));
        bytes32 leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob))));
        bytes32 root = leafAlice < leafBob
            ? keccak256(abi.encodePacked(leafAlice, leafBob))
            : keccak256(abi.encodePacked(leafBob, leafAlice));

        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_ACCESS_CONTROL;
        cfg.accessControl = IHookRigBlock.AccessControlParams({
            checkBeforeAddLiquidity: true, checkBeforeSwap: true, merkleRoot: root, manager: owner
        });

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);

        // Allowlist address(this) so we can seed liquidity
        vm.prank(owner);
        orchestrator.setAllowlistAccount(poolId, address(this), true);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        // Unauthorized manager revert
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(AccessControlBlock.UnauthorizedAccessControlManager.selector, carol));
        orchestrator.setAllowlistAccount(poolId, carol, true);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(AccessControlBlock.UnauthorizedAccessControlManager.selector, carol));
        orchestrator.setAccessMerkleRoot(poolId, bytes32(0));

        // Carol (not allowlisted, no proof) cannot swap
        vm.expectRevert();
        _swapExactIn(carol, key, true, 100 ether, "");

        // Alice swaps using zero-copy calldata Merkle proof: abi.encodePacked(abi.encode(alice), leafBob)
        bytes memory proofData = abi.encodePacked(abi.encode(alice), leafBob);
        _swapExactIn(alice, key, true, 100 ether, proofData);

        // Update Merkle root
        vm.prank(owner);
        orchestrator.setAccessMerkleRoot(poolId, root);
    }

    function test_Block19_CircuitBreaker_RollingPriceBand() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_CIRCUIT_BREAKER;
        cfg.circuitBreaker = IHookRigBlock.CircuitBreakerParams({maxWindowTickDeviation: 30, windowSeconds: 300});

        (PoolKey memory key,) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 100_000 ether);

        // Small swap inside 30-tick deviation succeeds
        _swapExactIn(alice, key, true, 50 ether, "");

        // Large swap moving price > 30 ticks within the 300s window reverts with CircuitBreakerTriggered
        vm.expectRevert();
        _swapExactIn(bob, key, true, 10_000 ether, "");

        // Advance past window (301s) -> window anchor resets
        vm.warp(block.timestamp + 301);
        _swapExactIn(bob, key, true, 50 ether, "");
    }

    // =========================================================================
    // Group 3: Token Rules (Blocks #8, #9, #10, #21)
    // =========================================================================

    function test_Block08_WalletCap_MaxHoldingsAndSunset() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_WALLET_CAP;
        cfg.walletCap = IHookRigBlock.WalletCapParams({maxWalletBps: 500, sunsetBlocks: 50}); // 5% of totalSupply

        (PoolKey memory key,) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 10_000_000 ether);

        address whale = address(0xBEEF);
        token0.mint(whale, 500_000_000 ether);
        vm.prank(whale);
        token0.approve(address(router), type(uint256).max);

        // Buying within 5% cap succeeds
        _swapExactIn(whale, key, true, 1000 ether, "");

        // Buying above 5% of totalSupply reverts with WalletCapExceeded
        uint256 supply = token1.totalSupply();
        token1.mint(whale, (supply * 600) / 10_000);
        vm.expectRevert();
        _swapExactIn(whale, key, true, 1000 ether, "");

        // Selling is NEVER blocked even if whale holds > 5%
        vm.prank(whale);
        token1.approve(address(router), type(uint256).max);
        _swapExactIn(whale, key, false, 500 ether, "");

        // Advance past sunsetBlocks (50 blocks) -> whale can buy freely
        vm.roll(block.number + 55);
        _swapExactIn(whale, key, true, 1000 ether, "");

        // Anti-honeypot floor check: maxWalletBps < 10 (0.10%) reverts
        PoolKey memory badKey = key;
        badKey.tickSpacing = 120;
        cfg.walletCap.maxWalletBps = 5;
        vm.expectRevert(abi.encodeWithSelector(WalletCapLogic.InvalidWalletCapBps.selector, 5));
        orchestrator.registerPoolStack(badKey, cfg);
    }

    function test_Block09_BuySellTax_ClaimsAndBounds() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_BUY_SELL_TAX;
        cfg.buySellTax =
            IHookRigBlock.BuySellTaxParams({buyTaxBps: 200, sellTaxBps: 300, taxRecipient: treasury, decayOnly: true});

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        // Buy swap -> 2% tax credited in currency1 to treasury + 5 bps protocol royalty to PROTOCOL_ROYALTY_RECIPIENT
        _swapExactIn(alice, key, true, 1000 ether, "");
        uint256 claim1 = orchestrator.poolClaims(poolId, currency1, treasury);
        assertGt(claim1, 0);
        assertGt(orchestrator.poolClaims(poolId, currency1, orchestrator.PROTOCOL_ROYALTY_RECIPIENT()), 0);

        // Sell swap -> 3% tax credited in currency0 to treasury + 5 bps protocol royalty to PROTOCOL_ROYALTY_RECIPIENT
        _swapExactIn(bob, key, false, 1000 ether, "");
        uint256 claim0 = orchestrator.poolClaims(poolId, currency0, treasury);
        assertGt(claim0, 0);
        assertGt(orchestrator.poolClaims(poolId, currency0, orchestrator.PROTOCOL_ROYALTY_RECIPIENT()), 0);

        // Treasury pulls ERC-6909 claims via withdrawClaim (including amount == 0 full-balance convenience withdrawal)
        uint256 balBefore = token1.balanceOf(treasury);
        vm.prank(treasury);
        orchestrator.withdrawClaim(poolId, currency1, claim1, treasury);
        assertEq(token1.balanceOf(treasury) - balBefore, claim1);

        uint256 bal0Before = token0.balanceOf(treasury);
        vm.prank(treasury);
        orchestrator.withdrawClaim(poolId, currency0, 0, treasury);
        assertEq(token0.balanceOf(treasury) - bal0Before, claim0);

        // Pool admin (address(this)) can lower buy/sell tax on orchestrator via setBuySellTax; non-admin reverts
        vm.prank(alice);
        vm.expectRevert();
        orchestrator.setBuySellTax(poolId, 100, 150, charity);
        orchestrator.setBuySellTax(poolId, 100, 150, charity);

        // Revert on tax > 10% (1000 bps)
        PoolKey memory badKey = key;
        badKey.tickSpacing = 120;
        cfg.buySellTax.buyTaxBps = 1500;
        vm.expectRevert(abi.encodeWithSelector(BuySellTaxLogic.TaxExceedsHardCap.selector, 1500, 300));
        orchestrator.registerPoolStack(badKey, cfg);

        // Revert on zero taxRecipient when tax > 0
        cfg.buySellTax.buyTaxBps = 200;
        cfg.buySellTax.taxRecipient = address(0);
        vm.expectRevert(BuySellTaxLogic.InvalidTaxRecipient.selector);
        orchestrator.registerPoolStack(badKey, cfg);

        // Test BuySellTaxBlock._updateBuySellTax & decayOnly anti-honeypot enforcement
        BuySellTaxHarness harness = new BuySellTaxHarness();
        harness.initTax(
            poolId,
            IHookRigBlock.BuySellTaxParams({buyTaxBps: 300, sellTaxBps: 400, taxRecipient: treasury, decayOnly: true})
        );

        // Increasing tax in decayOnly mode reverts
        vm.expectRevert(BuySellTaxLogic.TaxIncreaseForbiddenInDecayOnlyMode.selector);
        harness.updateTax(poolId, 350, 400, treasury);

        // Updating above hard cap reverts
        vm.expectRevert(abi.encodeWithSelector(BuySellTaxLogic.TaxExceedsHardCap.selector, 1200, 200));
        harness.updateTax(poolId, 1200, 200, treasury);

        // Updating with zero recipient when buyTax > 0 reverts
        vm.expectRevert(BuySellTaxLogic.InvalidTaxRecipient.selector);
        harness.updateTax(poolId, 100, 100, address(0));

        // Decreasing tax and rotating recipient succeeds
        harness.updateTax(poolId, 100, 150, charity);
        (uint16 bTax, address rec) = harness.getTax(poolId, true);
        assertEq(bTax, 100);
        assertEq(rec, charity);
    }

    function test_Block10_AutoBurn_BurnCallAndDeadAddressModes() public {
        // Mode 1: ERC20Burnable.burn(amount)
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_AUTO_BURN;
        cfg.autoBurn = IHookRigBlock.AutoBurnParams({burnOnBuyBps: 250, useTokenBurnCall: true});

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        uint256 supplyBefore = token1.totalSupply();
        _swapExactIn(alice, key, true, 1000 ether, "");
        uint256 burned = orchestrator.totalAutoBurnedByPool(poolId);
        assertGt(burned, 0);
        assertEq(supplyBefore - token1.totalSupply(), burned);

        // Mode 2: Transfer to 0xdead
        PoolKey memory keyDead = key;
        keyDead.tickSpacing = 120;
        cfg.autoBurn = IHookRigBlock.AutoBurnParams({burnOnBuyBps: 250, useTokenBurnCall: false});
        orchestrator.registerPoolStack(keyDead, cfg);
        poolManager.initialize(keyDead, SQRT_PRICE_1_1);
        _seedFullRangeLiquidity(keyDead, 1_000_000 ether);

        _swapExactIn(bob, keyDead, true, 1000 ether, "");
        assertGt(token1.balanceOf(address(0xdead)), 0);

        // Revert on burnOnBuyBps > 500
        PoolKey memory badKey = key;
        badKey.tickSpacing = 180;
        cfg.autoBurn.burnOnBuyBps = 600;
        vm.expectRevert(abi.encodeWithSelector(AutoBurnBlock.AutoBurnExceedsCap.selector, 600));
        orchestrator.registerPoolStack(badKey, cfg);
    }

    function test_Block21_VestingSellCap_DailyEpochEnforcement() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_VESTING_SELL_CAP;
        cfg.vestingSellCap = IHookRigBlock.VestingSellCapParams({maxDailySellBps: 1000}); // Max 10% of holdings per day

        (PoolKey memory key,) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        address teamSeller = address(0x7EA4);
        token1.mint(teamSeller, 10_000 ether);
        vm.prank(teamSeller);
        token1.approve(address(router), type(uint256).max);

        // Selling 800 ether (8% of 10,000 ether) succeeds
        _swapExactIn(teamSeller, key, false, 800 ether, "");

        // Selling another 300 ether in the same 24h epoch (> 10% total) reverts with DailyVestingSellCapExceeded
        vm.expectRevert();
        _swapExactIn(teamSeller, key, false, 300 ether, "");

        // Advance 1 day -> new epoch starts, selling succeeds
        vm.warp(block.timestamp + 1 days + 1);
        _swapExactIn(teamSeller, key, false, 500 ether, "");

        // Anti-honeypot floor check: maxDailySellBps < 50 reverts
        PoolKey memory badKey = key;
        badKey.tickSpacing = 120;
        cfg.vestingSellCap.maxDailySellBps = 10;
        vm.expectRevert(abi.encodeWithSelector(VestingSellCapLogic.InvalidDailySellCapBps.selector, 10));
        orchestrator.registerPoolStack(badKey, cfg);
    }

    // =========================================================================
    // Group 4: Rewards & Income (Blocks #11, #12, #13, #14, #20, #22)
    // =========================================================================

    function test_Block11_FeeSharing_PrimaryAndSecondarySplits() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_FEE_SHARING;
        cfg.feeSharing = IHookRigBlock.FeeSharingParams({
            feeShareBps: 400,
            primaryRecipient: treasury,
            secondaryRecipient: charity,
            secondaryShareBps: 2500 // 25% of the 4% cut -> 1% charity, 3% treasury
        });

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        _swapExactIn(alice, key, true, 1000 ether, "");
        uint256 pClaim = orchestrator.poolClaims(poolId, currency1, treasury);
        uint256 sClaim = orchestrator.poolClaims(poolId, currency1, charity);
        assertGt(pClaim, 0);
        assertGt(sClaim, 0);
        assertApproxEqAbs(pClaim, sClaim * 3, 4);
    }

    function test_Block12_LPRewards_And_ZeroLiquidityFallback() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_LP_REWARDS;
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 300});

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        _swapExactIn(alice, key, true, 1000 ether, "");
        _flushLPDonations(key);
        assertGt(orchestrator.totalLPRewardsDonated(poolId), 0);

        // Cap check (> 500 bps)
        PoolKey memory badKey = key;
        badKey.tickSpacing = 120;
        cfg.lpRewards.extraBuyFeeBps = 600;
        vm.expectRevert(abi.encodeWithSelector(LPRewardsBlock.LPRewardExceedsCap.selector, 600));
        orchestrator.registerPoolStack(badKey, cfg);
    }

    function test_Block13_SwapRewards_VolumeLoyaltyPoints() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_SWAP_REWARDS;
        cfg.swapRewards = IHookRigBlock.SwapRewardsParams({pointsPerUnitVolume: 10e18});

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        _swapExactIn(alice, key, true, 500 ether, "");
        uint256 pts = orchestrator.swapRewardPoints(poolId, alice);
        assertGt(pts, 0);
        assertEq(orchestrator.totalPoolSwapPoints(poolId), pts);
    }

    function test_Block14_KingOfThePool_JackpotCountdownAndClaim() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_KING_OF_THE_POOL;
        cfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 300, roundDurationSeconds: 600, minBuyAmountForReset: 100 ether
        });

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        // Alice buys >= 100 ether -> crowned King of Round #1
        _swapExactIn(alice, key, true, 500 ether, "");
        (uint64 rId, address king, uint256 pot, uint64 deadline) = orchestrator.getCurrentKing(poolId);
        assertEq(rId, 1);
        assertEq(king, alice);
        assertGt(pot, 0);

        // Bob tries a tiny dust buy (< 100 ether) -> contributes to pot but does NOT reset deadline or steal King!
        vm.warp(block.timestamp + 100);
        _swapExactIn(bob, key, true, 10 ether, "");
        (, address kingAfterDust, uint256 potAfterDust, uint64 deadlineAfterDust) = orchestrator.getCurrentKing(poolId);
        assertEq(kingAfterDust, alice);
        assertEq(deadlineAfterDust, deadline);
        assertGt(potAfterDust, pot);

        // Advance past roundDeadline -> Alice claims Round #1 jackpot!
        vm.warp(deadline + 1);

        // Non-winner cannot claim
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KingOfThePoolLogic.NotRoundWinner.selector, bob, alice));
        orchestrator.claimKingPot(poolId, 1, bob);

        uint256 aliceBalBefore = token1.balanceOf(alice);
        vm.prank(alice);
        orchestrator.claimKingPot(poolId, 1, alice);
        assertEq(token1.balanceOf(alice) - aliceBalBefore, potAfterDust);

        // Double claim reverts
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KingOfThePoolLogic.RoundNotClaimable.selector, poolId, 1));
        orchestrator.claimKingPot(poolId, 1, alice);
    }

    function test_Block20_ReferralSplit_FirstTouchAndAntiSelfReferral() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_REFERRAL_SPLIT;
        cfg.referralSplit = IHookRigBlock.ReferralSplitParams({referralFeeBps: 150});

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        // Self-referral reverts
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ReferralSplitLogic.InvalidSelfReferral.selector, alice));
        orchestrator.registerReferrer(poolId, alice);

        // Alice registers Bob as referrer
        vm.prank(alice);
        orchestrator.registerReferrer(poolId, bob);
        assertEq(orchestrator.traderReferrer(poolId, alice), bob);

        // Alice swaps -> Bob receives ERC-6909 referral claim
        _swapExactIn(alice, key, true, 1000 ether, "");
        assertGt(orchestrator.poolClaims(poolId, currency1, bob), 0);
    }

    function test_Block22_AutoBuyback_ReserveAccumulationAndFloorTrigger() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_AUTO_BUYBACK;
        cfg.autoBuyback =
            IHookRigBlock.AutoBuybackParams({buybackFeeBps: 300, triggerFloorTick: -10, minBuybackReserve: 1 ether});

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 500_000 ether);

        // First buy moves tick up (> triggerFloorTick) -> accumulates reserve
        _swapExactIn(alice, key, false, 5000 ether, "");

        // Next swap pushes tick down below -10 -> triggers floor buyback donation to LPs
        _swapExactIn(bob, key, true, 15_000 ether, "");
        _flushLPDonations(key);
        assertGt(orchestrator.totalLPRewardsDonated(poolId), 0);
    }

    // =========================================================================
    // Group 5: Trading (Blocks #15, #16, #17)
    // =========================================================================

    function test_Block15_LimitOrders_PlaceCancelAndTickCrossing() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_LIMIT_ORDERS;

        (PoolKey memory key,) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 500_000 ether);

        // Alice places two limit orders (one at tick -60, one at tick 60)
        vm.startPrank(alice);
        uint256 orderDown = orchestrator.placeLimitOrder(key, -60, true, 100 ether);
        uint256 orderUp = orchestrator.placeLimitOrder(key, 60, false, 100 ether);
        uint256 orderToCancel = orchestrator.placeLimitOrder(key, 120, false, 50 ether);
        vm.stopPrank();
        assertEq(orderDown, 1);
        assertEq(orderUp, 2);

        // Non-maker cannot cancel
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LimitOrdersLogic.NotOrderMaker.selector, bob));
        orchestrator.cancelLimitOrder(key, orderToCancel);

        // Alice cancels orderToCancel and recovers funds
        uint256 balBefore = token1.balanceOf(alice);
        vm.prank(alice);
        orchestrator.cancelLimitOrder(key, orderToCancel);
        assertEq(token1.balanceOf(alice) - balBefore, 50 ether);

        // Swap downward across tick -60 -> fills bucket at -60
        _swapExactIn(bob, key, true, 25_000 ether, "");

        // A filled but unclaimed order can still be cancelled: its input never left escrow
        uint256 aliceBefore = token0.balanceOf(alice);
        vm.prank(alice);
        orchestrator.cancelLimitOrder(key, orderDown);
        assertGt(token0.balanceOf(alice), aliceBefore);

        // Swap upward across tick +60 -> fills bucket at +60
        _swapExactIn(bob, key, false, 50_000 ether, "");
    }

    function test_Block16_TWAMM_OrdersDisabled() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_TWAMM;

        (PoolKey memory key,) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        // TWAMM never swaps deposits, so new orders are rejected instead of escrowing funds that cannot pay out
        vm.prank(alice);
        vm.expectRevert(TWAMMLogic.TWAMMOrdersDisabled.selector);
        orchestrator.submitTWAMMOrder(key, true, 3600 ether, 3600);

        // Swaps on a TWAMM pool keep working
        vm.warp(block.timestamp + 600);
        _swapExactIn(carol, key, true, 100 ether, "");
    }

    function test_Block17_Oracle_TruncatedTWAPCheckpointing() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_ORACLE;

        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 500_000 ether);

        // Swap moves price significantly
        _swapExactIn(alice, key, true, 40_000 ether, "");

        // Advance 2 seconds -> next action checkpoints truncated tick delta
        vm.warp(block.timestamp + 2);
        _swapExactIn(bob, key, false, 100 ether, "");

        (int24 lastTick, int56 tickCumulative) = orchestrator.getOracleTickCumulative(poolId);
        assertTrue(lastTick != 0 || tickCumulative != 0);

        // beforeRemoveLiquidity also updates oracle checkpoint
        vm.warp(block.timestamp + 5);
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: -1000 ether, salt: bytes32(0)}),
            ""
        );
    }
}
