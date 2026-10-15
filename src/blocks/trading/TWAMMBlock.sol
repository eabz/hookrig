// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library TWAMMLogic {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint64 internal constant MAX_TWAMM_DURATION = 365 days;
    uint256 internal constant MAX_ACTIVE_TWAMM_ORDERS = 256;

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
        uint128 totalAmount;
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
    event TWAMMOrderCancelled(uint256 indexed orderId, PoolId indexed poolId, address indexed owner, uint256 refund);
    event TWAMMVirtualOrdersExecuted(
        PoolId indexed poolId, uint256 elapsedSeconds, uint256 virtualAmount0, uint256 virtualAmount1
    );

    error InvalidTWAMMInterval();
    error NotTWAMMOrderOwner(address caller);
    error TWAMMOrderNotActive(uint256 orderId);
    error TWAMMPoolKeyMismatch();
    error MaxActiveTWAMMOrdersReached(PoolId poolId);
    error TWAMMOrdersDisabled();

    function submitOrder(
        mapping(PoolId => TWAMMState) storage states,
        mapping(uint256 => TWAMMOrder) storage orders,
        mapping(PoolId => uint256[]) storage activeOrderIds,
        uint256 orderId,
        PoolId poolId,
        PoolKey calldata key,
        bool zeroForOne,
        uint128 totalAmount,
        uint64 durationSeconds
    ) external {
        if (durationSeconds == 0 || durationSeconds > MAX_TWAMM_DURATION || totalAmount < durationSeconds) {
            revert InvalidTWAMMInterval();
        }
        uint128 rate = uint128(Math.mulDiv(totalAmount, 1, durationSeconds, Math.Rounding.Floor));
        executePending(states, orders, activeOrderIds, poolId);
        uint256[] storage ids = activeOrderIds[poolId];
        if (ids.length >= MAX_ACTIVE_TWAMM_ORDERS) {
            revert MaxActiveTWAMMOrdersReached(poolId);
        }

        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        if (inputCurrency.isAddressZero()) {
            if (msg.value != totalAmount) revert InvalidTWAMMInterval();
        } else {
            if (msg.value != 0) revert InvalidTWAMMInterval();
            IERC20 token = IERC20(Currency.unwrap(inputCurrency));
            uint256 balBefore = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), totalAmount);
            if (token.balanceOf(address(this)) - balBefore != totalAmount) revert InvalidTWAMMInterval();
        }

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
            totalAmount: totalAmount,
            sellRatePerSecond: rate,
            startTimestamp: uint64(block.timestamp),
            expirationTimestamp: expiry,
            cancelled: false
        });
        ids.push(orderId);

        emit TWAMMOrderSubmitted(orderId, poolId, msg.sender, zeroForOne, rate, expiry);
    }

    function cancelOrder(
        mapping(PoolId => TWAMMState) storage states,
        mapping(uint256 => TWAMMOrder) storage orders,
        mapping(PoolId => uint256[]) storage activeOrderIds,
        PoolKey calldata key,
        uint256 orderId
    ) external returns (uint256 refundAmount) {
        TWAMMOrder storage order = orders[orderId];
        if (order.owner != msg.sender) revert NotTWAMMOrderOwner(msg.sender);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(order.poolId)) revert TWAMMPoolKeyMismatch();

        executePending(states, orders, activeOrderIds, order.poolId);
        if (order.cancelled) {
            revert TWAMMOrderNotActive(orderId);
        }

        order.cancelled = true;
        if (block.timestamp < order.expirationTimestamp) {
            TWAMMState storage state = states[order.poolId];
            if (order.zeroForOne) {
                state.sellRate0For1 -= order.sellRatePerSecond;
            } else {
                state.sellRate1For0 -= order.sellRatePerSecond;
            }

            uint256[] storage ids = activeOrderIds[order.poolId];
            for (uint256 i = 0; i < ids.length; i++) {
                if (ids[i] == orderId) {
                    ids[i] = ids[ids.length - 1];
                    ids.pop();
                    break;
                }
            }
        }

        refundAmount = order.totalAmount;
        if (refundAmount > 0) {
            Currency inputCurrency = order.zeroForOne ? key.currency0 : key.currency1;
            inputCurrency.transfer(msg.sender, refundAmount);
        }

        emit TWAMMOrderCancelled(orderId, order.poolId, msg.sender, refundAmount);
    }

    function executePending(
        mapping(PoolId => TWAMMState) storage states,
        mapping(uint256 => TWAMMOrder) storage orders,
        mapping(PoolId => uint256[]) storage activeOrderIds,
        PoolId poolId
    ) public {
        TWAMMState storage state = states[poolId];
        uint64 lastTs = state.lastVirtualOrderTimestamp;
        if (lastTs == 0) {
            state.lastVirtualOrderTimestamp = uint64(block.timestamp);
            return;
        }
        if (block.timestamp <= lastTs) return;

        uint64 nowTs = uint64(block.timestamp);
        uint256 elapsed = nowTs - lastTs;
        state.lastVirtualOrderTimestamp = nowTs;

        uint256[] storage ids = activeOrderIds[poolId];
        uint256 v0 = 0;
        uint256 v1 = 0;
        uint256 i = 0;
        while (i < ids.length) {
            TWAMMOrder storage order = orders[ids[i]];
            uint64 endTs = order.expirationTimestamp < nowTs ? order.expirationTimestamp : nowTs;
            if (endTs > lastTs) {
                uint256 activeSeconds = uint256(endTs - lastTs);
                uint256 vol = uint256(order.sellRatePerSecond) * activeSeconds;
                if (order.zeroForOne) {
                    v0 += vol;
                } else {
                    v1 += vol;
                }
            }

            if (order.expirationTimestamp <= nowTs) {
                if (order.zeroForOne) {
                    state.sellRate0For1 -= order.sellRatePerSecond;
                } else {
                    state.sellRate1For0 -= order.sellRatePerSecond;
                }
                ids[i] = ids[ids.length - 1];
                ids.pop();
            } else {
                i++;
            }
        }

        if (v0 > 0 || v1 > 0) {
            state.accruedVirtualVolume0 += v0;
            state.accruedVirtualVolume1 += v1;
            emit TWAMMVirtualOrdersExecuted(poolId, elapsed, v0, v1);
        }
    }

    function previewState(
        mapping(PoolId => TWAMMState) storage states,
        mapping(uint256 => TWAMMOrder) storage orders,
        mapping(PoolId => uint256[]) storage activeOrderIds,
        PoolId poolId
    ) external view returns (TWAMMState memory projected) {
        projected = states[poolId];
        uint64 lastTs = projected.lastVirtualOrderTimestamp;
        if (lastTs == 0 || block.timestamp <= lastTs) {
            return projected;
        }

        uint64 nowTs = uint64(block.timestamp);
        projected.lastVirtualOrderTimestamp = nowTs;
        uint256[] storage ids = activeOrderIds[poolId];
        for (uint256 i = 0; i < ids.length; i++) {
            TWAMMOrder storage order = orders[ids[i]];
            uint64 endTs = order.expirationTimestamp < nowTs ? order.expirationTimestamp : nowTs;
            uint256 activeSeconds = uint256(endTs - lastTs);
            uint256 vol = uint256(order.sellRatePerSecond) * activeSeconds;
            if (order.zeroForOne) {
                projected.accruedVirtualVolume0 += vol;
                if (order.expirationTimestamp <= nowTs) {
                    projected.sellRate0For1 -= order.sellRatePerSecond;
                }
            } else {
                projected.accruedVirtualVolume1 += vol;
                if (order.expirationTimestamp <= nowTs) {
                    projected.sellRate1For0 -= order.sellRatePerSecond;
                }
            }
        }
    }
}

