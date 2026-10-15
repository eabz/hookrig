// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library AntiSnipeLogic {
    uint24 internal constant MAX_ANTI_SNIPE_LAUNCH_FEE = 800_000; // 80.00%
    uint24 internal constant MAX_ANTI_SNIPE_NORMAL_FEE = 50_000; // 5.00%
    uint32 internal constant MAX_ANTI_SNIPE_DECAY_BLOCKS = 50_400; // ~7 days

    struct AntiSnipeState {
        uint24 launchFee;
        uint24 normalFee;
        uint32 startBlock;
        uint32 decayBlocks;
    }

    error InvalidAntiSnipeConfig(uint24 launchFee, uint24 normalFee);

    function init(
        mapping(PoolId => AntiSnipeState) storage states,
        PoolId poolId,
        IHookRigBlock.AntiSnipeParams calldata params
    ) external {
        if (
            params.launchFee < params.normalFee || params.launchFee > MAX_ANTI_SNIPE_LAUNCH_FEE
                || params.normalFee > MAX_ANTI_SNIPE_NORMAL_FEE || params.decayBlocks > MAX_ANTI_SNIPE_DECAY_BLOCKS
        ) {
            revert InvalidAntiSnipeConfig(params.launchFee, params.normalFee);
        }
        states[poolId] = AntiSnipeState({
            launchFee: params.launchFee,
            normalFee: params.normalFee,
            startBlock: uint32(block.number),
            decayBlocks: params.decayBlocks
        });
    }

    function computeFee(mapping(PoolId => AntiSnipeState) storage states, PoolId poolId)
        external
        view
        returns (uint24)
    {
        AntiSnipeState storage state = states[poolId];
        uint24 launchFee = state.launchFee;
        if (launchFee == 0) return 0;
        uint32 decayBlocks = state.decayBlocks;
        uint24 normalFee = state.normalFee;
        if (decayBlocks == 0) return normalFee;

        uint256 elapsed = block.number > state.startBlock ? block.number - state.startBlock : 0;
        if (elapsed >= decayBlocks) {
            return normalFee;
        }

        uint256 feeDiff = launchFee - normalFee;
        uint256 reduction = Math.mulDiv(feeDiff, elapsed, decayBlocks, Math.Rounding.Floor);
        return uint24(launchFee - reduction);
    }
}

/// @title AntiSnipeBlock
/// @notice Group 2 (Protection & Access) — Block #4: Launch fee decaying to normal fee over N blocks (`afterInitialize`, `beforeSwap`).
/// @dev Trust Level: Low (monotonically decays; supports graduation clock reset for launchpad tokens).
abstract contract AntiSnipeBlock is IHookRigBlock {
    mapping(PoolId poolId => AntiSnipeLogic.AntiSnipeState state) internal _antiSnipeStates;

    function _initAntiSnipe(PoolId poolId, AntiSnipeParams calldata params) internal {
        AntiSnipeLogic.init(_antiSnipeStates, poolId, params);
    }

    /// @notice Resets the startBlock to `block.number` when a bonding curve token graduates to Uniswap v4.
    function _resetAntiSnipeGraduationClock(PoolId poolId) internal {
        AntiSnipeLogic.AntiSnipeState storage state = _antiSnipeStates[poolId];
        if (state.launchFee > 0) {
            state.startBlock = uint32(block.number);
        }
    }

    function _computeAntiSnipeFee(PoolId poolId) internal view returns (uint24) {
        return AntiSnipeLogic.computeFee(_antiSnipeStates, poolId);
    }
}
