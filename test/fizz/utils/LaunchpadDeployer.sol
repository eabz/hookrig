// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHookRigOrchestrator} from "../../../src/interfaces/IHookRigOrchestrator.sol";
import {LaunchpadFactory} from "../../../src/launchpad/LaunchpadFactory.sol";
import {VirtualXYKLaunch} from "../../../src/launchpad/curves/VirtualXYKLaunch.sol";
import {SteppedTrancheLaunch} from "../../../src/launchpad/curves/SteppedTrancheLaunch.sol";
import {NativeTickLaunch} from "../../../src/launchpad/curves/NativeTickLaunch.sol";

/// @title LaunchpadDeployer
/// @notice Deploys the three curve implementations and the `LaunchpadFactory` from a fresh contract so the factory
///         address can be predicted from a known nonce (curve implementations store `factory` as an immutable).
/// @dev Fuzzer-agnostic replacement for `vm.computeCreateAddress` / `vm.getNonce`, which hevm does not support.
contract LaunchpadDeployer {
    LaunchpadFactory public immutable factory;
    VirtualXYKLaunch public immutable virtualXYKImpl;
    SteppedTrancheLaunch public immutable steppedTrancheImpl;
    NativeTickLaunch public immutable nativeTickImpl;

    constructor(IPoolManager poolManager, IHookRigOrchestrator orchestrator) {
        // A fresh contract starts at nonce 1: impls take nonces 1..3, the factory takes nonce 4
        address predictedFactory = _createAddress(address(this), 4);

        VirtualXYKLaunch xyk = new VirtualXYKLaunch(poolManager, orchestrator, predictedFactory);
        SteppedTrancheLaunch tranche = new SteppedTrancheLaunch(poolManager, orchestrator, predictedFactory);
        NativeTickLaunch native = new NativeTickLaunch(poolManager, orchestrator, predictedFactory);
        LaunchpadFactory deployed =
            new LaunchpadFactory(poolManager, orchestrator, address(xyk), address(tranche), address(native));
        require(address(deployed) == predictedFactory, "LaunchpadDeployer: factory prediction mismatch");

        virtualXYKImpl = xyk;
        steppedTrancheImpl = tranche;
        nativeTickImpl = native;
        factory = deployed;
    }

    /// @notice RLP-encoded CREATE address for nonces in [1, 0x7f].
    function _createAddress(address deployer, uint8 nonce) private pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(nonce))))));
    }
}
