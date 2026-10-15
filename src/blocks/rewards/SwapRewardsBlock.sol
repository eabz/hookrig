// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library SwapRewardsLogic {
    event SwapPointsAccrued(PoolId indexed poolId, address indexed trader, uint256 pointsAdded, uint256 newTotal);

    function accrue(
        mapping(PoolId => IHookRigBlock.SwapRewardsParams) storage configs,
        mapping(PoolId => mapping(address => uint256)) storage swapRewardPoints,
        mapping(PoolId => uint256) storage totalPoolSwapPoints,
        PoolId poolId,
        address trader,
        uint256 volumeAmount
    ) external {
        uint128 rate = configs[poolId].pointsPerUnitVolume;
        if (rate == 0 || volumeAmount == 0 || trader == address(0)) return;

        uint256 points = Math.mulDiv(volumeAmount, rate, 1e18, Math.Rounding.Floor);
        if (points == 0) return;

        uint256 updated = swapRewardPoints[poolId][trader] + points;
        swapRewardPoints[poolId][trader] = updated;
        totalPoolSwapPoints[poolId] += points;

        emit SwapPointsAccrued(poolId, trader, points, updated);
    }
}

/// @title SwapRewardsBlock
/// @notice Group 4 (Rewards & Income) — Block #13: Accrues loyalty reward points per swap (`afterSwap`).
/// @dev Trust Level: Low (non-custodial point accumulator; zero delta impact).
abstract contract SwapRewardsBlock is IHookRigBlock {
    uint128 internal constant MAX_POINTS_PER_UNIT_VOLUME = 1e27;

    mapping(PoolId poolId => SwapRewardsParams config) internal _swapRewardsConfigs;
    mapping(PoolId poolId => mapping(address trader => uint256 points)) public swapRewardPoints;
    mapping(PoolId poolId => uint256 totalPoints) public totalPoolSwapPoints;

    error SwapRewardPointsRateTooHigh(uint128 requestedRate);

    function _initSwapRewards(PoolId poolId, SwapRewardsParams calldata params) internal {
        if (params.pointsPerUnitVolume > MAX_POINTS_PER_UNIT_VOLUME) {
            revert SwapRewardPointsRateTooHigh(params.pointsPerUnitVolume);
        }
        _swapRewardsConfigs[poolId] = params;
    }

    function _accrueSwapRewards(PoolId poolId, address trader, uint256 volumeAmount) internal {
        SwapRewardsLogic.accrue(
            _swapRewardsConfigs, swapRewardPoints, totalPoolSwapPoints, poolId, trader, volumeAmount
        );
    }
}
