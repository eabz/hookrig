// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library LimitOrdersLogic {
    using SafeERC20 for IERC20;

    uint256 internal constant MAX_TICK_FILLS_PER_SWAP = 16;

    struct LimitOrderBucket {
        uint128 totalInputAmount;
        uint128 filledOutputAmount;
        bool filled;
    }

    struct UserLimitOrder {
        PoolId poolId;
        address maker;
        int24 targetTick;
        bool zeroForOne;
        uint128 inputAmount;
        bool claimedOrCancelled;
    }

    event LimitOrderPlaced(
        uint256 indexed orderId,
        PoolId indexed poolId,
        address indexed maker,
        int24 targetTick,
        bool zeroForOne,
        uint128 inputAmount
    );
    event LimitOrderCancelled(uint256 indexed orderId, PoolId indexed poolId, address indexed maker, uint128 amount);
    event LimitOrderTickCrossed(PoolId indexed poolId, int24 indexed crossedTick, bool zeroForOne, uint128 bucketSize);

    error NotOrderMaker(address caller);
    error OrderAlreadyHandled(uint256 orderId);
    error BucketAlreadyFilled(uint256 orderId);
    error InvalidOrderAmount();

    function placeOrder(
        mapping(uint256 => UserLimitOrder) storage orders,
        mapping(PoolId => mapping(int24 => mapping(bool => LimitOrderBucket))) storage buckets,
        uint256 orderId,
        PoolId poolId,
        PoolKey calldata key,
        int24 targetTick,
        bool zeroForOne,
        uint128 inputAmount
    ) external {
        if (inputAmount == 0) revert InvalidOrderAmount();
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        if (!inputCurrency.isAddressZero()) {
            IERC20(Currency.unwrap(inputCurrency)).safeTransferFrom(msg.sender, address(this), inputAmount);
        }

        orders[orderId] = UserLimitOrder({
            poolId: poolId,
            maker: msg.sender,
            targetTick: targetTick,
            zeroForOne: zeroForOne,
            inputAmount: inputAmount,
            claimedOrCancelled: false
        });

        buckets[poolId][targetTick][zeroForOne].totalInputAmount += inputAmount;

        emit LimitOrderPlaced(orderId, poolId, msg.sender, targetTick, zeroForOne, inputAmount);
    }

    function cancelOrder(
        mapping(uint256 => UserLimitOrder) storage orders,
        mapping(PoolId => mapping(int24 => mapping(bool => LimitOrderBucket))) storage buckets,
        PoolKey calldata key,
        uint256 orderId
    ) external {
        UserLimitOrder storage order = orders[orderId];
        if (order.maker != msg.sender) revert NotOrderMaker(msg.sender);
        if (order.claimedOrCancelled) revert OrderAlreadyHandled(orderId);

        LimitOrderBucket storage bucket = buckets[order.poolId][order.targetTick][order.zeroForOne];
        if (bucket.filled) revert BucketAlreadyFilled(orderId);

        order.claimedOrCancelled = true;
        bucket.totalInputAmount -= order.inputAmount;

        Currency inputCurrency = order.zeroForOne ? key.currency0 : key.currency1;
        inputCurrency.transfer(msg.sender, order.inputAmount);

        emit LimitOrderCancelled(orderId, order.poolId, msg.sender, order.inputAmount);
    }

    function processCrossedTicks(
        mapping(PoolId => int24) storage lastTicks,
        mapping(PoolId => mapping(int24 => mapping(bool => LimitOrderBucket))) storage buckets,
        PoolId poolId,
        int24 tickSpacing,
        int24 postSwapTick
    ) external {
        int24 prevTick = lastTicks[poolId];
        if (prevTick == postSwapTick || tickSpacing <= 0) return;

        bool movedUp = postSwapTick > prevTick;
        int24 step = tickSpacing;
        uint256 stepsChecked = 0;

        if (movedUp) {
            int24 aligned = (prevTick / step) * step;
            for (int24 t = aligned; t <= postSwapTick && stepsChecked < MAX_TICK_FILLS_PER_SWAP; t += step) {
                stepsChecked++;
                LimitOrderBucket storage b = buckets[poolId][t][false];
                if (b.totalInputAmount > 0 && !b.filled) {
                    b.filled = true;
                    emit LimitOrderTickCrossed(poolId, t, false, b.totalInputAmount);
                }
            }
        } else {
            int24 aligned = (prevTick / step) * step;
            for (int24 t = aligned; t >= postSwapTick && stepsChecked < MAX_TICK_FILLS_PER_SWAP; t -= step) {
                stepsChecked++;
                LimitOrderBucket storage b = buckets[poolId][t][true];
                if (b.totalInputAmount > 0 && !b.filled) {
                    b.filled = true;
                    emit LimitOrderTickCrossed(poolId, t, true, b.totalInputAmount);
                }
            }
        }

        lastTicks[poolId] = postSwapTick;
    }
}

/// @title LimitOrdersBlock
/// @notice Group 5 (Trading) — Block #15: Tick-indexed on-chain limit orders (`afterInitialize`, `afterSwap`).
/// @dev Trust Level: Low (users can always cancel unfilled orders; bounded tick traversal per swap).
abstract contract LimitOrdersBlock is IHookRigBlock {
    using PoolIdLibrary for PoolKey;

    uint256 internal nextLimitOrderId = 1;
    mapping(PoolId poolId => int24 lastTick) internal _limitOrderLastTick;
    mapping(
        PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => LimitOrdersLogic.LimitOrderBucket bucket))
    ) internal _limitOrderBuckets;
    mapping(uint256 orderId => LimitOrdersLogic.UserLimitOrder order) internal _limitOrders;

    function _initLimitOrders(PoolId poolId, int24 initialTick) internal {
        _limitOrderLastTick[poolId] = initialTick;
    }

    function placeLimitOrder(PoolKey calldata key, int24 targetTick, bool zeroForOne, uint128 inputAmount)
        external
        returns (uint256 orderId)
    {
        orderId = nextLimitOrderId++;
        LimitOrdersLogic.placeOrder(
            _limitOrders, _limitOrderBuckets, orderId, key.toId(), key, targetTick, zeroForOne, inputAmount
        );
    }

    /// @notice Guarantee liveness: makers can always cancel unfilled orders and recover escrowed tokens.
    function cancelLimitOrder(PoolKey calldata key, uint256 orderId) external {
        LimitOrdersLogic.cancelOrder(_limitOrders, _limitOrderBuckets, key, orderId);
    }

    function _processCrossedLimitOrderTicks(PoolId poolId, int24 tickSpacing, int24 postSwapTick) internal {
        LimitOrdersLogic.processCrossedTicks(_limitOrderLastTick, _limitOrderBuckets, poolId, tickSpacing, postSwapTick);
    }
}
