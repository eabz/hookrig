// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library CircuitBreakerLogic {
    struct CircuitBreakerState {
        int24 maxWindowTickDeviation;
        uint32 windowSeconds;
        int24 anchorTick;
        uint32 windowStartTimestamp;
    }

    error CircuitBreakerTriggered(PoolId poolId, int24 anchorTick, int24 postSwapTick, int24 maxDeviation);

    function checkAndAdvance(
        mapping(PoolId => CircuitBreakerState) storage states,
        PoolId poolId,
        int24 preSwapTick,
        int24 postSwapTick
    ) external {
        CircuitBreakerState storage cb = states[poolId];
        if (cb.maxWindowTickDeviation <= 0) return;

        if (cb.windowStartTimestamp == 0 || block.timestamp >= cb.windowStartTimestamp + cb.windowSeconds) {
            cb.anchorTick = preSwapTick;
            cb.windowStartTimestamp = uint32(block.timestamp);
        }

        int24 dev = postSwapTick >= cb.anchorTick ? postSwapTick - cb.anchorTick : cb.anchorTick - postSwapTick;
        if (dev > cb.maxWindowTickDeviation) {
            revert CircuitBreakerTriggered(poolId, cb.anchorTick, postSwapTick, cb.maxWindowTickDeviation);
        }
    }
}

/// @title CircuitBreakerBlock
/// @notice Group 2 (Protection & Access) — Expansion Block #19: Rolling price-band circuit breaker (`beforeSwap`, `afterSwap`).
/// @dev Trust Level: Low (protects Stock-quoted / RWA, Stable-pair, and Treasury-backed pools from flash crashes).
abstract contract CircuitBreakerBlock is IHookRigBlock {
    mapping(PoolId poolId => CircuitBreakerLogic.CircuitBreakerState state) internal _circuitBreakers;

    function _initCircuitBreaker(PoolId poolId, CircuitBreakerParams calldata params) internal {
        _circuitBreakers[poolId] = CircuitBreakerLogic.CircuitBreakerState({
            maxWindowTickDeviation: params.maxWindowTickDeviation,
            windowSeconds: params.windowSeconds > 0 ? params.windowSeconds : 300,
            anchorTick: 0,
            windowStartTimestamp: 0
        });
    }

    function _checkAndAdvanceCircuitBreaker(PoolId poolId, int24 preSwapTick, int24 postSwapTick) internal {
        CircuitBreakerLogic.checkAndAdvance(_circuitBreakers, poolId, preSwapTick, postSwapTick);
    }
}
