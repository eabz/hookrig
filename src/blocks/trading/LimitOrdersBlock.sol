// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";
import {IHookRigOrchestrator} from "../../interfaces/IHookRigOrchestrator.sol";
import {TransientContext} from "../../libraries/TransientContext.sol";

contract LimitOrderSwapExecutor is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable poolManager;

    struct FillCallbackData {
        PoolKey key;
        bool zeroForOne;
        uint128 inputAmount;
        address recipient;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    receive() external payable {}

    function executeFillSwap(PoolKey calldata key, bool zeroForOne, uint128 inputAmount, address recipient)
        external
        payable
        returns (uint256 outputAmount)
    {
        bytes memory res = poolManager.unlock(
            abi.encode(
                FillCallbackData({key: key, zeroForOne: zeroForOne, inputAmount: inputAmount, recipient: recipient})
            )
        );
        outputAmount = abi.decode(res, (uint256));
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");
        FillCallbackData memory cb = abi.decode(rawData, (FillCallbackData));

        BalanceDelta delta = poolManager.swap(
            cb.key,
            SwapParams({
                zeroForOne: cb.zeroForOne,
                amountSpecified: -int256(uint256(cb.inputAmount)),
                sqrtPriceLimitX96: cb.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        if (delta.amount0() < 0) {
            cb.key.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
        } else if (delta.amount0() > 0) {
            cb.key.currency0.take(poolManager, cb.recipient, uint256(uint128(delta.amount0())), false);
        }

        if (delta.amount1() < 0) {
            cb.key.currency1.settle(poolManager, address(this), uint256(uint128(-delta.amount1())), false);
        } else if (delta.amount1() > 0) {
            cb.key.currency1.take(poolManager, cb.recipient, uint256(uint128(delta.amount1())), false);
        }

        int128 outDelta = cb.zeroForOne ? delta.amount1() : delta.amount0();
        uint256 outputAmount = outDelta > 0 ? uint256(uint128(outDelta)) : 0;

        Currency inputCurrency = cb.zeroForOne ? cb.key.currency0 : cb.key.currency1;
        uint256 leftover = inputCurrency.isAddressZero()
            ? address(this).balance
            : IERC20(Currency.unwrap(inputCurrency)).balanceOf(address(this));
        if (leftover > 0) {
            inputCurrency.transfer(cb.recipient, leftover);
        }

        return abi.encode(outputAmount);
    }
}

library LimitOrdersLogic {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint256 internal constant MAX_TICK_FILLS_PER_SWAP = 512;

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
    event LimitOrderClaimed(uint256 indexed orderId, PoolId indexed poolId, address indexed maker, uint128 amount);
    event LimitOrderTickCrossed(PoolId indexed poolId, int24 indexed crossedTick, bool zeroForOne, uint128 bucketSize);

    error NotOrderMaker(address caller);
    error OrderAlreadyHandled(uint256 orderId);
    error BucketAlreadyFilled(uint256 orderId);
    error BucketNotYetFilled(uint256 orderId);
    error InvalidOrderAmount();
    error InvalidTargetTick(int24 targetTick, int24 tickSpacing);
    error OrderPoolKeyMismatch();

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
        if (
            key.tickSpacing <= 0 || targetTick < TickMath.MIN_TICK || targetTick > TickMath.MAX_TICK
                || targetTick % key.tickSpacing != 0
        ) {
            revert InvalidTargetTick(targetTick, key.tickSpacing);
        }

        LimitOrderBucket storage bucket = buckets[poolId][targetTick][zeroForOne];
        if (bucket.filled) {
            if (bucket.totalInputAmount == 0) {
                bucket.filled = false;
            } else {
                revert BucketAlreadyFilled(orderId);
            }
        }

        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        if (inputCurrency.isAddressZero()) {
            if (msg.value != inputAmount) revert InvalidOrderAmount();
        } else {
            if (msg.value != 0) revert InvalidOrderAmount();
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

        bucket.totalInputAmount += inputAmount;

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
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(order.poolId)) revert OrderPoolKeyMismatch();

        LimitOrderBucket storage bucket = buckets[order.poolId][order.targetTick][order.zeroForOne];
        if (bucket.filled) revert BucketAlreadyFilled(orderId);

        order.claimedOrCancelled = true;
        bucket.totalInputAmount -= order.inputAmount;

        Currency inputCurrency = order.zeroForOne ? key.currency0 : key.currency1;
        inputCurrency.transfer(msg.sender, order.inputAmount);

        emit LimitOrderCancelled(orderId, order.poolId, msg.sender, order.inputAmount);
    }

    function claimOrder(
        mapping(uint256 => UserLimitOrder) storage orders,
        mapping(PoolId => mapping(int24 => mapping(bool => LimitOrderBucket))) storage buckets,
        mapping(PoolId => int24) storage lastTicks,
        PoolKey calldata key,
        uint256 orderId,
        bool swapOnClaim,
        LimitOrderSwapExecutor executor
    ) external {
        UserLimitOrder storage order = orders[orderId];
        if (order.maker != msg.sender) revert NotOrderMaker(msg.sender);
        if (order.claimedOrCancelled) revert OrderAlreadyHandled(orderId);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(order.poolId)) revert OrderPoolKeyMismatch();

        LimitOrderBucket storage bucket = buckets[order.poolId][order.targetTick][order.zeroForOne];
        if (!bucket.filled) revert BucketNotYetFilled(orderId);

        order.claimedOrCancelled = true;
        bucket.totalInputAmount -= order.inputAmount;
        if (bucket.totalInputAmount == 0) {
            bucket.filled = false;
        }

        Currency inputCurrency = order.zeroForOne ? key.currency0 : key.currency1;
        uint128 paidOut = order.inputAmount;

        if (swapOnClaim && address(executor) != address(0)) {
            PoolId poolId = order.poolId;
            TransientContext.setInternalHookExecution(poolId, true);
            uint256 outAmount;
            if (inputCurrency.isAddressZero()) {
                outAmount =
                    executor.executeFillSwap{value: order.inputAmount}(key, order.zeroForOne, order.inputAmount, msg.sender);
            } else {
                IERC20(Currency.unwrap(inputCurrency)).safeTransfer(address(executor), order.inputAmount);
                outAmount = executor.executeFillSwap(key, order.zeroForOne, order.inputAmount, msg.sender);
            }
            TransientContext.setInternalHookExecution(poolId, false);
            if (outAmount == 0) revert BucketNotYetFilled(orderId);
            paidOut = outAmount > type(uint128).max ? type(uint128).max : uint128(outAmount);

            IPoolManager pm = executor.poolManager();
            (, int24 postTick,,) = StateLibrary.getSlot0(pm, poolId);
            processCrossedTicks(lastTicks, buckets, poolId, key.tickSpacing, postTick);
        } else {
            inputCurrency.transfer(msg.sender, order.inputAmount);
        }

        emit LimitOrderClaimed(orderId, order.poolId, msg.sender, paidOut);
    }

    function processCrossedTicks(
        mapping(PoolId => int24) storage lastTicks,
        mapping(PoolId => mapping(int24 => mapping(bool => LimitOrderBucket))) storage buckets,
        PoolId poolId,
        int24 tickSpacing,
        int24 postSwapTick
    ) public {
        int24 prevTick = lastTicks[poolId];
        if (prevTick == postSwapTick || tickSpacing <= 0) return;

        bool movedUp = postSwapTick > prevTick;
        int24 step = tickSpacing;
        uint256 stepsChecked = 0;
        int24 lastReached = postSwapTick;

        if (movedUp) {
            int24 rem = prevTick % step;
            int24 aligned = rem == 0 ? prevTick : (rem > 0 ? prevTick - rem : prevTick - (rem + step));
            int24 t = aligned;
            for (; t <= postSwapTick && stepsChecked < MAX_TICK_FILLS_PER_SWAP; t += step) {
                stepsChecked++;
                lastReached = t;
                LimitOrderBucket storage b = buckets[poolId][t][false];
                if (b.totalInputAmount > 0 && !b.filled) {
                    b.filled = true;
                    emit LimitOrderTickCrossed(poolId, t, false, b.totalInputAmount);
                }
            }
            if (t <= postSwapTick) {
                lastTicks[poolId] = lastReached;
                return;
            }
        } else {
            int24 rem = prevTick % step;
            int24 aligned = rem == 0 ? prevTick : (rem > 0 ? prevTick + (step - rem) : prevTick - rem);
            int24 t = aligned;
            for (; t >= postSwapTick && stepsChecked < MAX_TICK_FILLS_PER_SWAP; t -= step) {
                stepsChecked++;
                lastReached = t;
                LimitOrderBucket storage b = buckets[poolId][t][true];
                if (b.totalInputAmount > 0 && !b.filled) {
                    b.filled = true;
                    emit LimitOrderTickCrossed(poolId, t, true, b.totalInputAmount);
                }
            }
            if (t >= postSwapTick) {
                lastTicks[poolId] = lastReached;
                return;
            }
        }

        lastTicks[poolId] = postSwapTick;
    }
}

interface IHasPoolManager {
    function poolManager() external view returns (IPoolManager);
}

/// @title LimitOrdersBlock
/// @notice Group 5 (Trading) — Block #15: Tick-indexed on-chain limit orders (`afterInitialize`, `afterSwap`).
/// @dev Trust Level: Low (users can always cancel unfilled orders or claim filled orders; bounded tick traversal per swap).
abstract contract LimitOrdersBlock is IHookRigBlock {
    using PoolIdLibrary for PoolKey;

    uint256 internal nextLimitOrderId = 1;
    LimitOrderSwapExecutor internal _limitOrderExecutor;
    mapping(PoolId poolId => int24 lastTick) internal _limitOrderLastTick;
    mapping(
        PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => LimitOrdersLogic.LimitOrderBucket bucket))
    ) internal _limitOrderBuckets;
    mapping(uint256 orderId => LimitOrdersLogic.UserLimitOrder order) internal _limitOrders;

    function _initLimitOrders(PoolId poolId, int24 initialTick) internal {
        _limitOrderLastTick[poolId] = initialTick;
    }

    function _swapFilledOrderOnClaim() internal view virtual returns (bool) {
        return false;
    }

    function placeLimitOrder(PoolKey calldata key, int24 targetTick, bool zeroForOne, uint128 inputAmount)
        external
        payable
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

    /// @notice Guarantee liveness: makers can always claim/withdraw orders once their target tick has been crossed.
    function claimLimitOrder(PoolKey calldata key, uint256 orderId) external {
        bool swapOnClaim = _swapFilledOrderOnClaim();
        LimitOrderSwapExecutor executor = _limitOrderExecutor;
        if (swapOnClaim && address(executor) == address(0)) {
            executor = new LimitOrderSwapExecutor(IHasPoolManager(address(this)).poolManager());
            _limitOrderExecutor = executor;
        }
        LimitOrdersLogic.claimOrder(
            _limitOrders, _limitOrderBuckets, _limitOrderLastTick, key, orderId, swapOnClaim, executor
        );
    }

    function _processCrossedLimitOrderTicks(PoolId poolId, int24 tickSpacing, int24 postSwapTick) internal {
        LimitOrdersLogic.processCrossedTicks(_limitOrderLastTick, _limitOrderBuckets, poolId, tickSpacing, postSwapTick);
    }
}
