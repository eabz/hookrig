// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";
import {IHookRigOrchestrator} from "../../interfaces/IHookRigOrchestrator.sol";

library ReferralSplitLogic {
    using CurrencySettler for Currency;

    uint16 internal constant MAX_REFERRAL_FEE_BPS = 300; // 3.00% hard cap

    error ReferralFeeExceedsCap(uint16 requestedBps);
    error InvalidSelfReferral(address trader);

    event ReferrerRegistered(PoolId indexed poolId, address indexed trader, address indexed referrer);

    function init(
        mapping(PoolId => IHookRigBlock.ReferralSplitParams) storage configs,
        PoolId poolId,
        IHookRigBlock.ReferralSplitParams calldata params
    ) external {
        if (params.referralFeeBps > MAX_REFERRAL_FEE_BPS) {
            revert ReferralFeeExceedsCap(params.referralFeeBps);
        }
        configs[poolId] = params;
    }

    function register(
        mapping(PoolId => mapping(address => address)) storage referrers,
        PoolId poolId,
        address trader,
        address referrer
    ) external {
        if (referrer == address(0) || referrer == trader || _isDisallowed(referrer) || _isDisallowed(trader)) {
            revert InvalidSelfReferral(trader);
        }
        if (referrers[poolId][trader] == address(0)) {
            referrers[poolId][trader] = referrer;
            emit ReferrerRegistered(poolId, trader, referrer);
        }
    }

    function _isDisallowed(address account) private view returns (bool) {
        if (account == address(this)) return true;
        (bool ok, bytes memory data) =
            address(this).staticcall(abi.encodeWithSignature("isTrustedRouter(address)", account));
        return ok && data.length >= 32 && abi.decode(data, (bool));
    }

    function resolveReferrer(
        mapping(PoolId => IHookRigBlock.ReferralSplitParams) storage referralConfigs,
        mapping(PoolId => mapping(address => address)) storage traderReferrer,
        PoolId poolId,
        address trader
    ) public view returns (address referrer, uint16 referralBps) {
        return resolveReferrer(referralConfigs, traderReferrer, poolId, trader, false);
    }

    function resolveReferrer(
        mapping(PoolId => IHookRigBlock.ReferralSplitParams) storage referralConfigs,
        mapping(PoolId => mapping(address => address)) storage traderReferrer,
        PoolId poolId,
        address trader,
        bool traderIsSender
    ) public view returns (address referrer, uint16 referralBps) {
        if (traderIsSender || trader == address(0)) {
            return (address(0), 0);
        }
        referrer = traderReferrer[poolId][trader];
        if (referrer == address(0) || referrer == trader) {
            return (address(0), 0);
        }
        referralBps = referralConfigs[poolId].referralFeeBps;
        if (referralBps == 0) {
            return (address(0), 0);
        }
    }

    function processWaterfallReferral(
        mapping(PoolId => mapping(Currency => mapping(address => uint256))) storage poolClaims,
        mapping(PoolId => IHookRigBlock.ReferralSplitParams) storage referralConfigs,
        mapping(PoolId => mapping(address => address)) storage traderReferrer,
        IPoolManager manager,
        PoolId poolId,
        address trader,
        Currency unspecifiedCurrency,
        uint256 grossAmount,
        bool isExactInput,
        uint256 totalCutAmount
    ) public returns (uint256 newTotalCut) {
        newTotalCut = totalCutAmount;
        (address referrer, uint16 refBps) = resolveReferrer(referralConfigs, traderReferrer, poolId, trader, false);
        if (referrer == address(0) || refBps == 0) return newTotalCut;
        uint256 refCut;
        {
            Math.Rounding rounding = isExactInput ? Math.Rounding.Floor : Math.Rounding.Ceil;
            uint256 maxAllowed = Math.mulDiv(grossAmount, 2500, 10_000, rounding);
            if (newTotalCut >= maxAllowed) return newTotalCut;
            refCut = Math.mulDiv(grossAmount, refBps, 10_000, rounding);
            if (newTotalCut + refCut > maxAllowed) refCut = maxAllowed - newTotalCut;
        }
        if (refCut > 0) {
            newTotalCut += refCut;
            unspecifiedCurrency.take(manager, address(this), refCut, true);
            poolClaims[poolId][unspecifiedCurrency][referrer] += refCut;
            emit IHookRigOrchestrator.ClaimCredited(poolId, unspecifiedCurrency, referrer, refCut);
        }
    }
}

/// @title ReferralSplitBlock
/// @notice Group 4 (Rewards & Income) — Expansion Block #20: Referral & affiliate fee split
///         (`afterSwap`, `afterSwapReturnDelta`).
/// @dev Trust Level: Low (capped at 3%; prevents self-referral; credits pullable ERC-6909 claims to referrers).
abstract contract ReferralSplitBlock is IHookRigBlock {
    mapping(PoolId poolId => ReferralSplitParams config) internal _referralConfigs;
    mapping(PoolId poolId => mapping(address trader => address referrer)) public traderReferrer;

    function _initReferralSplit(PoolId poolId, ReferralSplitParams calldata params) internal {
        ReferralSplitLogic.init(_referralConfigs, poolId, params);
    }

    /// @notice Registers an on-chain referrer for `msg.sender` on `poolId` (first-touch attribution).
    function registerReferrer(PoolId poolId, address referrer) external {
        ReferralSplitLogic.register(traderReferrer, poolId, msg.sender, referrer);
    }

    function _resolveReferrerAndBps(PoolId poolId, address trader)
        internal
        view
        returns (uint16 referralBps, address referrer)
    {
        (referrer, referralBps) =
            ReferralSplitLogic.resolveReferrer(_referralConfigs, traderReferrer, poolId, trader, false);
    }
}
