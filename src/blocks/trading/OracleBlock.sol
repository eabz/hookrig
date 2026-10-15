// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";
import {HookPermissionMasks} from "../../libraries/HookPermissionMasks.sol";
import {TWAMMLogic} from "./TWAMMBlock.sol";
import {IHasPoolManager} from "./LimitOrdersBlock.sol";
import {DynamicFeeLogic} from "../fees/DynamicFeeBlock.sol";
import {ManagedFeeLogic} from "../fees/ManagedFeeBlock.sol";
import {ArbRecaptureLogic} from "../protection/ArbRecaptureBlock.sol";

library OracleLogic {
    using PoolIdLibrary for PoolKey;

    int24 internal constant MAX_ORACLE_TICK_DELTA_PER_SEC = 100;

    struct OracleObservation {
        uint32 blockTimestamp;
        int24 lastTick;
        int56 tickCumulative;
        bool initialized;
    }

    event OracleCheckpointed(PoolId indexed poolId, int24 tick, int56 tickCumulative, uint32 timestamp);

    function initAfterInitialize(
        mapping(PoolId => OracleObservation) storage oracleObservations,
        mapping(PoolId => TWAMMLogic.TWAMMState) storage twammStates,
        mapping(PoolId => int24) storage limitOrderLastTick,
        mapping(PoolId => DynamicFeeLogic.DynamicFeeState) storage dynamicFeeStates,
        mapping(PoolId => ManagedFeeLogic.ManagedFeeState) storage managedFeeStates,
        mapping(PoolId => ArbRecaptureLogic.ArbRecaptureState) storage arbStates,
        IPoolManager poolManager,
        PoolKey calldata key,
        uint32 bitmap,
        int24 tick
    ) external {
        PoolId poolId = key.toId();
        if ((bitmap & HookPermissionMasks.BIT_ORACLE) != 0) {
            oracleObservations[poolId] = OracleObservation({
                blockTimestamp: uint32(block.timestamp), lastTick: tick, tickCumulative: 0, initialized: true
            });
        }
        if ((bitmap & HookPermissionMasks.BIT_TWAMM) != 0) {
            twammStates[poolId].lastVirtualOrderTimestamp = uint64(block.timestamp);
        }
        if ((bitmap & HookPermissionMasks.BIT_LIMIT_ORDERS) != 0) {
            limitOrderLastTick[poolId] = tick;
        }
        if ((bitmap & HookPermissionMasks.BIT_DYNAMIC_FEE) != 0) {
            DynamicFeeLogic.DynamicFeeState storage st = dynamicFeeStates[poolId];
            st.lastObservedTick = tick;
            st.lastUpdateBlock = uint32(block.number);
        }
        if ((bitmap & HookPermissionMasks.BIT_MANAGED_FEE) != 0) {
            poolManager.updateDynamicLPFee(key, managedFeeStates[poolId].currentFee);
        }
        if ((bitmap & HookPermissionMasks.BIT_ARB_RECAPTURE) != 0) {
            ArbRecaptureLogic.ArbRecaptureState storage arbSt = arbStates[poolId];
            arbSt.referenceTick = tick;
            arbSt.lastUpdatedBlock = uint32(block.number);
        }
    }

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

        currentTick = _clampTick(obs.lastTick, currentTick, elapsed);

        // The pre-swap tick passed here is the price that held since the previous checkpoint, so it (not the
        // previous checkpoint's tick) weights the elapsed interval, as in the Uniswap v3 oracle.
        obs.tickCumulative += int56(currentTick) * int56(uint56(elapsed));
        obs.lastTick = currentTick;
        obs.blockTimestamp = currentTs;

        emit OracleCheckpointed(poolId, currentTick, obs.tickCumulative, currentTs);
    }

    /// @notice Extrapolates the cumulative to now with the live pool tick (clamped like a checkpoint), which is the
    ///         price that has held since the last checkpoint.
    function observeAtCurrentTime(
        mapping(PoolId => OracleObservation) storage observations,
        IPoolManager manager,
        PoolId poolId
    ) external view returns (int24 lastTick, int56 extrapolatedTickCumulative, uint32 lastTimestamp) {
        OracleObservation storage obs = observations[poolId];
        lastTick = obs.lastTick;
        lastTimestamp = obs.blockTimestamp;
        extrapolatedTickCumulative = obs.tickCumulative;
        if (obs.initialized && uint32(block.timestamp) > obs.blockTimestamp) {
            uint32 elapsed = uint32(block.timestamp) - obs.blockTimestamp;
            (, int24 liveTick,,) = StateLibrary.getSlot0(manager, poolId);
            extrapolatedTickCumulative += int56(_clampTick(obs.lastTick, liveTick, elapsed)) * int56(uint56(elapsed));
        }
    }

    /// @dev Limits the move from `lastTick` to MAX_ORACLE_TICK_DELTA_PER_SEC per elapsed second.
    function _clampTick(int24 lastTick, int24 tick, uint32 elapsed) private pure returns (int24) {
        int256 diff = int256(tick) - int256(lastTick);
        int256 maxChange = int256(uint256(elapsed)) * int256(MAX_ORACLE_TICK_DELTA_PER_SEC);
        int256 nextTick = int256(tick);
        if (diff > maxChange) {
            nextTick = int256(lastTick) + maxChange;
        } else if (diff < -maxChange) {
            nextTick = int256(lastTick) - maxChange;
        }
        if (nextTick > int256(TickMath.MAX_TICK)) {
            nextTick = int256(TickMath.MAX_TICK);
        } else if (nextTick < int256(TickMath.MIN_TICK)) {
            nextTick = int256(TickMath.MIN_TICK);
        }
        return int24(nextTick);
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

    function observeOracleAtCurrentTime(PoolId poolId)
        external
        view
        returns (int24 lastTick, int56 extrapolatedTickCumulative, uint32 lastTimestamp)
    {
        return
            OracleLogic.observeAtCurrentTime(_oracleObservations, IHasPoolManager(address(this)).poolManager(), poolId);
    }
}
