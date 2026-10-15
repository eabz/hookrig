// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

/// @title LPRewardsBlock
/// @notice Group 4 (Rewards & Income) — Block #12: Extra fee on buys donated directly to active LPs
///         (`afterSwap`, `afterSwapReturnDelta`).
/// @dev Trust Level: Medium (capped at MAX_LP_REWARD_BPS = 500 = 5%; 100% donated to pool LPs via PoolManager.donate).
abstract contract LPRewardsBlock is IHookRigBlock {
    uint16 internal constant MAX_LP_REWARD_BPS = 500; // 5.00%

    mapping(PoolId poolId => LPRewardsParams config) internal _lpRewardsConfigs;
    mapping(PoolId poolId => uint256 totalDonated) public totalLPRewardsDonated;

    event LPRewardsDonated(PoolId indexed poolId, uint256 amount0, uint256 amount1);

    error LPRewardExceedsCap(uint16 requestedBps);

    function _initLPRewards(PoolId poolId, LPRewardsParams calldata params) internal {
        if (params.extraBuyFeeBps > MAX_LP_REWARD_BPS) {
            revert LPRewardExceedsCap(params.extraBuyFeeBps);
        }
        _lpRewardsConfigs[poolId] = params;
    }
}
