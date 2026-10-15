// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles transfers of launched HookRigTokens (moves balances read by WalletCap / VestingSellCap / curves)
abstract contract HookRigTokenHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    function hookRigToken_transfer_clamped(uint256 tokenSeed, address to, uint256 value) public tracked {
        address token = launchTokens[tokenSeed % launchTokens.length];
        uint256 balance = MockBurnableERC20(token).balanceOf(actor);
        if (balance == 0) return;
        value = clampBetween(value, 1, balance);
        hookRigToken_transfer(tokenSeed, toActorNotCurrent(to), value);
    }

    /// @notice Donation stress: sends project tokens straight to the launch curve (outside `sell`).
    function hookRigToken_donateToCurve(uint256 tokenSeed, uint256 value) public tracked {
        uint256 i = tokenSeed % launchTokens.length;
        address curve = _curveForToken(launchTokens[i]);
        if (_launchState(curve) != LS_ACTIVE) return;
        uint256 balance = MockBurnableERC20(launchTokens[i]).balanceOf(actor);
        if (balance == 0) return;
        value = clampBetween(value, 1, balance);
        hookRigToken_transfer(i, curve, value);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function hookRigToken_transfer(uint256 tokenSeed, address to, uint256 value) public tracked {
        address token = launchTokens[tokenSeed % launchTokens.length];
        _setCallContext(CallKind.TOKEN_TRANSFER, actor, 0, to);
        vm.prank(actor);
        MockBurnableERC20(token).transfer(to, value);

        // GL-23: project tokens that reach the curve outside `sell`
        address curve = _curveForToken(token);
        if (to == curve && to != actor) ghosts.tokensDonatedToCurve[curve] += value;
    }

    function _curveForToken(address token) internal view returns (address) {
        return launchpadFactory.tokenToCurve(token);
    }
}
