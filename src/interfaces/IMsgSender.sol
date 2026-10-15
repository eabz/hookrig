// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IMsgSender
/// @notice Interface implemented by trusted Uniswap v4 routers (such as UniversalRouter / PositionManager)
///         to expose the true end-user initiator address during a PoolManager callback.
interface IMsgSender {
    function msgSender() external view returns (address);
}
