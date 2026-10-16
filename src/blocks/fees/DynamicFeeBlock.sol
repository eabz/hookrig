// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";
import {HookPermissionMasks} from "../../libraries/HookPermissionMasks.sol";
import {ManagedFeeLogic} from "./ManagedFeeBlock.sol";
import {MarketHoursFeeLogic} from "./MarketHoursFeeBlock.sol";
import {AntiSnipeLogic} from "../protection/AntiSnipeBlock.sol";
import {MEVProtectionLogic} from "../protection/MEVProtectionBlock.sol";
import {JITGuardLogic} from "../protection/JITGuardBlock.sol";
import {ArbRecaptureLogic} from "../protection/ArbRecaptureBlock.sol";

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
    ) public {
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

    function initFeeAndProtectionBlocks(
        mapping(PoolId => DynamicFeeState) storage dynamicFeeStates,
        mapping(PoolId => ManagedFeeLogic.ManagedFeeState) storage managedFeeStates,
        mapping(PoolId => IHookRigBlock.MarketHoursFeeParams) storage marketHoursConfigs,
        mapping(PoolId => AntiSnipeLogic.AntiSnipeState) storage antiSnipeStates,
        mapping(PoolId => MEVProtectionLogic.MEVProtectionState) storage mevStates,
        mapping(PoolId => JITGuardLogic.JITConfig) storage jitConfigs,
        mapping(PoolId => ArbRecaptureLogic.ArbRecaptureState) storage arbStates,
        PoolId poolId,
        IHookRigBlock.PoolStackConfig calldata config,
        uint32 bitmap,
        address admin
    ) external {
        if ((bitmap & HookPermissionMasks.BIT_DYNAMIC_FEE) != 0) {
            stage(dynamicFeeStates, poolId, config.dynamicFee);
        }
        if ((bitmap & HookPermissionMasks.BIT_MANAGED_FEE) != 0) {
            ManagedFeeLogic.stage(managedFeeStates, poolId, config.managedFee, admin);
        }
        if ((bitmap & HookPermissionMasks.BIT_MARKET_HOURS_FEE) != 0) {
            MarketHoursFeeLogic.init(marketHoursConfigs, poolId, config.marketHoursFee);
        }
        if ((bitmap & HookPermissionMasks.BIT_ANTI_SNIPE) != 0) {
            AntiSnipeLogic.init(antiSnipeStates, poolId, config.antiSnipe);
        }
        if ((bitmap & (HookPermissionMasks.BIT_MEV_PROTECTION | HookPermissionMasks.BIT_JIT_GUARD)) != 0) {
            MEVProtectionLogic.init(mevStates, jitConfigs, poolId, config.mevProtection);
        }
        if ((bitmap & HookPermissionMasks.BIT_ARB_RECAPTURE) != 0) {
            ArbRecaptureLogic.stage(arbStates, poolId, config.arbRecapture);
        }
    }

    /// @notice Computes the dynamic LP fee from prior-swap tick displacement and updates the EWMA volatility tracker.
    /// @dev Observation model (`S4-F11`):
    ///      - Because Uniswap v4 requires dynamic LP fees to be returned in `beforeSwap` (before the current swap
    ///        executes and moves the pool tick), `compute` measures completed prior-swap tick displacement
    ///        (`|currentTick - lastObservedTick|`) and pairs with `MEVProtectionBlock`, `ArbRecaptureBlock`, and
    ///        `AntiSnipeBlock` to bound single-swap impact on fresh pools.
    ///      - Within the same block (`block.number == state.lastUpdateBlock`), `rollingVolatilityTicks` only ratchets
    ///        upward (`absDelta > state.rollingVolatilityTicks`) and `lastObservedTick` remains anchored at the
    ///        block's initial tick, preventing an attacker from executing same-block zero-delta wash swaps to decay
    ///        `rollingVolatilityTicks` back toward `baseFee`. Downward EWMA decay occurs only when advancing to a new block.
    function compute(mapping(PoolId => DynamicFeeState) storage states, PoolId poolId, int24 currentTick)
        public
        returns (uint24 fee)
    {
        DynamicFeeState storage state = states[poolId];
        if (state.maxFee == 0) return 0;

        int256 tickDelta = currentTick >= state.lastObservedTick
            ? int256(currentTick) - int256(state.lastObservedTick)
            : int256(state.lastObservedTick) - int256(currentTick);

        uint24 absDelta = uint24(uint256(tickDelta > 1000 ? int256(1000) : tickDelta));
        if (block.number > state.lastUpdateBlock) {
            state.rollingVolatilityTicks = (state.rollingVolatilityTicks * 3 + absDelta + (absDelta > 0 ? 3 : 0)) / 4;
            state.lastObservedTick = currentTick;
            state.lastUpdateBlock = uint32(block.number);
        } else if (absDelta > state.rollingVolatilityTicks) {
            state.rollingVolatilityTicks = (state.rollingVolatilityTicks * 3 + absDelta + 3) / 4;
            state.lastObservedTick = currentTick;
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

    /// @notice Optional post-swap volatility observation helper that ratchets `rollingVolatilityTicks` upward if
    ///         a swap's `postSwapTick` displacement exceeds the current rolling volatility without decaying it.
    function recordPostSwapTick(
        mapping(PoolId => DynamicFeeState) storage states,
        PoolId poolId,
        int24 preSwapTick,
        int24 postSwapTick
    ) external {
        DynamicFeeState storage state = states[poolId];
        if (state.maxFee == 0) return;

        int256 swapDelta = postSwapTick >= preSwapTick
            ? int256(postSwapTick) - int256(preSwapTick)
            : int256(preSwapTick) - int256(postSwapTick);
        uint24 absDelta = uint24(uint256(swapDelta > 1000 ? int256(1000) : swapDelta));
        if (absDelta > state.rollingVolatilityTicks) {
            state.rollingVolatilityTicks = (state.rollingVolatilityTicks * 3 + absDelta + 3) / 4;
        }
    }

    function resolveBeforeSwapFee(
        mapping(PoolId => DynamicFeeState) storage dynamicFeeStates,
        mapping(PoolId => ManagedFeeLogic.ManagedFeeState) storage managedFeeStates,
        mapping(PoolId => IHookRigBlock.MarketHoursFeeParams) storage marketHoursConfigs,
        mapping(PoolId => AntiSnipeLogic.AntiSnipeState) storage antiSnipeStates,
        PoolId poolId,
        uint32 bitmap,
        int24 currentTick
    ) external returns (uint24 lpFeeOverride) {
        if ((bitmap & HookPermissionMasks.FEE_BLOCKS_MASK) == 0) {
            return 0;
        }

        uint24 resolvedFee = 0;

        if ((bitmap & HookPermissionMasks.BIT_DYNAMIC_FEE) != 0) {
            uint24 dynFee = compute(dynamicFeeStates, poolId, currentTick);
            if (dynFee > resolvedFee) resolvedFee = dynFee;
        }

        if ((bitmap & HookPermissionMasks.BIT_MANAGED_FEE) != 0) {
            uint24 mgdFee = managedFeeStates[poolId].currentFee;
            if (mgdFee > resolvedFee) resolvedFee = mgdFee;
        }

        if ((bitmap & HookPermissionMasks.BIT_MARKET_HOURS_FEE) != 0) {
            uint24 mktFee = MarketHoursFeeLogic.computeFee(marketHoursConfigs, poolId);
            if (mktFee > resolvedFee) resolvedFee = mktFee;
        }

        if ((bitmap & HookPermissionMasks.BIT_ANTI_SNIPE) != 0) {
            uint24 snipeFee = AntiSnipeLogic.computeFee(antiSnipeStates, poolId);
            if (snipeFee > resolvedFee) resolvedFee = snipeFee;
        }

        if (resolvedFee > LPFeeLibrary.MAX_LP_FEE) {
            resolvedFee = LPFeeLibrary.MAX_LP_FEE;
        }

        return resolvedFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }
}

/// @title DynamicFeeBlock
/// @notice Group 1 (Fees) — Block #1: Volatility-responsive dynamic LP fee (`afterInitialize`, `beforeSwap`).
/// @dev Trust Level: Low (purely algorithmic once initialized; bounded by MAX_DYNAMIC_FEE = 50_000 = 5%).
///      Observes completed prior-swap tick displacement in `beforeSwap` and prevents same-block zero-delta wash
///      swaps from decaying `rollingVolatilityTicks` (`S4-F11`).
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

    /// @notice Records post-swap tick displacement to ratchet intra-block volatility upward without decaying it.
    function _recordDynamicFeePostSwapTick(PoolId poolId, int24 preSwapTick, int24 postSwapTick) internal {
        DynamicFeeLogic.recordPostSwapTick(_dynamicFeeStates, poolId, preSwapTick, postSwapTick);
    }
}
