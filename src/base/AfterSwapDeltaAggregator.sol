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
import {ArbRecaptureBlock} from "../blocks/protection/ArbRecaptureBlock.sol";
import {BuySellTaxBlock} from "../blocks/token-rules/BuySellTaxBlock.sol";
import {AutoBurnBlock} from "../blocks/token-rules/AutoBurnBlock.sol";
import {FeeSharingBlock} from "../blocks/rewards/FeeSharingBlock.sol";
import {LPRewardsBlock} from "../blocks/rewards/LPRewardsBlock.sol";
import {KingOfThePoolBlock} from "../blocks/rewards/KingOfThePoolBlock.sol";
import {ReferralSplitBlock} from "../blocks/rewards/ReferralSplitBlock.sol";
import {AutoBuybackBlock} from "../blocks/rewards/AutoBuybackBlock.sol";

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

    function _validateAggregateReturnDeltaBudget(PoolStackConfig calldata cfg, uint32 bitmap)
        internal
        view
        returns (uint256 maxPossibleBps)
    {
        if ((bitmap & HookPermissionMasks.AFTER_SWAP_RETURN_DELTA_BLOCKS_MASK) == 0) {
            return 0;
        }

        uint256 maxBuyBps = _protocolRoyaltyBps();
        uint256 maxSellBps = _protocolRoyaltyBps();

        if ((bitmap & HookPermissionMasks.BIT_BUY_SELL_TAX) != 0) {
            maxBuyBps += cfg.buySellTax.buyTaxBps;
            maxSellBps += cfg.buySellTax.sellTaxBps;
        }
        if ((bitmap & HookPermissionMasks.BIT_AUTO_BURN) != 0) {
            maxBuyBps += cfg.autoBurn.burnOnBuyBps;
        }
        if ((bitmap & HookPermissionMasks.BIT_FEE_SHARING) != 0) {
            maxBuyBps += cfg.feeSharing.feeShareBps;
            maxSellBps += cfg.feeSharing.feeShareBps;
        }
        if ((bitmap & HookPermissionMasks.BIT_LP_REWARDS) != 0) {
            maxBuyBps += cfg.lpRewards.extraBuyFeeBps;
        }
        if ((bitmap & HookPermissionMasks.BIT_KING_OF_THE_POOL) != 0) {
            maxBuyBps += cfg.kingOfThePool.potFeeOnBuyBps;
        }
        if ((bitmap & HookPermissionMasks.BIT_REFERRAL_SPLIT) != 0) {
            maxBuyBps += cfg.referralSplit.referralFeeBps;
            maxSellBps += cfg.referralSplit.referralFeeBps;
        }
        if ((bitmap & HookPermissionMasks.BIT_AUTO_BUYBACK) != 0) {
            maxBuyBps += cfg.autoBuyback.buybackFeeBps;
            maxSellBps += cfg.autoBuyback.buybackFeeBps;
        }

        maxPossibleBps = maxBuyBps > maxSellBps ? maxBuyBps : maxSellBps;
    }

    function _executeAfterSwapDeltaWaterfall(
        IPoolManager manager,
        PoolKey calldata key,
        PoolId poolId,
        uint32 bitmap,
        bool isToken0ProjectToken,
        PoolTokenDir.SwapContext memory ctx
    ) internal returns (int128 totalHookDeltaUnspecified, uint256 totalCutAmount) {
        if ((bitmap & HookPermissionMasks.AFTER_SWAP_RETURN_DELTA_BLOCKS_MASK) == 0 || ctx.grossUnspecifiedAmount == 0)
        {
            return (0, 0);
        }

        uint256 maxAllowedTotalCut = Math.mulDiv(
            ctx.grossUnspecifiedAmount,
            MAX_AGGREGATE_AFTER_SWAP_BPS,
            10_000,
            ctx.isExactInput ? Math.Rounding.Floor : Math.Rounding.Ceil
        );
        uint256 lpDonationAmount = 0;
        bool hasActiveLiquidity = StateLibrary.getLiquidity(manager, poolId) > 0;

        // 0. Static 5 bps (0.05%) Protocol Royalty (credited as pullable ERC-6909 claim)
        {
            uint16 royaltyBps = _protocolRoyaltyBps();
            address royaltyRecipient = _protocolRoyaltyRecipient();
            if (royaltyBps > 0 && royaltyRecipient != address(0)) {
                uint256 royaltyCut = _boundedCut(ctx, royaltyBps, totalCutAmount, maxAllowedTotalCut);
                if (royaltyCut > 0) {
                    totalCutAmount += royaltyCut;
                    _creditClaimInternal(poolId, ctx.unspecifiedCurrency, royaltyRecipient, royaltyCut);
                }
            }
        }

        // 1. Arb recapture (donated to in-range LPs when hasActiveLiquidity)
        if ((bitmap & HookPermissionMasks.BIT_ARB_RECAPTURE) != 0) {
            uint16 arbBps = _computeArbRecaptureCutBps(poolId, ctx.preSwapTick, ctx.postSwapTick);
            if (arbBps > 0 && hasActiveLiquidity) {
                uint256 arbCut = _boundedCut(ctx, arbBps, totalCutAmount, maxAllowedTotalCut);
                if (arbCut > 0) {
                    totalCutAmount += arbCut;
                    lpDonationAmount += arbCut;
                }
            }
        }

        // 2. Buy and sell tax (credited as pullable ERC-6909 claim to taxRecipient)
        if ((bitmap & HookPermissionMasks.BIT_BUY_SELL_TAX) != 0) {
            (uint16 taxBps, address taxRecipient) = _getApplicableTaxBps(poolId, ctx.isBuy);
            if (taxBps > 0 && taxRecipient != address(0)) {
                uint256 taxCut = _boundedCut(ctx, taxBps, totalCutAmount, maxAllowedTotalCut);
                if (taxCut > 0) {
                    totalCutAmount += taxCut;
                    _creditClaimInternal(poolId, ctx.unspecifiedCurrency, taxRecipient, taxCut);
                }
            }
        }

        // 3. Auto burn (on all buys — both Exact-In and Exact-Out; SA-02)
        if ((bitmap & HookPermissionMasks.BIT_AUTO_BURN) != 0 && ctx.isBuy) {
            uint16 burnBps = _autoBurnConfigs[poolId].burnOnBuyBps;
            if (burnBps > 0) {
                uint256 burnCut = _boundedCut(ctx, burnBps, totalCutAmount, maxAllowedTotalCut);
                if (burnCut > 0) {
                    totalCutAmount += burnCut;
                    _executeAutoBurn(manager, poolId, ctx.unspecifiedCurrency, burnCut);
                }
            }
        }

        // 4. Fee sharing (credited as pullable ERC-6909 claims to primary & secondary recipients)
        if ((bitmap & HookPermissionMasks.BIT_FEE_SHARING) != 0) {
            uint16 shareBps = _feeSharingConfigs[poolId].feeShareBps;
            if (shareBps > 0) {
                uint256 shareCut = _boundedCut(ctx, shareBps, totalCutAmount, maxAllowedTotalCut);
                if (shareCut > 0) {
                    totalCutAmount += shareCut;
                    (address pRecip, uint256 pAmt, address sRecip, uint256 sAmt) =
                        _computeFeeSharingSplits(poolId, shareCut);
                    if (pAmt > 0) _creditClaimInternal(poolId, ctx.unspecifiedCurrency, pRecip, pAmt);
                    if (sAmt > 0) _creditClaimInternal(poolId, ctx.unspecifiedCurrency, sRecip, sAmt);
                }
            }
        }

        // 5. LP rewards (extra fee on buys donated to in-range LPs when hasActiveLiquidity)
        if ((bitmap & HookPermissionMasks.BIT_LP_REWARDS) != 0 && ctx.isBuy && hasActiveLiquidity) {
            uint16 lpBps = _lpRewardsConfigs[poolId].extraBuyFeeBps;
            if (lpBps > 0) {
                uint256 lpCut = _boundedCut(ctx, lpBps, totalCutAmount, maxAllowedTotalCut);
                if (lpCut > 0) {
                    totalCutAmount += lpCut;
                    lpDonationAmount += lpCut;
                }
            }
        }

        // 6. King of the Pool (pot fee on Exact-In buys where unspecifiedCurrency == projectCurrency)
        if (
            (bitmap & HookPermissionMasks.BIT_KING_OF_THE_POOL) != 0 && ctx.isBuy
                && ctx.unspecifiedCurrency == ctx.projectCurrency
        ) {
            uint16 potBps = _kingStates[poolId].potFeeOnBuyBps;
            if (potBps > 0) {
                uint256 potCut = _boundedCut(ctx, potBps, totalCutAmount, maxAllowedTotalCut);
                if (potCut > 0) {
                    totalCutAmount += potCut;
                    manager.mint(address(this), ctx.unspecifiedCurrency.toId(), potCut);
                    _processKingOfThePoolBuy(
                        poolId, ctx.trader, ctx.unspecifiedCurrency, potCut, ctx.grossUnspecifiedAmount
                    );
                }
            }
        }

        // 7. Referral Split (Expansion #20 — credited as pullable ERC-6909 claim to referrer)
        if ((bitmap & HookPermissionMasks.BIT_REFERRAL_SPLIT) != 0) {
            (uint16 refBps, address referrer) = _resolveReferrerAndBps(poolId, ctx.trader);
            if (refBps > 0 && referrer != address(0)) {
                uint256 refCut = _boundedCut(ctx, refBps, totalCutAmount, maxAllowedTotalCut);
                if (refCut > 0) {
                    totalCutAmount += refCut;
                    _creditClaimInternal(poolId, ctx.unspecifiedCurrency, referrer, refCut);
                }
            }
        }

        // 8. Auto Buyback & Floor Defense (Expansion #22)
        if ((bitmap & HookPermissionMasks.BIT_AUTO_BUYBACK) != 0) {
            uint16 bbBps = _autoBuybackStates[poolId].buybackFeeBps;
            if (bbBps > 0) {
                uint256 bbCut = _boundedCut(ctx, bbBps, totalCutAmount, maxAllowedTotalCut);
                if (bbCut > 0) {
                    totalCutAmount += bbCut;
                    uint256 deployed = _processAutoBuyback(
                        poolId,
                        ctx.unspecifiedCurrency,
                        bbCut,
                        ctx.postSwapTick,
                        isToken0ProjectToken,
                        hasActiveLiquidity
                    );
                    if (deployed > 0) {
                        uint256 priorReserve = deployed - bbCut;
                        if (priorReserve > 0) {
                            manager.burn(address(this), ctx.unspecifiedCurrency.toId(), priorReserve);
                        }
                        lpDonationAmount += deployed;
                    } else {
                        manager.mint(address(this), ctx.unspecifiedCurrency.toId(), bbCut);
                    }
                }
            }
        }

        // Settle combined LP donations (`Arb recapture` + `LP rewards` + triggered `Auto buyback`) safely
        if (lpDonationAmount > 0) {
            if (hasActiveLiquidity) {
                uint256 amount0 = ctx.unspecifiedCurrency == key.currency0 ? lpDonationAmount : 0;
                uint256 amount1 = ctx.unspecifiedCurrency == key.currency1 ? lpDonationAmount : 0;
                manager.donate(key, amount0, amount1, "");
                totalLPRewardsDonated[poolId] += lpDonationAmount;
                emit LPRewardsDonated(poolId, amount0, amount1);
            } else {
                // Zero active liquidity fallback: do not withhold lpDonationAmount so swap never reverts
                totalCutAmount -= lpDonationAmount;
            }
        }

        totalHookDeltaUnspecified = SafeCast.toInt128(SafeCast.toInt256(totalCutAmount));
    }

    function _boundedCut(
        PoolTokenDir.SwapContext memory ctx,
        uint16 bps,
        uint256 currentTotal,
        uint256 maxAllowed
    ) private pure returns (uint256 cut) {
        if (currentTotal >= maxAllowed) return 0;
        Math.Rounding rounding = ctx.isExactInput ? Math.Rounding.Floor : Math.Rounding.Ceil;
        cut = Math.mulDiv(ctx.grossUnspecifiedAmount, bps, 10_000, rounding);
        if (currentTotal + cut > maxAllowed) {
            cut = maxAllowed - currentTotal;
        }
    }

    function _protocolRoyaltyBps() internal view virtual returns (uint16);

    function _protocolRoyaltyRecipient() internal view virtual returns (address);

    function _creditClaimInternal(PoolId poolId, Currency currency, address beneficiary, uint256 amount)
        internal
        virtual;
}
