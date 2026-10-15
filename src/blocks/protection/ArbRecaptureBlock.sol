// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library ArbRecaptureLogic {
    uint16 internal constant MAX_ARB_RECAPTURE_SHARE_BPS = 8000; // 80% of excess spread
    uint16 internal constant MAX_ARB_EFFECTIVE_CUT_BPS = 1000; // Hard cap: at most 10% of swap output

    struct ArbRecaptureState {
        uint16 recaptureShareBps;
        int24 arbTriggerTickDelta;
        int24 referenceTick;
        uint32 lastUpdatedBlock;
    }

    error ArbRecaptureShareTooHigh(uint16 requestedBps);
    error InvalidArbTriggerTickDelta(int24 triggerTickDelta);

    function stage(
        mapping(PoolId => ArbRecaptureState) storage states,
        PoolId poolId,
        IHookRigBlock.ArbRecaptureParams calldata params
    ) external {
        if (params.recaptureShareBps > MAX_ARB_RECAPTURE_SHARE_BPS) {
            revert ArbRecaptureShareTooHigh(params.recaptureShareBps);
        }
        if (params.arbTriggerTickDelta < 0 || params.arbTriggerTickDelta > 100_000) {
            revert InvalidArbTriggerTickDelta(params.arbTriggerTickDelta);
        }
        ArbRecaptureState storage st = states[poolId];
        st.recaptureShareBps = params.recaptureShareBps;
        st.arbTriggerTickDelta = params.arbTriggerTickDelta > 0 ? params.arbTriggerTickDelta : int24(20);
    }

    function computeCutBps(
        mapping(PoolId => ArbRecaptureState) storage states,
        PoolId poolId,
        int24 preSwapTick,
        int24 postSwapTick
    ) external returns (uint16 effectiveCutBps) {
        ArbRecaptureState storage state = states[poolId];
        if (state.recaptureShareBps == 0) return 0;

        if (block.number > state.lastUpdatedBlock) {
            state.referenceTick = preSwapTick;
            state.lastUpdatedBlock = uint32(block.number);
        }

        int24 refTick = state.referenceTick;
        int256 swapTickMoved = postSwapTick >= preSwapTick
            ? int256(postSwapTick) - int256(preSwapTick)
            : int256(preSwapTick) - int256(postSwapTick);
        int256 refTickMoved =
            postSwapTick >= refTick ? int256(postSwapTick) - int256(refTick) : int256(refTick) - int256(postSwapTick);
        int256 tickMoved = refTickMoved > swapTickMoved ? refTickMoved : swapTickMoved;

        if (tickMoved <= int256(state.arbTriggerTickDelta)) {
            return 0;
        }

        uint256 excessTicks = uint256(tickMoved - int256(state.arbTriggerTickDelta));
        uint256 rawCutBps = Math.mulDiv(excessTicks, state.recaptureShareBps, 10_000, Math.Rounding.Floor);
        if (rawCutBps > MAX_ARB_EFFECTIVE_CUT_BPS) {
            rawCutBps = MAX_ARB_EFFECTIVE_CUT_BPS;
        }
        effectiveCutBps = uint16(rawCutBps);
    }
}

/// @title ArbRecaptureBlock
/// @notice Group 2 (Protection & Access) — Block #6: Captures a share of arbitrage profit and donates it to LPs
///         (`beforeSwap`, `afterSwap`, `afterSwapReturnDelta`).
/// @dev Trust Level: Medium (recaptureShareBps capped at 8000 = 80% of measured dislocation spread; 100% paid to LPs).
abstract contract ArbRecaptureBlock is IHookRigBlock {
    mapping(PoolId poolId => ArbRecaptureLogic.ArbRecaptureState state) internal _arbStates;

    function _stageArbRecapture(PoolId poolId, ArbRecaptureParams calldata params) internal {
        ArbRecaptureLogic.stage(_arbStates, poolId, params);
    }

    function _anchorArbRecaptureTick(PoolId poolId, int24 initialTick) internal {
        ArbRecaptureLogic.ArbRecaptureState storage st = _arbStates[poolId];
        st.referenceTick = initialTick;
        st.lastUpdatedBlock = uint32(block.number);
    }

    /// @notice Calculates the basis-point cut of swap output attributable to arbitrage dislocation.
    function _computeArbRecaptureCutBps(PoolId poolId, int24 preSwapTick, int24 postSwapTick)
        internal
        returns (uint16 effectiveCutBps)
    {
        return ArbRecaptureLogic.computeCutBps(_arbStates, poolId, preSwapTick, postSwapTick);
    }
}
