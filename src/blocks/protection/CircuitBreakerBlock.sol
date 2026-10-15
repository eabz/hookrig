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
    error InvalidCircuitBreakerConfig(int24 maxWindowTickDeviation, uint32 windowSeconds);

    function checkAndAdvance(
        mapping(PoolId => CircuitBreakerState) storage states,
        PoolId poolId,
        int24 preSwapTick,
        int24 postSwapTick
    ) external {
        CircuitBreakerState storage cb = states[poolId];
        if (cb.maxWindowTickDeviation <= 0) return;

        if (cb.windowStartTimestamp == 0) {
            cb.anchorTick = preSwapTick;
            cb.windowStartTimestamp = uint32(block.timestamp);
        } else if (block.timestamp >= uint256(cb.windowStartTimestamp) + uint256(cb.windowSeconds)) {
            cb.anchorTick = postSwapTick;
            cb.windowStartTimestamp = uint32(block.timestamp);
        }

        int256 dev = postSwapTick >= cb.anchorTick
            ? int256(postSwapTick) - int256(cb.anchorTick)
            : int256(cb.anchorTick) - int256(postSwapTick);
        if (dev > int256(cb.maxWindowTickDeviation)) {
            revert CircuitBreakerTriggered(poolId, cb.anchorTick, postSwapTick, cb.maxWindowTickDeviation);
        }
    }
}

/// @title CircuitBreakerBlock
/// @notice Group 2 (Protection & Access) — Expansion Block #19: Rolling price-band circuit breaker (`beforeSwap`, `afterSwap`).
/// @dev Trust Level: Low (protects Stock-quoted / RWA, Stable-pair, and Treasury-backed pools from flash crashes).
abstract contract CircuitBreakerBlock is IHookRigBlock {
    mapping(PoolId poolId => CircuitBreakerLogic.CircuitBreakerState state) internal _circuitBreakers;

    uint32 internal constant MAX_WINDOW_SECONDS = 86_400; // Max 24h rolling window so pools auto-recover

    function _initCircuitBreaker(PoolId poolId, CircuitBreakerParams calldata params) internal {
        if (
            params.maxWindowTickDeviation < 0
                || (params.maxWindowTickDeviation > 0 && params.maxWindowTickDeviation < 10)
                || params.maxWindowTickDeviation > 887_272 || params.windowSeconds > MAX_WINDOW_SECONDS
                || (params.windowSeconds > 0 && params.windowSeconds < 10)
        ) {
            revert CircuitBreakerLogic.InvalidCircuitBreakerConfig(params.maxWindowTickDeviation, params.windowSeconds);
        }
        uint32 win = params.windowSeconds > 0 ? params.windowSeconds : 300;
        _circuitBreakers[poolId] = CircuitBreakerLogic.CircuitBreakerState({
            maxWindowTickDeviation: params.maxWindowTickDeviation,
            windowSeconds: win,
            anchorTick: 0,
            windowStartTimestamp: 0
        });
    }

    function _checkAndAdvanceCircuitBreaker(PoolId poolId, int24 preSwapTick, int24 postSwapTick) internal {
        CircuitBreakerLogic.checkAndAdvance(_circuitBreakers, poolId, preSwapTick, postSwapTick);
    }
}
