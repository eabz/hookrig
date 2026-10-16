// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

interface IHasPoolManager {
    function poolManager() external view returns (IPoolManager);
}

library ManagedFeeLogic {
    uint24 internal constant MAX_MANAGED_FEE_CAP = 50_000; // 5.00%

    struct ManagedFeeState {
        uint24 currentFee;
        uint24 feeCap;
        address manager;
    }

    event ManagedFeeUpdated(PoolId indexed poolId, uint24 oldFee, uint24 newFee, address indexed manager);

    error UnauthorizedFeeManager(address caller);
    error ManagedFeeExceedsCap(uint24 requestedFee, uint24 feeCap);

    function stage(
        mapping(PoolId => ManagedFeeState) storage states,
        PoolId poolId,
        IHookRigBlock.ManagedFeeParams calldata params,
        address fallbackAdmin
    ) external {
        if (params.feeCap > MAX_MANAGED_FEE_CAP) {
            revert ManagedFeeExceedsCap(params.feeCap, MAX_MANAGED_FEE_CAP);
        }
        uint24 cap = params.feeCap;
        if (params.startingFee > cap) {
            revert ManagedFeeExceedsCap(params.startingFee, cap);
        }
        address mgr = params.manager != address(0) ? params.manager : fallbackAdmin;
        states[poolId] = ManagedFeeState({currentFee: params.startingFee, feeCap: cap, manager: mgr});
    }

    function update(mapping(PoolId => ManagedFeeState) storage states, PoolId poolId, address caller, uint24 newFee)
        external
        returns (bool poolInitialized)
    {
        ManagedFeeState storage state = states[poolId];
        if (caller != state.manager) revert UnauthorizedFeeManager(caller);
        if (newFee > state.feeCap) revert ManagedFeeExceedsCap(newFee, state.feeCap);

        uint24 oldFee = state.currentFee;
        state.currentFee = newFee;
        emit ManagedFeeUpdated(poolId, oldFee, newFee, caller);

        IPoolManager pm = IHasPoolManager(address(this)).poolManager();
        if (address(pm) != address(0)) {
            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(pm, poolId);
            poolInitialized = sqrtPriceX96 != 0;
        }
    }
}

/// @title ManagedFeeBlock
/// @notice Group 1 (Fees) — Block #2: Manager-configurable LP fee with an immutable hard cap (`afterInitialize`).
/// @dev Trust Level: Medium (a designated manager can update the fee, strictly bounded by `feeCap <= 5%`).
abstract contract ManagedFeeBlock is IHookRigBlock {
    using PoolIdLibrary for PoolKey;

    mapping(PoolId poolId => ManagedFeeLogic.ManagedFeeState state) internal _managedFeeStates;

    error UnauthorizedFeeManager(address caller);
    error ManagedFeeExceedsCap(uint24 requestedFee, uint24 feeCap);

    function _stageManagedFee(PoolId poolId, ManagedFeeParams calldata params, address fallbackAdmin) internal {
        ManagedFeeLogic.stage(_managedFeeStates, poolId, params, fallbackAdmin);
    }

    function _applyInitialManagedFee(IPoolManager manager, PoolKey calldata key, PoolId poolId) internal {
        manager.updateDynamicLPFee(key, _managedFeeStates[poolId].currentFee);
    }

    /// @notice Updates the managed LP fee for `key` (`S2-F45`).
    /// @dev Only syncs `PoolManager.updateDynamicLPFee` when the pool has already been initialized (`sqrtPriceX96 != 0`);
    ///      if called before `PoolManager.initialize`, the updated fee is stored in `_managedFeeStates[poolId].currentFee`
    ///      and applied during `afterInitialize`.
    function setManagedPoolFee(PoolKey calldata key, uint24 newFee) external {
        if (ManagedFeeLogic.update(_managedFeeStates, key.toId(), msg.sender, newFee)) {
            _updatePoolManagerDynamicFee(key, newFee);
        }
    }

    function _getManagedFee(PoolId poolId) internal view returns (uint24) {
        return _managedFeeStates[poolId].currentFee;
    }

    function _updatePoolManagerDynamicFee(PoolKey calldata key, uint24 newFee) internal virtual;
}
