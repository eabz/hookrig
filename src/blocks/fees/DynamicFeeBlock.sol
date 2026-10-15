// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library DynamicFeeLogic {
    uint24 internal constant MAX_DYNAMIC_FEE = 50_000; // 5.00%

    struct DynamicFeeState {
        uint24 baseFee;
        uint24 maxFee;
        int24 volatilityTickThreshold;
        int24 lastObservedTick;
        uint32 lastUpdateBlock;
        uint24 rollingVolatilityTicks;
    }

    error InvalidDynamicFeeBounds(uint24 baseFee, uint24 maxFee);
    error InvalidVolatilityTickThreshold(int24 threshold);

    function stage(
        mapping(PoolId => DynamicFeeState) storage states,
        PoolId poolId,
        IHookRigBlock.DynamicFeeParams calldata params
    ) external {
        if (params.baseFee > params.maxFee || params.maxFee > MAX_DYNAMIC_FEE) {
            revert InvalidDynamicFeeBounds(params.baseFee, params.maxFee);
        }
        if (params.volatilityTickThreshold < 0 || params.volatilityTickThreshold > 1000) {
            revert InvalidVolatilityTickThreshold(params.volatilityTickThreshold);
        }
        DynamicFeeState storage st = states[poolId];
        st.baseFee = params.baseFee;
        st.maxFee = params.maxFee;
        st.volatilityTickThreshold = params.volatilityTickThreshold > 0 ? params.volatilityTickThreshold : int24(50);
    }

    function compute(mapping(PoolId => DynamicFeeState) storage states, PoolId poolId, int24 currentTick)
        external
        returns (uint24 fee)
    {
        DynamicFeeState storage state = states[poolId];
        if (state.maxFee == 0) return 0;

        int256 tickDelta = currentTick >= state.lastObservedTick
            ? int256(currentTick) - int256(state.lastObservedTick)
            : int256(state.lastObservedTick) - int256(currentTick);

        uint24 absDelta = uint24(uint256(tickDelta > 1000 ? int256(1000) : tickDelta));
        if (block.number > state.lastUpdateBlock) {
            state.rollingVolatilityTicks = (state.rollingVolatilityTicks * 3 + absDelta) / 4;
            state.lastObservedTick = currentTick;
            state.lastUpdateBlock = uint32(block.number);
        } else if (absDelta > state.rollingVolatilityTicks) {
            state.rollingVolatilityTicks = (state.rollingVolatilityTicks * 3 + absDelta) / 4;
        }

        uint24 threshold = uint24(state.volatilityTickThreshold);
        if (state.rollingVolatilityTicks == 0 || threshold == 0) {
            return state.baseFee;
        }

        if (state.rollingVolatilityTicks >= threshold) {
            return state.maxFee;
        }

        uint256 feeRange = state.maxFee - state.baseFee;
        uint256 surcharge = Math.mulDiv(feeRange, state.rollingVolatilityTicks, threshold, Math.Rounding.Floor);
        fee = state.baseFee + uint24(surcharge);
    }
}

/// @title DynamicFeeBlock
/// @notice Group 1 (Fees) — Block #1: Volatility-responsive dynamic LP fee (`afterInitialize`, `beforeSwap`).
/// @dev Trust Level: Low (purely algorithmic once initialized; bounded by MAX_DYNAMIC_FEE = 50_000 = 5%).
abstract contract DynamicFeeBlock is IHookRigBlock {
    mapping(PoolId poolId => DynamicFeeLogic.DynamicFeeState state) internal _dynamicFeeStates;

    function _stageDynamicFee(PoolId poolId, DynamicFeeParams calldata params) internal {
        DynamicFeeLogic.stage(_dynamicFeeStates, poolId, params);
    }

    function _anchorDynamicFeeTick(PoolId poolId, int24 initialTick) internal {
        DynamicFeeLogic.DynamicFeeState storage st = _dynamicFeeStates[poolId];
        st.lastObservedTick = initialTick;
        st.lastUpdateBlock = uint32(block.number);
    }

    /// @notice Computes the dynamic LP fee and updates the truncated EMA tick volatility tracker.
    function _computeDynamicFee(PoolId poolId, int24 currentTick) internal returns (uint24 fee) {
        return DynamicFeeLogic.compute(_dynamicFeeStates, poolId, currentTick);
    }
}
