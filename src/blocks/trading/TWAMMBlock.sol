// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library TWAMMLogic {
    struct TWAMMState {
        uint64 lastVirtualOrderTimestamp;
        uint128 sellRate0For1; // Tokens per second streaming token0 -> token1
        uint128 sellRate1For0; // Tokens per second streaming token1 -> token0
        uint256 accruedVirtualVolume0;
        uint256 accruedVirtualVolume1;
    }

    struct TWAMMOrder {
        PoolId poolId;
        address owner;
        bool zeroForOne;
        uint128 sellRatePerSecond;
        uint64 startTimestamp;
        uint64 expirationTimestamp;
        bool cancelled;
    }

    event TWAMMOrderSubmitted(
        uint256 indexed orderId,
        PoolId indexed poolId,
        address indexed owner,
        bool zeroForOne,
        uint128 sellRatePerSecond,
        uint64 expirationTimestamp
    );
    event TWAMMVirtualOrdersExecuted(
        PoolId indexed poolId, uint256 elapsedSeconds, uint256 virtualAmount0, uint256 virtualAmount1
    );

    error InvalidTWAMMInterval();

    function submitOrder(
        mapping(PoolId => TWAMMState) storage states,
        mapping(uint256 => TWAMMOrder) storage orders,
        uint256 orderId,
        PoolId poolId,
        bool zeroForOne,
        uint128 totalAmount,
        uint64 durationSeconds
    ) external {
        if (durationSeconds == 0 || totalAmount < durationSeconds) revert InvalidTWAMMInterval();
        executePending(states, poolId);

        uint128 rate = uint128(Math.mulDiv(totalAmount, 1, durationSeconds, Math.Rounding.Floor));
        uint64 expiry = uint64(block.timestamp) + durationSeconds;

        TWAMMState storage state = states[poolId];
        if (zeroForOne) {
            state.sellRate0For1 += rate;
        } else {
            state.sellRate1For0 += rate;
        }

        orders[orderId] = TWAMMOrder({
            poolId: poolId,
            owner: msg.sender,
            zeroForOne: zeroForOne,
            sellRatePerSecond: rate,
            startTimestamp: uint64(block.timestamp),
            expirationTimestamp: expiry,
            cancelled: false
        });

        emit TWAMMOrderSubmitted(orderId, poolId, msg.sender, zeroForOne, rate, expiry);
    }

    function executePending(mapping(PoolId => TWAMMState) storage states, PoolId poolId) public {
        TWAMMState storage state = states[poolId];
        uint64 lastTs = state.lastVirtualOrderTimestamp;
        if (lastTs == 0) {
            state.lastVirtualOrderTimestamp = uint64(block.timestamp);
            return;
        }
        if (block.timestamp <= lastTs) return;

        uint256 elapsed = block.timestamp - lastTs;
        state.lastVirtualOrderTimestamp = uint64(block.timestamp);

        uint256 v0 = uint256(state.sellRate0For1) * elapsed;
        uint256 v1 = uint256(state.sellRate1For0) * elapsed;

        if (v0 > 0 || v1 > 0) {
            state.accruedVirtualVolume0 += v0;
            state.accruedVirtualVolume1 += v1;
            emit TWAMMVirtualOrdersExecuted(poolId, elapsed, v0, v1);
        }
    }
}

/// @title TWAMMBlock
/// @notice Group 5 (Trading) — Block #16: Time-Weighted Average Market Maker streaming virtual orders
///         (`beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`).
/// @dev Trust Level: Low (O(1) closed-form virtual order streaming between checkpoints).
abstract contract TWAMMBlock is IHookRigBlock {
    using PoolIdLibrary for PoolKey;

    uint256 internal nextTWAMMOrderId = 1;
    mapping(PoolId poolId => TWAMMLogic.TWAMMState state) internal _twammStates;
    mapping(uint256 orderId => TWAMMLogic.TWAMMOrder order) internal _twammOrders;

    function _validateTWAMMBeforeInitialize(int24 tickSpacing) internal pure {
        if (tickSpacing <= 0) revert TWAMMLogic.InvalidTWAMMInterval();
    }

    function _initTWAMM(PoolId poolId) internal {
        _twammStates[poolId].lastVirtualOrderTimestamp = uint64(block.timestamp);
    }

    function submitTWAMMOrder(PoolKey calldata key, bool zeroForOne, uint128 totalAmount, uint64 durationSeconds)
        external
        returns (uint256 orderId)
    {
        orderId = nextTWAMMOrderId++;
        TWAMMLogic.submitOrder(
            _twammStates, _twammOrders, orderId, key.toId(), zeroForOne, totalAmount, durationSeconds
        );
    }

    /// @notice Advances TWAMM virtual order streaming up to `block.timestamp` in O(1).
    function _executePendingTWAMMOrders(PoolId poolId) internal {
        TWAMMLogic.executePending(_twammStates, poolId);
    }
}
