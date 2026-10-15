// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library OracleLogic {
    int24 internal constant MAX_ORACLE_TICK_DELTA_PER_SEC = 100;

    struct OracleObservation {
        uint32 blockTimestamp;
        int24 lastTick;
        int56 tickCumulative;
        bool initialized;
    }

    event OracleCheckpointed(PoolId indexed poolId, int24 tick, int56 tickCumulative, uint32 timestamp);

    function updateCheckpoint(
        mapping(PoolId => OracleObservation) storage observations,
        PoolId poolId,
        int24 currentTick
    ) external {
        OracleObservation storage obs = observations[poolId];
        if (!obs.initialized) return;

        uint32 currentTs = uint32(block.timestamp);
        uint32 elapsed = currentTs - obs.blockTimestamp;
        if (elapsed == 0) return;

        int24 diff = currentTick - obs.lastTick;
        int24 maxChange = int24(int256(uint256(elapsed)) * int256(MAX_ORACLE_TICK_DELTA_PER_SEC));
        if (diff > maxChange) {
            currentTick = obs.lastTick + maxChange;
        } else if (diff < -maxChange) {
            currentTick = obs.lastTick - maxChange;
        }

        obs.tickCumulative += int56(currentTick) * int56(uint56(elapsed));
        obs.lastTick = currentTick;
        obs.blockTimestamp = currentTs;

        emit OracleCheckpointed(poolId, currentTick, obs.tickCumulative, currentTs);
    }
}

/// @title OracleBlock
/// @notice Group 5 (Trading) — Block #17: Truncated geometric TWAP oracle checkpointing
///         (`afterInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, `beforeSwap`).
/// @dev Trust Level: Low (truncates max tick delta per block to resist single-block flash-loan manipulation).
abstract contract OracleBlock is IHookRigBlock {
    mapping(PoolId poolId => OracleLogic.OracleObservation latest) internal _oracleObservations;

    function _initOracle(PoolId poolId, int24 initialTick) internal {
        _oracleObservations[poolId] = OracleLogic.OracleObservation({
            blockTimestamp: uint32(block.timestamp), lastTick: initialTick, tickCumulative: 0, initialized: true
        });
    }

    function _updateOracleCheckpoint(PoolId poolId, int24 currentTick) internal {
        OracleLogic.updateCheckpoint(_oracleObservations, poolId, currentTick);
    }

    function getOracleTickCumulative(PoolId poolId) external view returns (int24 lastTick, int56 tickCumulative) {
        OracleLogic.OracleObservation storage obs = _oracleObservations[poolId];
        return (obs.lastTick, obs.tickCumulative);
    }
}
