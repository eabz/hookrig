// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../Base.sol";
import {Properties} from "../Properties.sol";
import {NativeTickLaunch} from "../../../src/launchpad/curves/NativeTickLaunch.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

/// @notice Handles new launches mid-campaign (all three curve models), with fuzzed but valid configs
abstract contract LaunchpadFactoryHandler is Properties {
    uint256 internal constant MAX_LAUNCHES = 8;
    uint256 internal constant MAX_CREATOR_VESTING_BPS = 1000; // `LaunchpadFactory.MAX_CREATOR_VESTING_BPS`
    uint256 internal constant VESTING_RELEASE_STEP = 2 hours;

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice Launches a curve; `arg0` bit 200 = 0 adds a creator vesting slice (`arg0 >> 208`, ≤ 10%).
    function launchpadFactory_secondary(uint8 selector, uint256 arg0, uint256 arg1, uint256 arg2) public tracked {
        if (launchTokens.length >= MAX_LAUNCHES) return;
        selector = uint8(selector % 3);
        _setCallContext(CallKind.LAUNCH, admin, poolKeys.length, address(0));
        launchVestingBps = (arg0 >> 200) % 2 == 0 ? uint16(clampLte(arg0 >> 208, MAX_CREATOR_VESTING_BPS)) : 0;
        if (selector == 0) _launchpadFactory_launchNativeTick(arg0, arg1);
        else if (selector == 1) _launchpadFactory_launchSteppedTranche(arg0, arg1, arg2);
        else _launchpadFactory_launchVirtualXYK(arg0, arg1, arg2);
        launchVestingBps = 0;
    }

    /// @notice Releases the creator's vested tokens (after a short warp) and sells them back into the bonding curve as
    ///         the creator (admin). Reaches curve sells of tokens the curve never sold (GL-13 / GL-23, SP-12 / SP-13).
    function launchpadFactory_releaseAndSellVesting(uint256 tokenSeed, uint256 amount) public tracked {
        address token = launchTokens[tokenSeed % launchTokens.length];
        address vest = launchpadFactory.tokenToCreatorVesting(token);
        if (vest == address(0)) return;
        skipTime(VESTING_RELEASE_STEP);
        VestingWallet(payable(vest)).release(token);

        address curve = launchpadFactory.tokenToCurve(token);
        if (ghosts.curveKind[curve] == CURVE_OTHER || _launchState(curve) != LS_ACTIVE) return;
        uint256 balance = MockBurnableERC20(token).balanceOf(admin);
        if (balance == 0) return;
        amount = clampBetween(amount, 1, balance);
        _sellToCurveAs(admin, curve, amount);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function _launchpadFactory_launchVirtualXYK(uint256 stackSeed, uint256 targetSeed, uint256 walletSeed) internal {
        ITokenLaunchpad.VirtualXYKConfig memory cfg = _defaultXYKConfig();
        cfg.graduationQuoteTarget = uint128(clampBetween(targetSeed, 1 ether, 200 ether));
        cfg.virtualQuoteReserve = uint128(clampBetween(targetSeed >> 64, 1 ether, 100 ether));
        cfg.maxWalletBpsDuringCurve = uint16(walletSeed % 3 == 0 ? clampBetween(walletSeed >> 8, 10, 10_000) : 0);
        IHookRigBlock.PoolStackConfig memory stack = _launchStack(stackSeed);
        _launchVirtualXYK(stack, cfg);
        _recordLaunchCuts(stack);
    }

    function _launchpadFactory_launchSteppedTranche(uint256 stackSeed, uint256 cfgSeed, uint256 surchargeSeed)
        internal
    {
        ITokenLaunchpad.SteppedTrancheConfig memory cfg = _defaultTrancheConfig();
        cfg.numTranches = uint8(clampBetween(cfgSeed, 1, 10));
        cfg.graduationQuoteTarget = uint128(clampBetween(cfgSeed >> 8, 1 ether, 100 ether));
        cfg.antiSnipeSurchargeBps = uint16(clampLte(surchargeSeed, 2000));
        cfg.antiSnipeBlocks = uint32(clampLte(surchargeSeed >> 16, 50));
        cfg.surchargeToKingPotBps = uint16(clampLte(surchargeSeed >> 48, 10_000));
        cfg.maxWalletBps = uint16(clampLte(cfgSeed >> 136, 10_000));
        IHookRigBlock.PoolStackConfig memory stack = _launchStack(stackSeed);
        _launchSteppedTranche(stack, cfg);
        _recordLaunchCuts(stack);
    }

    /// @notice Native-tick launch: bands sit below the initial tick so they are single-sided in the project token.
    function _launchpadFactory_launchNativeTick(uint256 stackSeed, uint256 liquiditySeed) internal {
        ITokenLaunchpad.NativeTickBand[] memory bands = new ITokenLaunchpad.NativeTickBand[](2);
        bands[0] = ITokenLaunchpad.NativeTickBand({
            tickLower: -6000, tickUpper: -60, tokenAmount: uint128(clampBetween(liquiditySeed, 1 ether, 1_000_000 ether))
        });
        bands[1] = ITokenLaunchpad.NativeTickBand({
            tickLower: -12_000, tickUpper: -6000, tokenAmount: uint128(clampBetween(liquiditySeed >> 128, 1 ether, 1_000_000 ether))
        });
        ITokenLaunchpad.NativeTickConfig memory cfg =
            ITokenLaunchpad.NativeTickConfig({initialSqrtPriceX96: SQRT_PRICE_1_1, tickSpacing: 60, bands: bands});

        ITokenLaunchpad.LaunchTokenMetadata memory meta = _launchMeta("Native Launch", "NTV");
        bytes32 salt = _mineLaunchSalt(meta);
        IHookRigBlock.PoolStackConfig memory stack = _launchStack(stackSeed);
        (address token, address curve, PoolKey memory key) = launchpadFactory.launchNativeTick(
            meta, Currency.wrap(address(token0)), IHookRigOrchestrator(address(0)), stack, cfg, salt
        );
        _registerLaunch(token, curve, key);
        _recordLaunchCuts(stack);
    }

    /// @notice Sells `amount` project tokens into a bonding curve as `seller` (implemented by the aggregator, which
    ///         owns the per-curve sell paths and their SP-12 / SP-13 checks).
    function _sellToCurveAs(address seller, address curve, uint256 amount) internal virtual;

    /// @notice SP-26: claim-slice bps of the pool just appended by a launch (tax only; launch stacks have no
    ///         fee sharing or referral).
    function _recordLaunchCuts(IHookRigBlock.PoolStackConfig memory stack) internal {
        if ((stack.enabledBlocksBitmap & HookPermissionMasks.BIT_BUY_SELL_TAX) == 0) return;
        ghosts.cfgBps[poolKeys.length - 1] = [stack.buySellTax.buyTaxBps, stack.buySellTax.sellTaxBps, 0, 0];
    }

    /// @notice Launch stacks always include King of the Pool (pot/seed paths) plus a seed-selected mix of cuts.
    function _launchStack(uint256 seed) internal returns (IHookRigBlock.PoolStackConfig memory stack) {
        stack.enabledBlocksBitmap = HookPermissionMasks.BIT_KING_OF_THE_POOL;
        stack.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: uint16(clampBetween(seed, 1, 500)), roundDurationSeconds: 600, minBuyAmountForReset: 1 ether
        });
        if ((seed >> 16) % 2 == 0) {
            stack.enabledBlocksBitmap |= HookPermissionMasks.BIT_BUY_SELL_TAX;
            stack.buySellTax = IHookRigBlock.BuySellTaxParams({
                buyTaxBps: uint16(clampLte(seed >> 24, 500)),
                sellTaxBps: uint16(clampLte(seed >> 40, 500)),
                taxRecipient: actors[1],
                decayOnly: true
            });
        }
        if ((seed >> 56) % 2 == 0) {
            stack.enabledBlocksBitmap |= HookPermissionMasks.BIT_AUTO_BUYBACK;
            stack.autoBuyback = IHookRigBlock.AutoBuybackParams({
                buybackFeeBps: uint16(clampLte(seed >> 64, 500)), triggerFloorTick: -100, minBuybackReserve: 1 ether
            });
        }
        if ((seed >> 80) % 2 == 0) {
            stack.enabledBlocksBitmap |= HookPermissionMasks.BIT_ANTI_SNIPE;
            stack.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 50_000, normalFee: 3000, decayBlocks: 20});
        }
    }
}
