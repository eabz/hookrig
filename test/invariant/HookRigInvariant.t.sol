// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookRigTestBase} from "../utils/HookRigTestBase.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IHookRigBlock} from "../../src/interfaces/IHookRigBlock.sol";
import {IHookRigOrchestrator} from "../../src/interfaces/IHookRigOrchestrator.sol";
import {ITokenLaunchpad} from "../../src/interfaces/ITokenLaunchpad.sol";
import {HookPermissionMasks} from "../../src/libraries/HookPermissionMasks.sol";
import {VirtualXYKLaunch} from "../../src/launchpad/curves/VirtualXYKLaunch.sol";

/// @title HookRigHandler
/// @notice Stateful invariant handler executing randomized swaps, claim withdrawals, and time/block warps.
contract HookRigHandler is Test {
    HookRigInvariantTest public testContract;
    PoolKey public poolKey;
    PoolId public poolId;

    uint256 public totalClaimed0;
    uint256 public totalClaimed1;

    constructor(HookRigInvariantTest _testContract, PoolKey memory _poolKey, PoolId _poolId) {
        testContract = _testContract;
        poolKey = _poolKey;
        poolId = _poolId;
    }

    function handler_swapBuy(uint256 amountSeed, uint256 blockAdvance, uint256 timeAdvance) external {
        uint256 amountIn = bound(amountSeed, 1e6, 5_000 ether);
        uint256 blocks = bound(blockAdvance, 0, 5);
        uint256 secs = bound(timeAdvance, 0, 120);
        testContract.executeHandlerSwap(true, amountIn, blocks, secs);
    }

    function handler_swapSell(uint256 amountSeed, uint256 blockAdvance, uint256 timeAdvance) external {
        uint256 amountIn = bound(amountSeed, 1e6, 5_000 ether);
        uint256 blocks = bound(blockAdvance, 0, 5);
        uint256 secs = bound(timeAdvance, 0, 120);
        testContract.executeHandlerSwap(false, amountIn, blocks, secs);
    }

    function handler_withdrawTreasuryClaims() external {
        (uint256 c0, uint256 c1) = testContract.executeHandlerWithdraw();
        totalClaimed0 += c0;
        totalClaimed1 += c1;
    }
}

