// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../Base.sol";
import {HookRigOrchestratorHandler} from "./HookRigOrchestratorHandler.sol";
import {HookRigTokenHandler} from "./HookRigTokenHandler.sol";
import {LaunchpadFactoryHandler} from "./LaunchpadFactoryHandler.sol";
import {SteppedTrancheLaunchHandler} from "./SteppedTrancheLaunchHandler.sol";
import {VirtualXYKLaunchHandler} from "./VirtualXYKLaunchHandler.sol";
import {PoolManagerHandler} from "./PoolManagerHandler.sol";

/// @notice Inherits from all the handlers to expose all entry points in a single contract.
///         Manages environment changes (e.g. current actor, current token, mocks setup, etc.).
abstract contract Handlers is
    HookRigOrchestratorHandler,
    HookRigTokenHandler,
    LaunchpadFactoryHandler,
    SteppedTrancheLaunchHandler,
    VirtualXYKLaunchHandler,
    PoolManagerHandler
{
    function setCurrentActor(uint256 entropy) public tracked {
        actor = actors[entropy % actors.length];
    }

    /// @inheritdoc LaunchpadFactoryHandler
    function _sellToCurveAs(address seller, address curve, uint256 amount) internal override {
        uint8 kind = ghosts.curveKind[curve];
        if (kind == CURVE_XYK) {
            _xykSellChecked(VirtualXYKLaunch(payable(curve)), seller, amount, 0, seller, false);
        } else if (kind == CURVE_TRANCHE) {
            _trancheSellChecked(SteppedTrancheLaunch(payable(curve)), seller, amount, 0, seller, false);
        }
    }
}
