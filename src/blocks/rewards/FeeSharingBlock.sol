// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library FeeSharingLogic {
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
        if (params.feeShareBps > 0 && params.primaryRecipient == address(0)) {
            revert InvalidFeeSharingConfig();
        }
        configs[poolId] = params;
    }

    function computeSplits(
        mapping(PoolId => IHookRigBlock.FeeSharingParams) storage configs,
        PoolId poolId,
        uint256 totalShareAmount
    ) external view returns (address primary, uint256 primaryAmount, address secondary, uint256 secondaryAmount) {
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
