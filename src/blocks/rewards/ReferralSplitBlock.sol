// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library ReferralSplitLogic {
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
        if (referrer == address(0) || referrer == trader) revert InvalidSelfReferral(trader);
        if (referrers[poolId][trader] == address(0)) {
            referrers[poolId][trader] = referrer;
            emit ReferrerRegistered(poolId, trader, referrer);
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
        referralBps = _referralConfigs[poolId].referralFeeBps;
        referrer = traderReferrer[poolId][trader];
        if (referrer == trader) {
            referrer = address(0);
        }
    }
}