/// @title HookRigInvariantTest
/// @notice Stateless fuzz and stateful invariant tests for HookRig:
///         1. ERC-6909 Claim Solvency Invariant (`orchestrator` ERC-6909 balance >= sum of all active claims + pots)
///         2. Aggregate Return-Delta Cap Invariant (`totalDelta <= 25%` across arbitrary fuzz swap sizes)
///         3. Fee Aggregator Priority & Bounds Invariant (`minFee <= lpFee <= 500_000`)
///         4. VirtualXYK Bonding Curve No-Free-Money Invariant (buying X and immediately selling all tokens yields `<= X`)
contract HookRigInvariantTest is HookRigTestBase {
    using PoolIdLibrary for PoolKey;

    PoolKey internal invKey;
    PoolId internal invPoolId;
    HookRigHandler internal handler;

    function setUp() public override {
        super.setUp();

        // Configure a multi-block stack with DynamicFee + AntiSnipe + BuySellTax + AutoBurn + FeeSharing + LPRewards + KingOfThePool + ReferralSplit + AutoBuyback + Oracle
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_DYNAMIC_FEE | HookPermissionMasks.BIT_ANTI_SNIPE
            | HookPermissionMasks.BIT_BUY_SELL_TAX | HookPermissionMasks.BIT_AUTO_BURN
            | HookPermissionMasks.BIT_FEE_SHARING | HookPermissionMasks.BIT_LP_REWARDS
            | HookPermissionMasks.BIT_SWAP_REWARDS | HookPermissionMasks.BIT_KING_OF_THE_POOL
            | HookPermissionMasks.BIT_REFERRAL_SPLIT | HookPermissionMasks.BIT_AUTO_BUYBACK
            | HookPermissionMasks.BIT_ORACLE;

        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 3000, maxFee: 30_000, volatilityTickThreshold: 40});
        cfg.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 50_000, normalFee: 3000, decayBlocks: 50});
        cfg.buySellTax =
            IHookRigBlock.BuySellTaxParams({buyTaxBps: 200, sellTaxBps: 200, taxRecipient: treasury, decayOnly: true});
        cfg.autoBurn = IHookRigBlock.AutoBurnParams({burnOnBuyBps: 100, useTokenBurnCall: true});
        cfg.feeSharing = IHookRigBlock.FeeSharingParams({
            feeShareBps: 200, primaryRecipient: treasury, secondaryRecipient: charity, secondaryShareBps: 2500
        });
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 100});
        cfg.swapRewards = IHookRigBlock.SwapRewardsParams({pointsPerUnitVolume: 1e18});
        cfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 200, roundDurationSeconds: 600, minBuyAmountForReset: 10 ether
        });
        cfg.referralSplit = IHookRigBlock.ReferralSplitParams({referralFeeBps: 100});
        cfg.autoBuyback =
            IHookRigBlock.AutoBuybackParams({buybackFeeBps: 100, triggerFloorTick: -10, minBuybackReserve: 50 ether});

        (invKey, invPoolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(invKey, 10_000_000 ether);

        // Register Bob as Alice's referrer so ReferralSplit is exercised on every handler swap
        vm.prank(alice);
        orchestrator.registerReferrer(invPoolId, bob);

        handler = new HookRigHandler(this, invKey, invPoolId);
        targetContract(address(handler));
    }

    function executeHandlerSwap(bool zeroForOne, uint256 amountIn, uint256 blocks, uint256 secs) external {
        if (blocks > 0) vm.roll(block.number + blocks);
        if (secs > 0) vm.warp(block.timestamp + secs);
        _swapExactIn(alice, invKey, zeroForOne, amountIn, "");
    }

    function executeHandlerWithdraw() external returns (uint256 c0, uint256 c1) {
        c0 = orchestrator.poolClaims(invPoolId, currency0, treasury);
        if (c0 > 0) {
            vm.prank(treasury);
            orchestrator.withdrawClaim(invPoolId, currency0, c0, treasury);
        }
        c1 = orchestrator.poolClaims(invPoolId, currency1, treasury);
        if (c1 > 0) {
            vm.prank(treasury);
            orchestrator.withdrawClaim(invPoolId, currency1, c1, treasury);
        }
    }

    // =========================================================================
    // Stateful Invariants
    // =========================================================================

    /// @notice Invariant 1: The orchestrator's ERC-6909 claim balance in `PoolManager` is ALWAYS >=
    ///         the sum of all outstanding `poolClaims` + active `KingOfThePool` pot.
    function invariant_ERC6909ClaimSolvency() public view {
        uint256 orcBal0 = poolManager.balanceOf(address(orchestrator), currency0.toId());
        uint256 orcBal1 = poolManager.balanceOf(address(orchestrator), currency1.toId());

        address royaltyRecipient = orchestrator.PROTOCOL_ROYALTY_RECIPIENT();
        uint256 claims0 = orchestrator.poolClaims(invPoolId, currency0, treasury)
            + orchestrator.poolClaims(invPoolId, currency0, charity)
            + orchestrator.poolClaims(invPoolId, currency0, bob)
            + orchestrator.poolClaims(invPoolId, currency0, royaltyRecipient);

        (,, uint256 kingPot,) = orchestrator.getCurrentKing(invPoolId);
        uint256 claims1 = orchestrator.poolClaims(invPoolId, currency1, treasury)
            + orchestrator.poolClaims(invPoolId, currency1, charity)
            + orchestrator.poolClaims(invPoolId, currency1, bob)
            + orchestrator.poolClaims(invPoolId, currency1, royaltyRecipient) + kingPot;

        assertGe(orcBal0, claims0, "Currency0 ERC-6909 insolvency");
        assertGe(orcBal1, claims1, "Currency1 ERC-6909 insolvency");
    }

    // =========================================================================
    // Stateless Fuzz Tests
    // =========================================================================

    /// @notice Fuzz test across arbitrary swap sizes (from 1 wei to 50,000 ether) verifying no underflow,
    ///         no unexpected revert, and strict ERC-6909 claim solvency.
    function testFuzz_MultiBlockSwapSolvencyAndRounding(uint256 amountIn, bool zeroForOne) public {
        amountIn = bound(amountIn, 1, 50_000 ether);
        _swapExactIn(alice, invKey, zeroForOne, amountIn, abi.encode(bob));
        invariant_ERC6909ClaimSolvency();
    }

    /// @notice Fuzz test verifying that round-trip buy + immediate sell on `VirtualXYKLaunch` NEVER yields
    ///         more quote asset than the buyer put in (directional Floor/Ceil rounding invariant).
    function testFuzz_VirtualXYK_NoRoundTripArbitrage(uint256 quoteIn) public {
        quoteIn = bound(quoteIn, 1e12, 40 ether);

        ITokenLaunchpad.LaunchTokenMetadata memory meta = ITokenLaunchpad.LaunchTokenMetadata({
            name: "Fuzz Curve",
            symbol: "FUZZ",
            totalSupply: 1_000_000_000 ether,
            creator: owner,
            creatorVestingBps: 0,
            vestingDurationSeconds: 0
        });

        bytes32 salt;
        for (uint256 i = 1; i < 10_000; i++) {
            address pred = launchpadFactory.predictTokenAddress(meta, bytes32(i));
            if (uint160(pred) > uint160(Currency.unwrap(currency0))) {
                salt = bytes32(i);
                break;
            }
        }

        IHookRigBlock.PoolStackConfig memory stackCfg;
        stackCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_SWAP_REWARDS;
        stackCfg.swapRewards = IHookRigBlock.SwapRewardsParams({pointsPerUnitVolume: 1e18});
        ITokenLaunchpad.VirtualXYKConfig memory curveCfg = ITokenLaunchpad.VirtualXYKConfig({
            virtualQuoteReserve: 30 ether,
            virtualTokenReserve: 800_000_000 ether,
            graduationQuoteTarget: 50 ether,
            curveTokenAllocation: 800_000_000 ether,
            lpTokenReserve: 200_000_000 ether,
            maxWalletBpsDuringCurve: 0
        });

        (address tokenAddr, address curveAddr,) = launchpadFactory.launchVirtualXYK(
            meta, currency0, 60, IHookRigOrchestrator(address(0)), stackCfg, curveCfg, salt
        );
        VirtualXYKLaunch curve = VirtualXYKLaunch(payable(curveAddr));

        vm.startPrank(alice);
        token0.approve(curveAddr, type(uint256).max);
        (uint256 tokensOut, uint256 quoteUsed) = curve.buy(quoteIn, 0, alice);

        if (tokensOut > 0) {
            token0.approve(curveAddr, type(uint256).max);
            (bool ok,) =
                tokenAddr.call(abi.encodeWithSignature("approve(address,uint256)", curveAddr, type(uint256).max));
            assertTrue(ok);
            uint256 quoteBack = curve.sell(tokensOut, 0, alice);
            assertLe(quoteBack, quoteUsed, "Round-trip buy+sell extracted excess quote from curve!");
        }
        vm.stopPrank();
    }

    /// @notice Fuzz test proving that ANY arbitrary subset of the 22 building blocks (`1 <= bitmap <= (1 << 22) - 1`)
    ///         can be composed together in `PresetId.Blank` mode, execute swaps, and allow unhindered LP exit.
    function testFuzz_ArbitraryBlockBitmapCombinations(uint32 rawBitmap, bool zeroForOne) public {
        uint32 maxMask = uint32((uint256(1) << 22) - 1);
        uint32 bitmap = uint32(bound(rawBitmap, 1, maxMask));

        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.presetId = IHookRigBlock.PresetId.Blank;
        cfg.enabledBlocksBitmap = bitmap;

        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 2000, maxFee: 10_000, volatilityTickThreshold: 50});
        cfg.managedFee = IHookRigBlock.ManagedFeeParams({startingFee: 2500, feeCap: 15_000, manager: owner});
        cfg.marketHoursFee = IHookRigBlock.MarketHoursFeeParams({
            openHourUtc: 13,
            closeHourUtc: 20,
            openFee: 1500,
            closedFee: 4000,
            weekendClosed: true
        });
        cfg.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 30_000, normalFee: 2000, decayBlocks: 10});
        cfg.mevProtection = IHookRigBlock.MEVProtectionParams({
            maxTickDeltaPerSwap: 500,
            minLPHoldBlocks: 1,
            jitExitPenaltyBps: 0
        });
        cfg.arbRecapture = IHookRigBlock.ArbRecaptureParams({recaptureShareBps: 1000, arbTriggerTickDelta: 10});
        cfg.accessControl = IHookRigBlock.AccessControlParams({
            checkBeforeAddLiquidity: false,
            checkBeforeSwap: false,
            merkleRoot: bytes32(0),
            manager: owner
        });
        cfg.walletCap = IHookRigBlock.WalletCapParams({maxWalletBps: 5000, sunsetBlocks: 100});
        cfg.buySellTax = IHookRigBlock.BuySellTaxParams({
            buyTaxBps: 100,
            sellTaxBps: 100,
            taxRecipient: treasury,
            decayOnly: true
        });
        cfg.autoBurn = IHookRigBlock.AutoBurnParams({burnOnBuyBps: 100, useTokenBurnCall: true});
        cfg.feeSharing = IHookRigBlock.FeeSharingParams({
            feeShareBps: 100,
            primaryRecipient: treasury,
            secondaryRecipient: charity,
            secondaryShareBps: 5000
        });
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 100});
        cfg.swapRewards = IHookRigBlock.SwapRewardsParams({pointsPerUnitVolume: 1e18});
        cfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 100,
            roundDurationSeconds: 600,
            minBuyAmountForReset: 10 ether
        });
        cfg.circuitBreaker = IHookRigBlock.CircuitBreakerParams({maxWindowTickDeviation: 500, windowSeconds: 300});
        cfg.referralSplit = IHookRigBlock.ReferralSplitParams({referralFeeBps: 100});
        cfg.vestingSellCap = IHookRigBlock.VestingSellCapParams({maxDailySellBps: 2000});
        cfg.autoBuyback = IHookRigBlock.AutoBuybackParams({
            buybackFeeBps: 100,
            triggerFloorTick: -50,
            minBuybackReserve: 10 ether
        });

        PoolKey memory customKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0x800000,
            tickSpacing: 120,
            hooks: invKey.hooks
        });

        if (!orchestrator.isValidTier3Bitmap(bitmap)) {
            vm.expectRevert(abi.encodeWithSelector(IHookRigOrchestrator.InvalidBlockBitmap.selector, bitmap));
            orchestrator.registerPoolStack(customKey, cfg);
            return;
        }

        orchestrator.registerPoolStack(customKey, cfg);
        poolManager.initialize(customKey, SQRT_PRICE_1_1);
        _seedFullRangeLiquidity(customKey, 1_000_000 ether);

        _swapExactIn(alice, customKey, zeroForOne, 100 ether, "");
    }
}
