// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title HookRigToken
/// @notice Fixed-supply, non-rebasing ERC-20 launchpad token with `ERC20Burnable` (for `AutoBurnBlock`)
///         and `ERC20Permit` (EIP-2612 gasless approvals).
contract HookRigToken is ERC20, ERC20Burnable, ERC20Permit {
    address public immutable factory;
    address public immutable creator;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address initialRecipient_,
        address creator_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        factory = msg.sender;
        creator = creator_;
        _mint(initialRecipient_, totalSupply_);
    }
}