/// @title TWAMMBlock
/// @notice Group 5 (Trading) — Block #16: Time-Weighted Average Market Maker streaming virtual orders
///         (`beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`).
/// @dev Trust Level: Low (bounded virtual order streaming between checkpoints with automatic expiration retirement).
abstract contract TWAMMBlock is IHookRigBlock {
    using PoolIdLibrary for PoolKey;

    uint256 internal nextTWAMMOrderId = 1;
    mapping(PoolId poolId => TWAMMLogic.TWAMMState state) internal _twammStates;
    mapping(uint256 orderId => TWAMMLogic.TWAMMOrder order) internal _twammOrders;
    mapping(PoolId poolId => uint256[] activeOrderIds) internal _poolTWAMMOrderIds;

    function _validateTWAMMBeforeInitialize(int24 tickSpacing) internal pure {
        if (tickSpacing <= 0) revert TWAMMLogic.InvalidTWAMMInterval();
    }

    function _initTWAMM(PoolId poolId) internal {
        _twammStates[poolId].lastVirtualOrderTimestamp = uint64(block.timestamp);
    }

    /// @notice Disabled: TWAMM only tracks virtual volume and never swaps deposits, so an order could never pay
    ///         out. Existing orders stay cancellable for a full refund through `cancelTWAMMOrder`.
    function submitTWAMMOrder(PoolKey calldata, bool, uint128, uint64) external payable returns (uint256) {
        revert TWAMMLogic.TWAMMOrdersDisabled();
    }

    function cancelTWAMMOrder(PoolKey calldata key, uint256 orderId) external returns (uint256 refundAmount) {
        return TWAMMLogic.cancelOrder(_twammStates, _twammOrders, _poolTWAMMOrderIds, key, orderId);
    }

    /// @notice Advances TWAMM virtual order streaming up to `block.timestamp`.
    function _executePendingTWAMMOrders(PoolId poolId) internal {
        TWAMMLogic.executePending(_twammStates, _twammOrders, _poolTWAMMOrderIds, poolId);
    }

    function _previewTWAMMState(PoolId poolId) internal view returns (TWAMMLogic.TWAMMState memory) {
        return TWAMMLogic.previewState(_twammStates, _twammOrders, _poolTWAMMOrderIds, poolId);
    }
}
