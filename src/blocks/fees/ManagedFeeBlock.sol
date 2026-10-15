// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

/// @title ManagedFeeBlock
/// @notice Group 1 (Fees) — Block #2: Manager-configurable LP fee with an immutable hard cap (`afterInitialize`).
/// @dev Trust Level: Medium (a designated manager can update the fee, strictly bounded by `feeCap <= 5%`).
abstract contract ManagedFeeBlock is IHookRigBlock {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant MAX_MANAGED_FEE_CAP = 50_000; // 5.00%

    struct ManagedFeeState {
        uint24 currentFee;
        uint24 feeCap;
        address manager;
    }

    mapping(PoolId poolId => ManagedFeeState state) internal _managedFeeStates;

    event ManagedFeeUpdated(PoolId indexed poolId, uint24 oldFee, uint24 newFee, address indexed manager);

    error UnauthorizedFeeManager(address caller);
    error ManagedFeeExceedsCap(uint24 requestedFee, uint24 feeCap);

    function _stageManagedFee(PoolId poolId, ManagedFeeParams calldata params) internal {
        uint24 cap = params.feeCap == 0 || params.feeCap > MAX_MANAGED_FEE_CAP ? MAX_MANAGED_FEE_CAP : params.feeCap;
        if (params.startingFee > cap) {
            revert ManagedFeeExceedsCap(params.startingFee, cap);
        }
        _managedFeeStates[poolId] =
            ManagedFeeState({currentFee: params.startingFee, feeCap: cap, manager: params.manager});
    }

    function _applyInitialManagedFee(IPoolManager manager, PoolKey calldata key, PoolId poolId) internal {
        manager.updateDynamicLPFee(key, _managedFeeStates[poolId].currentFee);
    }

    function setManagedPoolFee(PoolKey calldata key, uint24 newFee) external {
        PoolId poolId = key.toId();
        ManagedFeeState storage state = _managedFeeStates[poolId];
        if (msg.sender != state.manager) revert UnauthorizedFeeManager(msg.sender);
        if (newFee > state.feeCap) revert ManagedFeeExceedsCap(newFee, state.feeCap);

        uint24 oldFee = state.currentFee;
        state.currentFee = newFee;
        _updatePoolManagerDynamicFee(key, newFee);
        emit ManagedFeeUpdated(poolId, oldFee, newFee, msg.sender);
    }

    function _getManagedFee(PoolId poolId) internal view returns (uint24) {
        return _managedFeeStates[poolId].currentFee;
    }

    function _updatePoolManagerDynamicFee(PoolKey calldata key, uint24 newFee) internal virtual;
}
