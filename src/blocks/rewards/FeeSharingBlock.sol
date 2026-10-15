// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";
import {IHookRigOrchestrator} from "../../interfaces/IHookRigOrchestrator.sol";
import {HookPermissionMasks} from "../../libraries/HookPermissionMasks.sol";
import {PoolTokenDir} from "../../libraries/PoolTokenDir.sol";

library FeeSharingLogic {
    using CurrencySettler for Currency;

    uint16 internal constant MAX_FEE_SHARE_BPS = 500; // 5.00%

    error InvalidFeeSharingConfig();

    function init(
        mapping(PoolId => IHookRigBlock.FeeSharingParams) storage configs,
        PoolId poolId,
        IHookRigBlock.FeeSharingParams calldata params
    ) external {
        if (params.feeShareBps > MAX_FEE_SHARE_BPS || params.secondaryShareBps > 10_000) {
            revert InvalidFeeSharingConfig();
        }
        if (
            (params.feeShareBps > 0 && params.primaryRecipient == address(0))
                || (params.secondaryShareBps > 0 && params.secondaryRecipient == address(0))
        ) {
            revert InvalidFeeSharingConfig();
        }
        configs[poolId] = params;
    }

    function computeSplits(
        mapping(PoolId => IHookRigBlock.FeeSharingParams) storage configs,
        PoolId poolId,
        uint256 totalShareAmount
    ) public view returns (address primary, uint256 primaryAmount, address secondary, uint256 secondaryAmount) {
        IHookRigBlock.FeeSharingParams storage cfg = configs[poolId];
        primary = cfg.primaryRecipient;
        secondary = cfg.secondaryRecipient;
        uint16 secBps = cfg.secondaryShareBps;

        if (secondary != address(0) && secBps > 0) {
            secondaryAmount = Math.mulDiv(totalShareAmount, secBps, 10_000, Math.Rounding.Floor);
            primaryAmount = totalShareAmount - secondaryAmount;
        } else {
            primaryAmount = totalShareAmount;
        }
    }

    function processWaterfallFeeSharing(
        mapping(PoolId => mapping(Currency => mapping(address => uint256))) storage poolClaims,
        mapping(PoolId => IHookRigBlock.FeeSharingParams) storage feeSharingConfigs,
        IPoolManager manager,
        PoolId poolId,
        Currency unspecifiedCurrency,
        uint256 grossAmount,
        bool isExactInput,
        uint256 totalCutAmount
    ) external returns (uint256 newTotalCut) {
        newTotalCut = totalCutAmount;
        uint16 shareBps = feeSharingConfigs[poolId].feeShareBps;
        if (shareBps > 0) {
            uint256 shareCut = _boundedCut(grossAmount, isExactInput, shareBps, newTotalCut);
            if (shareCut > 0) {
                newTotalCut += shareCut;
                (address pRecip, uint256 pAmt, address sRecip, uint256 sAmt) =
                    computeSplits(feeSharingConfigs, poolId, shareCut);
                if (pAmt > 0) _creditClaim(poolClaims, manager, poolId, unspecifiedCurrency, pRecip, pAmt);
                if (sAmt > 0) _creditClaim(poolClaims, manager, poolId, unspecifiedCurrency, sRecip, sAmt);
            }
        }
    }

    function processWaterfallLPRewards(
        mapping(PoolId => IHookRigBlock.LPRewardsParams) storage lpRewardsConfigs,
        PoolId poolId,
        uint256 grossAmount,
        bool isExactInput,
        uint256 totalCutAmount,
        uint256 lpDonationAmount
    ) external view returns (uint256 newTotalCut, uint256 newLpDonation) {
        newTotalCut = totalCutAmount;
        newLpDonation = lpDonationAmount;
        uint16 lpBps = lpRewardsConfigs[poolId].extraBuyFeeBps;
        if (lpBps > 0) {
            uint256 lpCut = _boundedCut(grossAmount, isExactInput, lpBps, newTotalCut);
            if (lpCut > 0) {
                newTotalCut += lpCut;
                newLpDonation += lpCut;
            }
        }
    }

    function _creditClaim(
        mapping(PoolId => mapping(Currency => mapping(address => uint256))) storage poolClaims,
        IPoolManager manager,
        PoolId poolId,
        Currency currency,
        address beneficiary,
        uint256 amount
    ) private {
        if (amount == 0 || beneficiary == address(0)) return;
        currency.take(manager, address(this), amount, true);
        poolClaims[poolId][currency][beneficiary] += amount;
        emit IHookRigOrchestrator.ClaimCredited(poolId, currency, beneficiary, amount);
    }

    function _boundedCut(uint256 grossAmount, bool isExactInput, uint16 bps, uint256 currentTotal)
        private
        pure
        returns (uint256 cut)
    {
        Math.Rounding rounding = isExactInput ? Math.Rounding.Floor : Math.Rounding.Ceil;
        uint256 maxAllowed = Math.mulDiv(grossAmount, 2500, 10_000, rounding);
        if (currentTotal >= maxAllowed) return 0;
        cut = Math.mulDiv(grossAmount, bps, 10_000, rounding);
        if (currentTotal + cut > maxAllowed) {
            cut = maxAllowed - currentTotal;
        }
    }
}

/// @title FeeSharingBlock
/// @notice Group 4 (Rewards & Income) — Block #11: Splits swap fee revenue between creator/protocol recipients
///         (`afterSwap`, `afterSwapReturnDelta`).
/// @dev Trust Level: Medium (capped at MAX_FEE_SHARE_BPS = 500 = 5%; settled via pullable ERC-6909 claims).
abstract contract FeeSharingBlock is IHookRigBlock {
    mapping(PoolId poolId => FeeSharingParams config) internal _feeSharingConfigs;

    function _initFeeSharing(PoolId poolId, FeeSharingParams calldata params) internal {
        FeeSharingLogic.init(_feeSharingConfigs, poolId, params);
    }

    function _computeFeeSharingSplits(PoolId poolId, uint256 totalShareAmount)
        internal
        view
        returns (address primary, uint256 primaryAmount, address secondary, uint256 secondaryAmount)
    {
        return FeeSharingLogic.computeSplits(_feeSharingConfigs, poolId, totalShareAmount);
    }
}
