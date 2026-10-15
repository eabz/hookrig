// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {HookPermissionMasks} from "../libraries/HookPermissionMasks.sol";
import {PoolTokenDir} from "../libraries/PoolTokenDir.sol";
import {ArbRecaptureBlock, ArbRecaptureLogic} from "../blocks/protection/ArbRecaptureBlock.sol";
import {BuySellTaxBlock, BuySellTaxLogic} from "../blocks/token-rules/BuySellTaxBlock.sol";
import {AutoBurnBlock, AutoBurnLogic} from "../blocks/token-rules/AutoBurnBlock.sol";
import {FeeSharingBlock, FeeSharingLogic} from "../blocks/rewards/FeeSharingBlock.sol";
import {LPRewardsBlock} from "../blocks/rewards/LPRewardsBlock.sol";
import {KingOfThePoolBlock, KingOfThePoolLogic} from "../blocks/rewards/KingOfThePoolBlock.sol";
import {ReferralSplitBlock, ReferralSplitLogic} from "../blocks/rewards/ReferralSplitBlock.sol";
import {AutoBuybackBlock, AutoBuybackLogic} from "../blocks/rewards/AutoBuybackBlock.sol";

/// @title AfterSwapDeltaAggregator
/// @notice Single-pass output/unspecified delta waterfall combining all 8 return-delta blocks:
///         1. `Arb recapture`
///         2. `Buy and sell tax`
///         3. `Auto burn`
///         4. `Fee sharing`
///         5. `LP rewards`
///         6. `King of the Pool`
///         7. `Referral split` (Expansion #20)
///         8. `Auto buyback` (Expansion #22)
/// @dev Enforces the Anti-Bunni Rounding Law (`Math.Rounding.Floor` on cuts) and `MAX_AGGREGATE_AFTER_SWAP_BPS = 2500` (25%).
abstract contract AfterSwapDeltaAggregator is
    ArbRecaptureBlock,
    BuySellTaxBlock,
    AutoBurnBlock,
    FeeSharingBlock,
    LPRewardsBlock,
    KingOfThePoolBlock,
    ReferralSplitBlock,
    AutoBuybackBlock
{
    uint16 internal constant MAX_AGGREGATE_AFTER_SWAP_BPS = 2500; // 25.00% hard aggregate cap

    function _executeAfterSwapDeltaWaterfall(
        mapping(PoolId => mapping(Currency => mapping(address => uint256))) storage poolClaims,
        IPoolManager manager,
        PoolKey calldata key,
        PoolId poolId,
        uint32 bitmap,
        PoolTokenDir.SwapContext memory ctx
    ) internal returns (int128 totalHookDeltaUnspecified, uint256 totalCutAmount) {
        if ((bitmap & HookPermissionMasks.AFTER_SWAP_RETURN_DELTA_BLOCKS_MASK) == 0 || ctx.grossUnspecifiedAmount == 0)
        {
            return (0, 0);
        }

        bool hasActiveLiquidity = StateLibrary.getLiquidity(manager, poolId) > 0;
        uint256 lpDonationAmount = 0;

        // 0. Static 5 bps (0.05%) Protocol Royalty
        totalCutAmount = BuySellTaxLogic.processWaterfallRoyalty(
            poolClaims,
            manager,
            poolId,
            ctx.unspecifiedCurrency,
            ctx.grossUnspecifiedAmount,
            ctx.isExactInput,
            _protocolRoyaltyBps(),
            _protocolRoyaltyRecipient()
        );

        // 1. Arb recapture
        if ((bitmap & HookPermissionMasks.BIT_ARB_RECAPTURE) != 0 && hasActiveLiquidity) {
            (totalCutAmount, lpDonationAmount) = ArbRecaptureLogic.processWaterfallArb(
                _arbStates,
                poolId,
                ctx.preSwapTick,
                ctx.postSwapTick,
                ctx.grossUnspecifiedAmount,
                ctx.isExactInput,
                totalCutAmount,
                lpDonationAmount
            );
        }

        // 2. Buy and sell tax
        if ((bitmap & HookPermissionMasks.BIT_BUY_SELL_TAX) != 0) {
            totalCutAmount = BuySellTaxLogic.processWaterfallTax(
                poolClaims,
                _taxConfigs,
                manager,
                poolId,
                ctx.unspecifiedCurrency,
                ctx.grossUnspecifiedAmount,
                ctx.isBuy,
                ctx.isExactInput,
                totalCutAmount
            );
        }

        // 3. Auto burn
        if ((bitmap & HookPermissionMasks.BIT_AUTO_BURN) != 0 && ctx.isBuy) {
            totalCutAmount = AutoBurnLogic.processWaterfallBurn(
                _autoBurnConfigs,
                totalAutoBurnedByPool,
                manager,
                poolId,
                ctx.unspecifiedCurrency,
                ctx.grossUnspecifiedAmount,
                ctx.isExactInput,
                totalCutAmount
            );
        }

        // 4. Fee sharing
        if ((bitmap & HookPermissionMasks.BIT_FEE_SHARING) != 0) {
            totalCutAmount = FeeSharingLogic.processWaterfallFeeSharing(
                poolClaims,
                _feeSharingConfigs,
                manager,
                poolId,
                ctx.unspecifiedCurrency,
                ctx.grossUnspecifiedAmount,
                ctx.isExactInput,
                totalCutAmount
            );
        }

        // 5. LP rewards
        if ((bitmap & HookPermissionMasks.BIT_LP_REWARDS) != 0 && ctx.isBuy && hasActiveLiquidity) {
            (totalCutAmount, lpDonationAmount) = FeeSharingLogic.processWaterfallLPRewards(
                _lpRewardsConfigs,
                poolId,
                ctx.grossUnspecifiedAmount,
                ctx.isExactInput,
                totalCutAmount,
                lpDonationAmount
            );
        }

        // 6. King of the Pool
        if (
            (bitmap & HookPermissionMasks.BIT_KING_OF_THE_POOL) != 0 && ctx.isBuy
                && ctx.unspecifiedCurrency == ctx.projectCurrency
        ) {
            totalCutAmount = KingOfThePoolLogic.processWaterfallKing(
                _kingStates,
                _settledKingRounds,
                manager,
                poolId,
                ctx.trader,
                ctx.unspecifiedCurrency,
                ctx.grossUnspecifiedAmount,
                ctx.isExactInput,
                totalCutAmount
            );
        }

        // 7. Referral Split
        if ((bitmap & HookPermissionMasks.BIT_REFERRAL_SPLIT) != 0) {
            totalCutAmount = ReferralSplitLogic.processWaterfallReferral(
                poolClaims,
                _referralConfigs,
                traderReferrer,
                manager,
                poolId,
                ctx.trader,
                ctx.unspecifiedCurrency,
                ctx.grossUnspecifiedAmount,
                ctx.isExactInput,
                totalCutAmount
            );
        }

        // 8. Auto Buyback & Floor Defense
        if ((bitmap & HookPermissionMasks.BIT_AUTO_BUYBACK) != 0) {
            bool isToken0Proj = ctx.projectCurrency == key.currency0;
            uint256 addedLp;
            (totalCutAmount, addedLp) = AutoBuybackLogic.processWaterfallBuyback(
                _autoBuybackStates,
                manager,
                poolId,
                ctx.unspecifiedCurrency,
                ctx.grossUnspecifiedAmount,
                ctx.postSwapTick,
                ctx.isExactInput,
                isToken0Proj,
                hasActiveLiquidity,
                totalCutAmount
            );
            lpDonationAmount += addedLp;
        }

        // Settle combined LP donations
        if (lpDonationAmount > 0) {
            totalCutAmount = AutoBuybackLogic.settleLPDonation(
                totalLPRewardsDonated,
                manager,
                key,
                hasActiveLiquidity,
                ctx.unspecifiedCurrency,
                totalCutAmount,
                lpDonationAmount
            );
        }

        totalHookDeltaUnspecified = SafeCast.toInt128(SafeCast.toInt256(totalCutAmount));
    }

    function _protocolRoyaltyBps() internal view virtual returns (uint16);

    function _protocolRoyaltyRecipient() internal view virtual returns (address);
}
