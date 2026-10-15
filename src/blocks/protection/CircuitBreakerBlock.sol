// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

/// @title CircuitBreakerBlock
/// @notice Group 2 (Protection & Access) — Expansion Block #19: Rolling price-band circuit breaker (`beforeSwap`, `afterSwap`).
/// @dev Trust Level: Low (protects Stock-quoted / RWA and Treasury-backed pools from flash crashes).
abstract contract CircuitBreakerBlock is IHookRigBlock {
    struct CircuitBreakerState {
        int24 maxWindowTickDeviation;
        uint32 windowSeconds;
        int24 anchorTick;
        uint32 windowStartTimestamp;
    }

    mapping(PoolId poolId => CircuitBreakerState state) internal _circuitBreakers;

    error CircuitBreakerTriggered(PoolId poolId, int24 anchorTick, int24 postSwapTick, int24 maxDeviation);

    function _initCircuitBreaker(PoolId poolId, int24 maxWindowTickDeviation, uint32 windowSeconds, int24 initialTick)
        internal
    {
        _circuitBreakers[poolId] = CircuitBreakerState({
            maxWindowTickDeviation: maxWindowTickDeviation,
            windowSeconds: windowSeconds > 0 ? windowSeconds : 300,
            anchorTick: initialTick,
            windowStartTimestamp: uint32(block.timestamp)
        });
    }

    function _checkAndAdvanceCircuitBreaker(PoolId poolId, int24 preSwapTick, int24 postSwapTick) internal {
        CircuitBreakerState storage cb = _circuitBreakers[poolId];
        if (cb.maxWindowTickDeviation <= 0) return;

        if (block.timestamp >= cb.windowStartTimestamp + cb.windowSeconds) {
            cb.anchorTick = preSwapTick;
            cb.windowStartTimestamp = uint32(block.timestamp);
        }

        int24 dev = postSwapTick >= cb.anchorTick ? postSwapTick - cb.anchorTick : cb.anchorTick - postSwapTick;
        if (dev > cb.maxWindowTickDeviation) {
            revert CircuitBreakerTriggered(poolId, cb.anchorTick, postSwapTick, cb.maxWindowTickDeviation);
        }
    }
}
