// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookRigTestBase, MockBurnableERC20} from "../utils/HookRigTestBase.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

import {IHookRigBlock} from "../../src/interfaces/IHookRigBlock.sol";
import {IHookRigOrchestrator} from "../../src/interfaces/IHookRigOrchestrator.sol";
import {ITokenLaunchpad} from "../../src/interfaces/ITokenLaunchpad.sol";
import {HookPermissionMasks} from "../../src/libraries/HookPermissionMasks.sol";
import {HookRigToken} from "../../src/launchpad/HookRigToken.sol";
import {LaunchpadFactory} from "../../src/launchpad/LaunchpadFactory.sol";
import {VirtualXYKLaunch} from "../../src/launchpad/curves/VirtualXYKLaunch.sol";
import {SteppedTrancheLaunch} from "../../src/launchpad/curves/SteppedTrancheLaunch.sol";
import {NativeTickLaunch} from "../../src/launchpad/curves/NativeTickLaunch.sol";

/// @title LaunchpadSuiteTest
/// @notice End-to-end unit and integration tests for `LaunchpadFactory`, `HookRigToken`,
///         `VirtualXYKLaunch`, `SteppedTrancheLaunch`, and `NativeTickLaunch`.
contract LaunchpadSuiteTest is HookRigTestBase {
    using PoolIdLibrary for PoolKey;

    Currency internal quoteCurrency;
    MockBurnableERC20 internal quoteToken;

    function setUp() public override {
        super.setUp();
        // Deploy a low-address quote token or use currency0 so we can easily mine a salt where token > quoteToken
        quoteCurrency = currency0;
        quoteToken = token0;
    }

    function _mineSaltForTokenAboveQuote(ITokenLaunchpad.LaunchTokenMetadata memory meta, address quoteAddr)
        internal
        view
        returns (bytes32)
    {
        for (uint256 i = 1; i < 10_000; i++) {
            bytes32 candidate = bytes32(i);
            address predicted = launchpadFactory.predictTokenAddress(meta, candidate);
            if (uint160(predicted) > uint160(quoteAddr)) {
                return candidate;
            }
        }
        revert("Failed to mine salt");
    }

    function _mineSaltForTokenBelowQuote(ITokenLaunchpad.LaunchTokenMetadata memory meta, address quoteAddr)
        internal
        view
        returns (bytes32)
    {
        for (uint256 i = 1; i < 10_000; i++) {
            bytes32 candidate = bytes32(i);
            address predicted = launchpadFactory.predictTokenAddress(meta, candidate);
            if (uint160(predicted) <= uint160(quoteAddr)) {
                return candidate;
            }
        }
        revert("Failed to mine low salt");
    }

    // =========================================================================
    // 1. Factory Validation, Token Deployment & Creator Vesting
    // =========================================================================

    function test_Factory_CreatorVestingCapAndSaltSortingValidation() public {
        ITokenLaunchpad.LaunchTokenMetadata memory meta = ITokenLaunchpad.LaunchTokenMetadata({
            name: "HookRig Meme",
            symbol: "HRIG",
            totalSupply: 1_000_000_000 ether,
            creator: owner,
            creatorVestingBps: 1500, // 15% > 10% hard cap
            vestingDurationSeconds: 180 days
        });

        IHookRigBlock.PoolStackConfig memory stackCfg;
        ITokenLaunchpad.VirtualXYKConfig memory curveCfg = ITokenLaunchpad.VirtualXYKConfig({
            virtualQuoteReserve: 30 ether,
            virtualTokenReserve: 800_000_000 ether,
            graduationQuoteTarget: 50 ether,
            curveTokenAllocation: 800_000_000 ether,
            lpTokenReserve: 200_000_000 ether,
            maxWalletBpsDuringCurve: 200
        });

        // 1. Exceeding 10% creator vesting cap reverts
        vm.expectRevert(abi.encodeWithSelector(LaunchpadFactory.CreatorVestingExceedsCap.selector, 1500));
        launchpadFactory.launchVirtualXYK(
            meta, quoteCurrency, 60, IHookRigOrchestrator(address(0)), stackCfg, curveCfg, bytes32(uint256(1))
        );

        // 2. Salt that does not sort token > quoteAddr reverts (use high quote address 0xFF..FF to force failure)
        meta.creatorVestingBps = 500;
        Currency highQuote = Currency.wrap(address(type(uint160).max));
        vm.expectRevert();
        launchpadFactory.launchVirtualXYK(
            meta, highQuote, 60, IHookRigOrchestrator(address(0)), stackCfg, curveCfg, bytes32(uint256(1))
        );
    }

    // =========================================================================
    // 2. Curve Model #1: VirtualXYKLaunch (Pump.fun-style + Atomic v4 Graduation)
    // =========================================================================

    function test_VirtualXYKLaunch_BuySellRefundAndAtomicGraduation() public {
        ITokenLaunchpad.LaunchTokenMetadata memory meta = ITokenLaunchpad.LaunchTokenMetadata({
            name: "VirtualXYK Token",
            symbol: "VXYK",
            totalSupply: 1_000_000_000 ether,
            creator: owner,
            creatorVestingBps: 500, // 5% vested to creator (50M tokens)
            vestingDurationSeconds: 90 days
        });

        bytes32 salt = _mineSaltForTokenAboveQuote(meta, Currency.unwrap(quoteCurrency));

        IHookRigBlock.PoolStackConfig memory stackCfg;
        stackCfg.presetId = IHookRigBlock.PresetId.FairLaunch;
        stackCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_ANTI_SNIPE | HookPermissionMasks.BIT_BUY_SELL_TAX;
        stackCfg.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 50_000, normalFee: 3000, decayBlocks: 20});
        stackCfg.buySellTax =
            IHookRigBlock.BuySellTaxParams({buyTaxBps: 200, sellTaxBps: 200, taxRecipient: treasury, decayOnly: true});

        // 950M tokens go to curve: 750M for bonding, 200M for graduation LP
        ITokenLaunchpad.VirtualXYKConfig memory curveCfg = ITokenLaunchpad.VirtualXYKConfig({
            virtualQuoteReserve: 30 ether,
            virtualTokenReserve: 800_000_000 ether,
            graduationQuoteTarget: 50 ether,
            curveTokenAllocation: 750_000_000 ether,
            lpTokenReserve: 200_000_000 ether,
            maxWalletBpsDuringCurve: 5000 // 50% max wallet during curve
        });

        // Post-graduation walletCap (0 bps) < curve maxWalletBpsDuringCurve (5000 bps) reverts
        vm.expectRevert(abi.encodeWithSelector(LaunchpadFactory.PostGraduationWalletCapBelowCurveCap.selector, 0, 5000));
        launchpadFactory.launchVirtualXYK(
            meta, quoteCurrency, 60, IHookRigOrchestrator(address(0)), stackCfg, curveCfg, salt
        );

        stackCfg.walletCap = IHookRigBlock.WalletCapParams({maxWalletBps: 5000, sunsetBlocks: 100});

        (address tokenAddr, address curveAddr, PoolKey memory key) = launchpadFactory.launchVirtualXYK(
            meta, quoteCurrency, 60, IHookRigOrchestrator(address(0)), stackCfg, curveCfg, salt
        );

        VirtualXYKLaunch curve = VirtualXYKLaunch(payable(curveAddr));
        HookRigToken pToken = HookRigToken(tokenAddr);

        // Verify creator vesting wallet received 5% (50M tokens)
        address vestAddr = launchpadFactory.tokenToCreatorVesting(tokenAddr);
        assertTrue(vestAddr != address(0));
        assertEq(pToken.balanceOf(vestAddr), 50_000_000 ether);
        assertEq(pToken.creator(), owner);
        assertEq(pToken.factory(), address(launchpadFactory));

        // Double initialization reverts
        vm.expectRevert(VirtualXYKLaunch.AlreadyInitialized.selector);
        curve.initializeCurve(key, tokenAddr, curveCfg);

        // Direct unlockCallback reverts
        vm.expectRevert(VirtualXYKLaunch.OnlyPoolManagerUnlock.selector);
        curve.unlockCallback("");

        // Zero buy/sell reverts
        vm.expectRevert(VirtualXYKLaunch.ZeroAmount.selector);
        curve.buy(0, 0, alice);
        vm.expectRevert(VirtualXYKLaunch.ZeroAmount.selector);
        curve.sell(0, 0, alice);

        // Alice approves quoteToken and buys 10 ether worth on the curve
        vm.startPrank(alice);
        quoteToken.approve(curveAddr, type(uint256).max);

        // Slippage check reverts if minTokensOut is impossibly high
        vm.expectRevert();
        curve.buy(10 ether, 900_000_000 ether, alice);

        (uint256 aliceTokens, uint256 quoteUsed1) = curve.buy(10 ether, 1, address(0)); // recipient=0 defaults to msg.sender
        assertEq(quoteUsed1, 10 ether);
        assertGt(aliceTokens, 0);
        assertEq(pToken.balanceOf(alice), aliceTokens);

        // Alice sells half of her tokens back into the curve before graduation
        pToken.approve(curveAddr, type(uint256).max);
        vm.expectRevert(); // Slippage check on sell
        curve.sell(aliceTokens / 2, 100 ether, alice);

        uint256 quoteRefunded = curve.sell(aliceTokens / 2, 1, address(0));
        assertGt(quoteRefunded, 0);
        assertLt(quoteRefunded, 10 ether); // Round-trip buy+sell never profits against the curve
        vm.stopPrank();

        // Bob buys with excess quote (100 ether when < 50 ether remains to graduation target)
        // Verifies cap-and-refund at graduation and atomic v4 pool initialization + LP seeding!
        vm.startPrank(bob);
        quoteToken.approve(curveAddr, type(uint256).max);
        uint256 bobQuoteBefore = quoteToken.balanceOf(bob);
        (uint256 bobTokens, uint256 bobQuoteUsed) = curve.buy(100 ether, 1, bob);
        vm.stopPrank();

        assertGt(bobTokens, 0);
        assertLt(bobQuoteUsed, 50 ether);
        assertEq(bobQuoteBefore - quoteToken.balanceOf(bob), bobQuoteUsed);
        assertEq(uint8(curve.launchState()), uint8(ITokenLaunchpad.LaunchState.Graduated));
        assertEq(curve.realQuoteRaised(), 50 ether);

        // Buying or selling on the curve after graduation reverts with CurveNotActive
        vm.prank(alice);
        vm.expectRevert(VirtualXYKLaunch.CurveNotActive.selector);
        curve.buy(1 ether, 0, alice);

        vm.prank(alice);
        vm.expectRevert(VirtualXYKLaunch.CurveNotActive.selector);
        curve.sell(1 ether, 0, alice);

        // Now Carol can swap directly on the graduated Uniswap v4 pool with HookRig blocks active!
        _swapExactIn(carol, key, true, 1 ether, "");
        assertGt(pToken.balanceOf(carol), 0);
    }

    function test_VirtualXYKLaunch_NativeETHQuoteAndWalletCap() public {
        Currency ethCurrency = Currency.wrap(address(0));
        ITokenLaunchpad.LaunchTokenMetadata memory meta = ITokenLaunchpad.LaunchTokenMetadata({
            name: "ETH Virtual Token",
            symbol: "ETHV",
            totalSupply: 1_000_000_000 ether,
            creator: owner,
            creatorVestingBps: 0,
            vestingDurationSeconds: 0
        });

        bytes32 salt = _mineSaltForTokenAboveQuote(meta, address(0));
        IHookRigBlock.PoolStackConfig memory stackCfg;
        stackCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_SWAP_REWARDS;
        stackCfg.swapRewards = IHookRigBlock.SwapRewardsParams({pointsPerUnitVolume: 1e18});
        ITokenLaunchpad.VirtualXYKConfig memory curveCfg = ITokenLaunchpad.VirtualXYKConfig({
            virtualQuoteReserve: 10 ether,
            virtualTokenReserve: 800_000_000 ether,
            graduationQuoteTarget: 5 ether,
            curveTokenAllocation: 800_000_000 ether,
            lpTokenReserve: 200_000_000 ether,
            maxWalletBpsDuringCurve: 1000 // 10% max wallet cap
        });

        (, address curveAddr,) = launchpadFactory.launchVirtualXYK(
            meta, ethCurrency, 60, IHookRigOrchestrator(address(0)), stackCfg, curveCfg, salt
        );
        VirtualXYKLaunch curve = VirtualXYKLaunch(payable(curveAddr));

        // Buying > 10% of supply reverts with WalletCapExceededOnCurve
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert();
        curve.buy{value: 5 ether}(5 ether, 1, alice);

        // Buying within 10% cap using native ETH succeeds
        vm.prank(alice);
        curve.buy{value: 1 ether}(1 ether, 1, alice);
    }

    // =========================================================================
    // 3. Curve Model #2: SteppedTrancheLaunch (Anti-Bundle Tranches + Surcharges)
    // =========================================================================

    function test_SteppedTrancheLaunch_TranchesAntiSnipeSurchargeAndGraduation() public {
        ITokenLaunchpad.LaunchTokenMetadata memory meta = ITokenLaunchpad.LaunchTokenMetadata({
            name: "Stepped Tranche Token",
            symbol: "STEP",
            totalSupply: 1_000_000_000 ether,
            creator: owner,
            creatorVestingBps: 0,
            vestingDurationSeconds: 0
        });

        bytes32 salt = _mineSaltForTokenAboveQuote(meta, Currency.unwrap(quoteCurrency));

        IHookRigBlock.PoolStackConfig memory stackCfg;
        stackCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_KING_OF_THE_POOL;
        stackCfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 200, roundDurationSeconds: 600, minBuyAmountForReset: 1 ether
        });

        // Base price = 2^-96 * 2^96 = 1e-7 quote per token -> wait: priceQ96 is quote per token in Q96
        // Let's set basePriceQ96 = (1 << 96) / 10_000_000 (1 quote buys 10M tokens)
        uint128 basePriceQ96 = uint128((uint256(1) << 96) / 10_000_000);
        uint128 stepIncrementQ96 = uint128((uint256(1) << 96) / 50_000_000);

        ITokenLaunchpad.SteppedTrancheConfig memory trancheCfg = ITokenLaunchpad.SteppedTrancheConfig({
            graduationQuoteTarget: 20 ether,
            curveTokenAllocation: 800_000_000 ether,
            lpTokenReserve: 200_000_000 ether,
            numTranches: 4,
            basePriceQ96: basePriceQ96,
            stepPriceIncrementQ96: stepIncrementQ96,
            maxWalletBps: 5000, // 50% max wallet
            antiSnipeSurchargeBps: 1000, // 10% surcharge at block 0
            antiSnipeBlocks: 10,
            surchargeToKingPotBps: 5000 // 50% of surcharge to KingPot, 50% to extra LP
        });

        (address tokenAddr, address curveAddr, PoolKey memory key) = launchpadFactory.launchSteppedTranche(
            meta, quoteCurrency, 60, IHookRigOrchestrator(address(0)), stackCfg, trancheCfg, salt
        );

        SteppedTrancheLaunch curve = SteppedTrancheLaunch(payable(curveAddr));

        // Double init & direct unlockCallback revert
        vm.expectRevert(SteppedTrancheLaunch.AlreadyInitialized.selector);
        curve.initializeCurve(key, tokenAddr, trancheCfg);
        vm.expectRevert(SteppedTrancheLaunch.OnlyPoolManagerUnlock.selector);
        curve.unlockCallback("");

        assertEq(curve.currentTrancheIndex(), 0);
        assertEq(curve.currentAntiSnipeSurchargeBps(), 1000);

        // Alice buys at launch block -> pays 10% anti-snipe surcharge
        vm.startPrank(alice);
        quoteToken.approve(curveAddr, type(uint256).max);
        (uint256 tokens1, uint256 surcharge1) = curve.buy(10 ether, 1, address(0));
        vm.stopPrank();

        assertEq(surcharge1, 1 ether);
        assertGt(tokens1, 0);
        assertEq(curve.totalSurchargeCollected(), 1 ether);

        // Alice can sell tokens back into SteppedTrancheLaunch if the launch stalls before graduation (anti-freeze liveness)
        vm.startPrank(alice);
        HookRigToken(tokenAddr).approve(curveAddr, type(uint256).max);
        uint256 aliceRefunded = curve.sell(tokens1 / 5, 1, address(0));
        assertGt(aliceRefunded, 0);
        vm.stopPrank();

        // Advance 5 blocks -> surcharge decays by 50% (to 500 bps)
        vm.roll(block.number + 5);
        assertEq(curve.currentAntiSnipeSurchargeBps(), 500);

        // Advance past 10 blocks -> surcharge is 0
        vm.roll(block.number + 10);
        assertEq(curve.currentAntiSnipeSurchargeBps(), 0);

        // Bob buys enough to reach the 20 ether graduationQuoteTarget -> triggers _graduateToV4!
        vm.startPrank(bob);
        quoteToken.approve(curveAddr, type(uint256).max);
        curve.buy(25 ether, 1, bob);
        vm.stopPrank();

        assertEq(uint8(curve.launchState()), uint8(ITokenLaunchpad.LaunchState.Graduated));

        // Post-graduation buy or sell on curve reverts
        vm.prank(alice);
        vm.expectRevert(SteppedTrancheLaunch.CurveNotActive.selector);
        curve.buy(1 ether, 0, alice);

        vm.prank(alice);
        vm.expectRevert(SteppedTrancheLaunch.CurveNotActive.selector);
        curve.sell(1 ether, 0, alice);

        // Swap on graduated v4 pool succeeds
        _swapExactIn(carol, key, true, 1 ether, "");
    }

    // =========================================================================
    // 4. Curve Model #3: NativeTickLaunch (Block-0 Single-Sided v4 Tick Seeding)
    // =========================================================================

    function test_NativeTickLaunch_BlockZeroSingleSidedConcentratedTicks() public {
        ITokenLaunchpad.LaunchTokenMetadata memory meta = ITokenLaunchpad.LaunchTokenMetadata({
            name: "Native Tick Token",
            symbol: "NTICK",
            totalSupply: 1_000_000_000 ether,
            creator: owner,
            creatorVestingBps: 0,
            vestingDurationSeconds: 0
        });

        bytes32 salt = _mineSaltForTokenAboveQuote(meta, Currency.unwrap(quoteCurrency));

        IHookRigBlock.PoolStackConfig memory stackCfg;
        stackCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_DYNAMIC_FEE;
        stackCfg.dynamicFee =
            IHookRigBlock.DynamicFeeParams({baseFee: 3000, maxFee: 30_000, volatilityTickThreshold: 40});

        // Because projectToken is currency1, tick ranges strictly BELOW currentTick (0 at SQRT_PRICE_1_1)
        // require 100% currency1 (projectToken) and 0% currency0 (quoteToken)!
        ITokenLaunchpad.NativeTickBand[] memory bands = new ITokenLaunchpad.NativeTickBand[](3);
        bands[0] = ITokenLaunchpad.NativeTickBand({tickLower: -1800, tickUpper: -60, tokenAmount: 10_000_000 ether});
        bands[1] = ITokenLaunchpad.NativeTickBand({tickLower: -3600, tickUpper: -1800, tokenAmount: 20_000_000 ether});
        bands[2] = ITokenLaunchpad.NativeTickBand({tickLower: -6000, tickUpper: -3600, tokenAmount: 0}); // 0-amount band skipped cleanly

        ITokenLaunchpad.NativeTickConfig memory nativeCfg =
            ITokenLaunchpad.NativeTickConfig({initialSqrtPriceX96: SQRT_PRICE_1_1, tickSpacing: 60, bands: bands});

        (address tokenAddr, address curveAddr, PoolKey memory key) = launchpadFactory.launchNativeTick(
            meta, quoteCurrency, IHookRigOrchestrator(address(0)), stackCfg, nativeCfg, salt
        );

        NativeTickLaunch curve = NativeTickLaunch(curveAddr);
        assertEq(uint8(curve.launchState()), uint8(ITokenLaunchpad.LaunchState.Graduated));

        // Double launch or direct unlockCallback reverts
        vm.expectRevert(NativeTickLaunch.AlreadyLaunched.selector);
        curve.initializeAndSeedNativeTicks(key, tokenAddr, nativeCfg);
        vm.expectRevert(NativeTickLaunch.OnlyPoolManagerUnlock.selector);
        curve.unlockCallback("");

        // Pool is immediately live at Block 0 with single-sided currency1 bands!
        _swapExactIn(alice, key, true, 100 ether, "");
        assertGt(IERC20(tokenAddr).balanceOf(alice), 0);
    }
}
