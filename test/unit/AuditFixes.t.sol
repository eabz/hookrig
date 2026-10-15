// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookRigTestBase} from "../utils/HookRigTestBase.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHookRigBlock} from "../../src/interfaces/IHookRigBlock.sol";
import {IHookRigOrchestrator} from "../../src/interfaces/IHookRigOrchestrator.sol";
import {ITokenLaunchpad} from "../../src/interfaces/ITokenLaunchpad.sol";
import {HookPermissionMasks} from "../../src/libraries/HookPermissionMasks.sol";
import {AccessControlLogic} from "../../src/blocks/protection/AccessControlBlock.sol";
import {BuySellTaxLogic} from "../../src/blocks/token-rules/BuySellTaxBlock.sol";
import {VestingSellCapLogic} from "../../src/blocks/token-rules/VestingSellCapBlock.sol";
import {LimitOrdersLogic} from "../../src/blocks/trading/LimitOrdersBlock.sol";
import {LaunchpadFactory} from "../../src/launchpad/LaunchpadFactory.sol";
import {DeepLiquidityPresetHook} from "../../src/presets/HookRigPresets.sol";

/// @title AuditFixesTest
/// @notice Regression tests for the fixes from the 2026-10-15 three-pass audit
///         (`.solidity-auditor/runs/20261015-100328/full-report.md`).
contract AuditFixesTest is HookRigTestBase {
    using PoolIdLibrary for PoolKey;

    // =========================================================================
    // Limit orders: the claim swap runs the full hook pipeline (#1, #2, #10)
    // =========================================================================

    function _limitOrderPool() internal returns (PoolKey memory key, PoolId poolId) {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_DYNAMIC_FEE | HookPermissionMasks.BIT_LIMIT_ORDERS
            | HookPermissionMasks.BIT_SWAP_REWARDS | HookPermissionMasks.BIT_LP_REWARDS;
        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 3000, maxFee: 10_000, volatilityTickThreshold: 50});
        cfg.swapRewards = IHookRigBlock.SwapRewardsParams({pointsPerUnitVolume: 1e18});
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 100});
        (key, poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 500_000 ether);
    }

    function test_Fix_ClaimSwapPaysCutsAndCreditsMaker() public {
        (PoolKey memory key, PoolId poolId) = _limitOrderPool();

        vm.prank(alice);
        uint256 orderId = orchestrator.placeLimitOrder(key, -60, true, 50 ether);
        _swapExactIn(bob, key, true, 25_000 ether, ""); // crosses tick -60 and fills the bucket

        address royalty = orchestrator.PROTOCOL_ROYALTY_RECIPIENT();
        uint256 royaltyBefore = orchestrator.poolClaims(poolId, currency1, royalty);
        uint256 alicePointsBefore = orchestrator.swapRewardPoints(poolId, alice);

        vm.prank(alice);
        orchestrator.claimLimitOrder(key, orderId);

        // The claim swap paid the protocol royalty and earned the maker (not the executor) swap points
        assertGt(orchestrator.poolClaims(poolId, currency1, royalty), royaltyBefore, "claim swap skipped royalty");
        assertGt(orchestrator.swapRewardPoints(poolId, alice), alicePointsBefore, "claim swap not credited to maker");
    }

    function test_Fix_ClaimSwapMinimumOutput() public {
        (PoolKey memory key,) = _limitOrderPool();

        vm.prank(alice);
        uint256 orderId = orchestrator.placeLimitOrder(key, -60, true, 50 ether);
        _swapExactIn(bob, key, true, 25_000 ether, "");

        vm.prank(alice);
        vm.expectRevert();
        orchestrator.claimLimitOrder(key, orderId, 1_000_000 ether);

        vm.prank(alice);
        orchestrator.claimLimitOrder(key, orderId, 1 ether);
    }

    function test_Fix_FilledOrderCanStillBeCancelled() public {
        (PoolKey memory key,) = _limitOrderPool();

        vm.prank(alice);
        uint256 orderId = orchestrator.placeLimitOrder(key, -60, true, 50 ether);
        _swapExactIn(bob, key, true, 25_000 ether, "");

        uint256 before = token0.balanceOf(alice);
        vm.prank(alice);
        orchestrator.cancelLimitOrder(key, orderId);
        assertEq(token0.balanceOf(alice), before + 50 ether);
    }

    // =========================================================================
    // VestingSellCap: attributable balances only (#3)
    // =========================================================================

    function _vestingPool() internal returns (PoolKey memory key) {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_VESTING_SELL_CAP;
        cfg.vestingSellCap = IHookRigBlock.VestingSellCapParams({maxDailySellBps: 50});
        (key,) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);
    }

    function test_Fix_VestingSellCap_UntrustedRouterSellDoesNotBrick() public {
        PoolKey memory key = _vestingPool();
        vm.prank(owner);
        orchestrator.setTrustedRouter(address(router), false);

        // The router holds no project tokens while afterSwap runs; the sell must not revert
        _swapExactIn(bob, key, false, 1_000 ether, "");
    }

    function test_Fix_VestingSellCap_TokensMovedOutLowerTheCap() public {
        PoolKey memory key = _vestingPool();

        // First sell snapshots ~100M; cap 0.5% = ~500k
        _swapExactIn(alice, key, false, 1 ether, "");

        // Alice moves 99% of her balance away; the next sell is checked against the lower live balance
        uint256 moveOut = token1.balanceOf(alice) * 99 / 100;
        vm.prank(alice);
        token1.transfer(bob, moveOut);

        vm.expectRevert();
        _swapExactIn(alice, key, false, 10_000 ether, "");
    }

    // =========================================================================
    // Wallet rules reject one-sided range orders (#24)
    // =========================================================================

    function test_Fix_WalletCapPoolRejectsOneSidedLiquidity() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_WALLET_CAP;
        cfg.walletCap = IHookRigBlock.WalletCapParams({maxWalletBps: 5000, sunsetBlocks: 0});
        (PoolKey memory key,) = _initPoolWithStack(cfg);

        vm.prank(alice);
        vm.expectRevert();
        router.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: 600, tickUpper: 1200, liquidityDelta: 1_000 ether, salt: 0}), ""
        );

        vm.prank(alice);
        router.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1_000 ether, salt: 0}), ""
        );
    }

    // =========================================================================
    // LP donations are queued and skip blocks with fresh liquidity (#11, #12, #14)
    // =========================================================================

    function test_Fix_LPDonationWaitsForBlockWithoutLiquidityAdds() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_LP_REWARDS;
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 300});
        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        vm.roll(block.number + 1);
        _swapExactIn(alice, key, true, 1_000 ether, "");
        uint256 queued = orchestrator.pendingLPDonation(poolId, currency1);
        assertGt(queued, 0);
        assertEq(orchestrator.totalLPRewardsDonated(poolId), 0, "a swap cannot pay its own donation");

        // A just-in-time LP adds narrow liquidity and swaps in the same block: the donation stays queued
        vm.roll(block.number + 1);
        vm.prank(bob);
        router.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1_000_000 ether, salt: 0}), ""
        );
        _swapExactIn(bob, key, false, 1 ether, "");
        assertEq(orchestrator.totalLPRewardsDonated(poolId), 0, "donation paid in a block with a liquidity add");

        // The first swap of a later block pays it out
        vm.roll(block.number + 1);
        _swapExactIn(carol, key, false, 1 ether, "");
        assertGe(orchestrator.totalLPRewardsDonated(poolId), queued);
    }

    // =========================================================================
    // Launchpad factory hardening (#5, #9, #16, #17, #18) and registration (#7)
    // =========================================================================

    function _meta() internal view returns (ITokenLaunchpad.LaunchTokenMetadata memory) {
        return ITokenLaunchpad.LaunchTokenMetadata({
            name: "Fix Token",
            symbol: "FIX",
            totalSupply: 1_000_000_000 ether,
            creator: owner,
            creatorVestingBps: 0,
            vestingDurationSeconds: 0
        });
    }

    function _curveCfg() internal pure returns (ITokenLaunchpad.VirtualXYKConfig memory) {
        return ITokenLaunchpad.VirtualXYKConfig({
            virtualQuoteReserve: 30 ether,
            virtualTokenReserve: 800_000_000 ether,
            graduationQuoteTarget: 50 ether,
            curveTokenAllocation: 750_000_000 ether,
            lpTokenReserve: 200_000_000 ether,
            maxWalletBpsDuringCurve: 0
        });
    }

    function _saltAbove(ITokenLaunchpad.LaunchTokenMetadata memory meta) internal view returns (bytes32) {
        for (uint256 i = 1; i < 10_000; i++) {
            if (uint160(launchpadFactory.predictTokenAddress(meta, bytes32(i))) > uint160(address(token0))) {
                return bytes32(i);
            }
        }
        revert("no salt");
    }

    function test_Fix_LaunchSaltIsBoundToSender() public view {
        ITokenLaunchpad.LaunchTokenMetadata memory meta = _meta();
        bytes32 salt = bytes32(uint256(7));
        assertTrue(
            launchpadFactory.predictTokenAddressFor(meta, salt, alice)
                != launchpadFactory.predictTokenAddressFor(meta, salt, bob),
            "two senders with one salt must get different token addresses"
        );
    }

    function _safeStack() internal pure returns (IHookRigBlock.PoolStackConfig memory stackCfg) {
        stackCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_DYNAMIC_FEE;
        stackCfg.dynamicFee =
            IHookRigBlock.DynamicFeeParams({baseFee: 3000, maxFee: 10_000, volatilityTickThreshold: 50});
    }

    function test_Fix_LaunchRejectsUnsafeStacksAndHooks() public {
        ITokenLaunchpad.LaunchTokenMetadata memory meta = _meta();
        bytes32 salt = _saltAbove(meta);
        IHookRigOrchestrator defaultHook = IHookRigOrchestrator(address(0));

        // Custom hook
        vm.expectRevert(abi.encodeWithSelector(LaunchpadFactory.UnsupportedHookContract.selector, address(0xBEEF)));
        launchpadFactory.launchVirtualXYK(
            meta, currency0, 60, IHookRigOrchestrator(address(0xBEEF)), _safeStack(), _curveCfg(), salt
        );

        // AccessControl on a launch pool
        IHookRigBlock.PoolStackConfig memory acCfg = _safeStack();
        acCfg.enabledBlocksBitmap |= HookPermissionMasks.BIT_ACCESS_CONTROL;
        vm.expectRevert(abi.encodeWithSelector(LaunchpadFactory.UnsafeLaunchStack.selector, acCfg.enabledBlocksBitmap));
        launchpadFactory.launchVirtualXYK(meta, currency0, 60, defaultHook, acCfg, _curveCfg(), salt);

        // AntiSnipe launch fee above 25%
        IHookRigBlock.PoolStackConfig memory snipeCfg = _safeStack();
        snipeCfg.enabledBlocksBitmap |= HookPermissionMasks.BIT_ANTI_SNIPE;
        snipeCfg.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 800_000, normalFee: 3000, decayBlocks: 20});
        vm.expectRevert(
            abi.encodeWithSelector(LaunchpadFactory.UnsafeLaunchStack.selector, snipeCfg.enabledBlocksBitmap)
        );
        launchpadFactory.launchVirtualXYK(meta, currency0, 60, defaultHook, snipeCfg, _curveCfg(), salt);

        // Tick spacing above the PoolManager maximum
        vm.expectRevert(LaunchpadFactory.InvalidCurveConfiguration.selector);
        launchpadFactory.launchVirtualXYK(meta, currency0, 40_000, defaultHook, _safeStack(), _curveCfg(), salt);

        // The safe stack launches
        launchpadFactory.launchVirtualXYK(meta, currency0, 60, defaultHook, _safeStack(), _curveCfg(), salt);
    }

    function test_Fix_RegisterPoolStackRejectsUndeployedToken() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_SWAP_REWARDS;
        cfg.swapRewards = IHookRigBlock.SwapRewardsParams({pointsPerUnitVolume: 1});
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: Currency.wrap(address(type(uint160).max)), // a predicted token that does not exist yet
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(orchestrator))
        });
        vm.expectRevert(AccessControlLogic.TokenNotDeployed.selector);
        orchestrator.registerPoolStack(key, cfg);
    }

    // =========================================================================
    // Tax can only decrease (#26)
    // =========================================================================

    function test_Fix_TaxCannotIncreaseWithoutDecayOnly() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_BUY_SELL_TAX;
        cfg.buySellTax =
            IHookRigBlock.BuySellTaxParams({buyTaxBps: 0, sellTaxBps: 0, taxRecipient: address(0), decayOnly: false});
        (, PoolId poolId) = _initPoolWithStack(cfg);

        vm.expectRevert(BuySellTaxLogic.TaxIncreaseForbiddenInDecayOnlyMode.selector);
        orchestrator.setBuySellTax(poolId, 1000, 1000, address(this));
    }

    // =========================================================================
    // Oracle weights the elapsed interval by the tick that held during it (#31)
    // =========================================================================

    function test_Fix_OracleWeightsIntervalByItsOwnTick() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_ORACLE;
        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 500_000 ether);

        _swapExactIn(alice, key, true, 40_000 ether, ""); // tick drops; same timestamp, no checkpoint
        vm.warp(block.timestamp + 10);
        _swapExactIn(alice, key, false, 1 ether, ""); // checkpoints the 10s the lower tick held

        (, int56 cumulative) = orchestrator.getOracleTickCumulative(poolId);
        assertLt(cumulative, 0, "the 10s interval must be weighted by the lower tick, not the initial tick 0");
    }

    // =========================================================================
    // MEV direction lock ignores dust (#19)
    // =========================================================================

    function test_Fix_MEVDustSwapDoesNotSetBlockDirection() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_MEV_PROTECTION;
        cfg.mevProtection =
            IHookRigBlock.MEVProtectionParams({maxTickDeltaPerSwap: 200, minLPHoldBlocks: 0, jitExitPenaltyBps: 0});
        (PoolKey memory key,) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        vm.roll(block.number + 1);
        _swapExactIn(alice, key, true, 1 wei, ""); // dust in one direction
        _swapExactIn(bob, key, false, 2_000 ether, ""); // larger opposite trade in the same block still succeeds
    }

    // =========================================================================
    // King of the Pool: a quote-currency seed does not freeze the crown (#4, #27), dust never crowns
    // =========================================================================

    function test_Fix_KingSeedInOtherCurrencyStillContestable() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_KING_OF_THE_POOL;
        cfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 200, roundDurationSeconds: 600, minBuyAmountForReset: 0
        });
        (PoolKey memory key, PoolId poolId) = _initPoolWithStack(cfg);
        _seedFullRangeLiquidity(key, 1_000_000 ether);

        // Launch-style seed in the quote currency (currency0) while buys pay the pot fee in currency1
        vm.prank(address(launchpadFactory));
        orchestrator.seedKingPotFromLaunchCurve(poolId, currency0, 5 ether);

        _swapExactIn(alice, key, true, 100 ether, "");
        (, address king,,) = orchestrator.getCurrentKing(poolId);
        assertEq(king, alice);

        vm.warp(block.timestamp + 10);
        _swapExactIn(carol, key, true, 1 wei, ""); // dust: nominal pot fee rounds to zero
        (, king,,) = orchestrator.getCurrentKing(poolId);
        assertEq(king, alice, "dust buy must not take the crown");

        _swapExactIn(bob, key, true, 100 ether, "");
        (, king,,) = orchestrator.getCurrentKing(poolId);
        assertEq(king, bob, "a later real buyer must be able to take the crown");
    }

    function test_Fix_KingRequiresPotFee() public {
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_KING_OF_THE_POOL;
        cfg.kingOfThePool =
            IHookRigBlock.KingOfThePoolParams({potFeeOnBuyBps: 0, roundDurationSeconds: 600, minBuyAmountForReset: 0});
        PoolKey memory key = _defaultPoolKey(IHooks(address(orchestrator)));
        vm.expectRevert();
        orchestrator.registerPoolStack(key, cfg);
    }

    // =========================================================================
    // Preset hooks reject blocks they cannot run (#15, #23)
    // =========================================================================

    function test_Fix_PresetHookRejectsBlocksWithoutCallbacks() public {
        Hooks.Permissions memory p = HookPermissionMasks.permissionsForBitmap(HookPermissionMasks.PRESET_DEEP_LIQUIDITY);
        uint160 flags;
        if (p.beforeInitialize) flags |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (p.afterInitialize) flags |= Hooks.AFTER_INITIALIZE_FLAG;
        if (p.beforeAddLiquidity) flags |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (p.beforeRemoveLiquidity) flags |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (p.beforeSwap) flags |= Hooks.BEFORE_SWAP_FLAG;
        if (p.afterSwap) flags |= Hooks.AFTER_SWAP_FLAG;
        if (p.afterSwapReturnDelta) flags |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        address presetAddr = address(uint160(0x7777000000000000000000000000000000000000) | flags);
        deployCodeTo("HookRigPresets.sol:DeepLiquidityPresetHook", abi.encode(poolManager, owner), presetAddr);

        // JITGuard needs beforeRemoveLiquidity, which the Deep Liquidity preset hook does not enable
        IHookRigBlock.PoolStackConfig memory cfg;
        cfg.presetId = IHookRigBlock.PresetId.DeepLiquidityExistingToken;
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_JIT_GUARD;
        uint32 bitmap = HookPermissionMasks.PRESET_DEEP_LIQUIDITY | HookPermissionMasks.BIT_JIT_GUARD;
        vm.expectRevert(abi.encodeWithSelector(IHookRigOrchestrator.InvalidBlockBitmap.selector, bitmap));
        DeepLiquidityPresetHook(payable(presetAddr)).registerPoolStack(_defaultPoolKey(IHooks(presetAddr)), cfg);
    }
}
