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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";
import {TransientContext} from "../../libraries/TransientContext.sol";
import {IHasPoolManager} from "./LimitOrdersBlock.sol";

/// @notice Executes out-of-unlock TWAMM virtual order swaps against `PoolManager` and returns the settled input and
///         output amounts to the hook.
contract TWAMMSwapExecutor is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable poolManager;
    address public immutable hook;

    error OnlyHookCaller(address caller);
    error ZeroVirtualSwapOutput();

    struct SwapCallbackData {
        PoolKey key;
        bool zeroForOne;
        uint256 inputAmount;
    }

    constructor(IPoolManager _poolManager, address _hook) {
        poolManager = _poolManager;
        hook = _hook;
    }

    receive() external payable {}

    function executeVirtualSwap(PoolKey calldata key, bool zeroForOne, uint256 inputAmount)
        external
        payable
        returns (uint256 actualIn, uint256 actualOut)
    {
        if (msg.sender != hook) revert OnlyHookCaller(msg.sender);
        try poolManager.unlock(
            abi.encode(SwapCallbackData({key: key, zeroForOne: zeroForOne, inputAmount: inputAmount}))
        ) returns (
            bytes memory res
        ) {
            (actualIn, actualOut) = abi.decode(res, (uint256, uint256));
        } catch {
            Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
            inputCurrency.transfer(hook, inputAmount);
            return (0, 0);
        }
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");
        SwapCallbackData memory cb = abi.decode(rawData, (SwapCallbackData));

        BalanceDelta delta = poolManager.swap(
            cb.key,
            SwapParams({
                zeroForOne: cb.zeroForOne,
                amountSpecified: -int256(cb.inputAmount),
                sqrtPriceLimitX96: cb.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 inDelta = cb.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = cb.zeroForOne ? delta.amount1() : delta.amount0();
        if (inDelta >= 0 || outDelta <= 0) revert ZeroVirtualSwapOutput();

        if (delta.amount0() < 0) {
            cb.key.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
        }
        if (delta.amount1() < 0) {
            cb.key.currency1.settle(poolManager, address(this), uint256(uint128(-delta.amount1())), false);
        }

        uint256 actualIn = uint256(uint128(-inDelta));
        Currency outputCurrency = cb.zeroForOne ? cb.key.currency1 : cb.key.currency0;
        uint256 nominalOut = uint256(uint128(outDelta));
        uint256 balBefore = outputCurrency.balanceOf(hook);
        outputCurrency.take(poolManager, hook, nominalOut, false);
        uint256 actualOut = outputCurrency.balanceOf(hook) - balBefore;
        if (actualOut == 0) revert ZeroVirtualSwapOutput();

        Currency inputCurrency = cb.zeroForOne ? cb.key.currency0 : cb.key.currency1;
        uint256 leftover = cb.inputAmount > actualIn ? cb.inputAmount - actualIn : 0;
        if (leftover > 0) {
            inputCurrency.transfer(hook, leftover);
        }

        return abi.encode(actualIn, actualOut);
    }

    function trySwapInUnlock(PoolKey calldata key, bool zeroForOne, uint256 inputAmount)
        external
        returns (uint256 actualIn, uint256 actualOut)
    {
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(inputAmount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 inDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inDelta >= 0 || outDelta <= 0) revert ZeroVirtualSwapOutput();

        if (delta.amount0() < 0) {
            key.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
        }
        if (delta.amount1() < 0) {
            key.currency1.settle(poolManager, address(this), uint256(uint128(-delta.amount1())), false);
        }

        actualIn = uint256(uint128(-inDelta));
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        uint256 nominalOut = uint256(uint128(outDelta));
        uint256 balBefore = outputCurrency.balanceOf(address(this));
        outputCurrency.take(poolManager, address(this), nominalOut, false);
        actualOut = outputCurrency.balanceOf(address(this)) - balBefore;
        if (actualOut == 0) revert ZeroVirtualSwapOutput();
    }
}

library TWAMMLogic {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;

    uint64 internal constant MAX_TWAMM_DURATION = 365 days;
    uint128 internal constant MIN_TWAMM_ORDER_AMOUNT = 1e15;
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
        bool rateRemoved;
        uint128 streamedAmount;
        uint128 swappedInputAmount;
        uint128 refundedInputAmount;
        uint256 claimableOutput;
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
    event TWAMMOrderClaimed(
        uint256 indexed orderId, PoolId indexed poolId, address indexed owner, uint256 amountOut, uint256 refundAmount
    );
    event TWAMMVirtualOrdersExecuted(
        PoolId indexed poolId, uint256 elapsedSeconds, uint256 virtualAmount0, uint256 virtualAmount1
    );

    error InvalidTWAMMInterval();
    error NotTWAMMOrderOwner(address caller);
    error TWAMMOrderNotActive(uint256 orderId);
    error TWAMMPoolKeyMismatch();
    error MaxActiveTWAMMOrdersReached(PoolId poolId);
    error TWAMMOrdersDisabled();

    function ensureExecutor(TWAMMSwapExecutor executor) external returns (TWAMMSwapExecutor) {
        if (address(executor) == address(0)) {
            executor = new TWAMMSwapExecutor(IHasPoolManager(address(this)).poolManager(), address(this));
        }
        return executor;
    }

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
        submitOrder(
            states,
            orders,
            activeOrderIds,
            orderId,
            poolId,
            key,
            zeroForOne,
            totalAmount,
            durationSeconds,
            TWAMMSwapExecutor(payable(address(0)))
        );
    }

    function submitOrder(
        mapping(PoolId => TWAMMState) storage states,
        mapping(uint256 => TWAMMOrder) storage orders,
        mapping(PoolId => uint256[]) storage activeOrderIds,
        uint256 orderId,
        PoolId poolId,
        PoolKey calldata key,
        bool zeroForOne,
        uint128 totalAmount,
        uint64 durationSeconds,
        TWAMMSwapExecutor executor
    ) public {
        if (
            states[poolId].lastVirtualOrderTimestamp == 0 || durationSeconds == 0
                || durationSeconds > MAX_TWAMM_DURATION || totalAmount < durationSeconds
                || totalAmount < MIN_TWAMM_ORDER_AMOUNT
        ) {
            revert InvalidTWAMMInterval();
        }
        uint128 rate = uint128(Math.mulDiv(totalAmount, 1, durationSeconds, Math.Rounding.Floor));
        executePendingWithSwap(states, orders, activeOrderIds, key, poolId, false, executor);
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
            cancelled: false,
            rateRemoved: false,
            streamedAmount: 0,
            swappedInputAmount: 0,
            refundedInputAmount: 0,
            claimableOutput: 0
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
        return cancelOrder(states, orders, activeOrderIds, key, orderId, TWAMMSwapExecutor(payable(address(0))));
    }

    function cancelOrder(
        mapping(PoolId => TWAMMState) storage states,
        mapping(uint256 => TWAMMOrder) storage orders,
        mapping(PoolId => uint256[]) storage activeOrderIds,
        PoolKey calldata key,
        uint256 orderId,
        TWAMMSwapExecutor executor
    ) public returns (uint256 refundAmount) {
        TWAMMOrder storage order = orders[orderId];
        if (order.owner != msg.sender) revert NotTWAMMOrderOwner(msg.sender);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(order.poolId)) revert TWAMMPoolKeyMismatch();

        executePendingWithSwap(states, orders, activeOrderIds, key, order.poolId, false, executor);
        if (order.cancelled) {
            revert TWAMMOrderNotActive(orderId);
        }

        order.cancelled = true;
        if (!order.rateRemoved) {
            order.rateRemoved = true;
            TWAMMState storage state = states[order.poolId];
            if (order.zeroForOne) {
                state.sellRate0For1 -= order.sellRatePerSecond;
            } else {
                state.sellRate1For0 -= order.sellRatePerSecond;
            }
        }

        uint256[] storage ids = activeOrderIds[order.poolId];
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == orderId) {
                ids[i] = ids[ids.length - 1];
                ids.pop();
                break;
            }
        }

        refundAmount =
            uint256(order.totalAmount) - uint256(order.swappedInputAmount) - uint256(order.refundedInputAmount);
        if (refundAmount > 0) {
            order.refundedInputAmount += uint128(refundAmount);
            Currency inputCurrency = order.zeroForOne ? key.currency0 : key.currency1;
            inputCurrency.transfer(msg.sender, refundAmount);
        }

        uint256 outAmount = order.claimableOutput;
        if (outAmount > 0) {
            order.claimableOutput = 0;
            Currency outputCurrency = order.zeroForOne ? key.currency1 : key.currency0;
            outputCurrency.transfer(msg.sender, outAmount);
        }

        emit TWAMMOrderCancelled(orderId, order.poolId, msg.sender, refundAmount);
    }

    function claimOrder(
        mapping(PoolId => TWAMMState) storage states,
        mapping(uint256 => TWAMMOrder) storage orders,
        mapping(PoolId => uint256[]) storage activeOrderIds,
        PoolKey calldata key,
        uint256 orderId,
        TWAMMSwapExecutor executor
    ) external returns (uint256 amountOut, uint256 refundAmount) {
        TWAMMOrder storage order = orders[orderId];
        if (order.owner != msg.sender) revert NotTWAMMOrderOwner(msg.sender);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(order.poolId)) revert TWAMMPoolKeyMismatch();

        executePendingWithSwap(states, orders, activeOrderIds, key, order.poolId, false, executor);

        amountOut = order.claimableOutput;
        if (amountOut > 0) {
            order.claimableOutput = 0;
            Currency outputCurrency = order.zeroForOne ? key.currency1 : key.currency0;
            outputCurrency.transfer(msg.sender, amountOut);
        }

        if (block.timestamp >= order.expirationTimestamp || order.cancelled) {
            refundAmount =
                uint256(order.totalAmount) - uint256(order.swappedInputAmount) - uint256(order.refundedInputAmount);
            if (refundAmount > 0) {
                order.refundedInputAmount += uint128(refundAmount);
                order.streamedAmount = order.swappedInputAmount;
                Currency inputCurrency = order.zeroForOne ? key.currency0 : key.currency1;
                inputCurrency.transfer(msg.sender, refundAmount);
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

        emit TWAMMOrderClaimed(orderId, order.poolId, msg.sender, amountOut, refundAmount);
    }

    function executePending(
        mapping(PoolId => TWAMMState) storage states,
        mapping(uint256 => TWAMMOrder) storage orders,
        mapping(PoolId => uint256[]) storage activeOrderIds,
        PoolId poolId
    ) public {
        if (TransientContext.isInternalHookExecution(poolId)) {
            return;
        }

        TWAMMState storage state = states[poolId];
        uint64 lastTs = state.lastVirtualOrderTimestamp;
        if (lastTs == 0 || block.timestamp <= lastTs) return;

        uint64 nowTs = uint64(block.timestamp);
        uint256 elapsed = nowTs - lastTs;
        state.lastVirtualOrderTimestamp = nowTs;

        uint256[] storage ids = activeOrderIds[poolId];
        uint256 v0 = 0;
        uint256 v1 = 0;
        uint256 i = 0;
        while (i < ids.length) {
            TWAMMOrder storage order = orders[ids[i]];
            if (!order.rateRemoved && !order.cancelled) {
                uint64 endTs = order.expirationTimestamp < nowTs ? order.expirationTimestamp : nowTs;
                if (endTs > lastTs) {
                    uint256 activeSeconds = uint256(endTs - lastTs);
                    uint256 vol = uint256(order.sellRatePerSecond) * activeSeconds;
                    uint256 remaining = uint256(order.totalAmount) - uint256(order.streamedAmount);
                    if (vol > remaining) {
                        vol = remaining;
                    }
                    order.streamedAmount += uint128(vol);
                    if (order.zeroForOne) {
                        v0 += vol;
                    } else {
                        v1 += vol;
                    }
                }

                if (order.expirationTimestamp <= nowTs) {
                    order.rateRemoved = true;
                    if (order.zeroForOne) {
                        state.sellRate0For1 -= order.sellRatePerSecond;
                    } else {
                        state.sellRate1For0 -= order.sellRatePerSecond;
                    }
                }
            }

            if (
                order.cancelled
                    || (order.expirationTimestamp <= nowTs && order.swappedInputAmount == order.streamedAmount)
            ) {
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

    function executePendingWithSwap(
        mapping(PoolId => TWAMMState) storage states,
        mapping(uint256 => TWAMMOrder) storage orders,
        mapping(PoolId => uint256[]) storage activeOrderIds,
        PoolKey calldata key,
        PoolId poolId,
        bool inUnlock,
        TWAMMSwapExecutor executor
    ) public {
        if (TransientContext.isInternalHookExecution(poolId)) return;

        executePending(states, orders, activeOrderIds, poolId);

        uint256[] storage ids = activeOrderIds[poolId];
        if (ids.length == 0) return;

        (uint256 totalUnswapped0, uint256 totalUnswapped1) = _sumUnswapped(orders, ids);
        if (totalUnswapped0 == 0 && totalUnswapped1 == 0) return;

        if (address(executor) == address(0)) {
            executor = new TWAMMSwapExecutor(IHasPoolManager(address(this)).poolManager(), address(this));
        }

        (uint256 settledIn0, uint256 settledOut0, uint256 settledIn1, uint256 settledOut1) =
            _executeAmmSwaps(key, totalUnswapped0, totalUnswapped1, inUnlock, executor);

        if (settledIn0 > 0) {
            _distributeDirection(orders, ids, true, totalUnswapped0, settledIn0, settledOut0);
        }
        if (settledIn1 > 0) {
            _distributeDirection(orders, ids, false, totalUnswapped1, settledIn1, settledOut1);
        }

        _pruneSettledOrders(orders, ids);
    }

    function _executeAmmSwaps(
        PoolKey calldata key,
        uint256 totalUnswapped0,
        uint256 totalUnswapped1,
        bool inUnlock,
        TWAMMSwapExecutor executor
    ) private returns (uint256 settledIn0, uint256 settledOut0, uint256 settledIn1, uint256 settledOut1) {
        (settledIn0, settledIn1) = _netOpposingFlows(
            IHasPoolManager(address(this)).poolManager(), key.toId(), totalUnswapped0, totalUnswapped1
        );
        settledOut0 = settledIn1;
        settledOut1 = settledIn0;

        if (settledIn0 < totalUnswapped0) {
            (uint256 in0, uint256 out0) = _swapVirtualInput(key, true, totalUnswapped0 - settledIn0, inUnlock, executor);
            settledIn0 += in0;
            settledOut0 += out0;
        }

        if (settledIn1 < totalUnswapped1) {
            bool swapped1;
            {
                (uint256 in1, uint256 out1) =
                    _swapVirtualInput(key, false, totalUnswapped1 - settledIn1, inUnlock, executor);
                settledIn1 += in1;
                settledOut1 += out1;
                swapped1 = in1 > 0;
            }

            if (swapped1 && settledIn0 < totalUnswapped0) {
                bool swapped0;
                {
                    (uint256 extraIn0, uint256 extraOut0) =
                        _swapVirtualInput(key, true, totalUnswapped0 - settledIn0, inUnlock, executor);
                    settledIn0 += extraIn0;
                    settledOut0 += extraOut0;
                    swapped0 = extraIn0 > 0;
                }

                if (swapped0 && settledIn1 < totalUnswapped1) {
                    (uint256 extraIn1, uint256 extraOut1) =
                        _swapVirtualInput(key, false, totalUnswapped1 - settledIn1, inUnlock, executor);
                    settledIn1 += extraIn1;
                    settledOut1 += extraOut1;
                }
            }
        }
    }

    function _netOpposingFlows(
        IPoolManager poolManager,
        PoolId poolId,
        uint256 totalUnswapped0,
        uint256 totalUnswapped1
    ) private view returns (uint256 netted0, uint256 netted1) {
        if (totalUnswapped0 == 0 || totalUnswapped1 == 0) return (0, 0);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtPriceX96 == 0) return (0, 0);

        uint256 equiv1 = Math.mulDiv(Math.mulDiv(totalUnswapped0, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
        if (equiv1 > 0 && equiv1 <= totalUnswapped1) {
            netted1 = equiv1;
            netted0 = Math.mulDiv(Math.mulDiv(netted1, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
            if (netted0 > totalUnswapped0) netted0 = totalUnswapped0;
        } else if (equiv1 > totalUnswapped1) {
            uint256 equiv0 = Math.mulDiv(Math.mulDiv(totalUnswapped1, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
            if (equiv0 > totalUnswapped0) equiv0 = totalUnswapped0;
            if (equiv0 > 0) {
                netted0 = equiv0;
                netted1 = Math.mulDiv(Math.mulDiv(netted0, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
                if (netted1 > totalUnswapped1) netted1 = totalUnswapped1;
            }
        }
        if (netted0 == 0 || netted1 == 0) {
            return (0, 0);
        }
    }

    function _sumUnswapped(mapping(uint256 => TWAMMOrder) storage orders, uint256[] storage ids)
        private
        view
        returns (uint256 total0, uint256 total1)
    {
        for (uint256 i = 0; i < ids.length; i++) {
            TWAMMOrder storage order = orders[ids[i]];
            if (!order.cancelled && order.streamedAmount > order.swappedInputAmount) {
                uint256 unswapped = uint256(order.streamedAmount - order.swappedInputAmount);
                if (order.zeroForOne) {
                    total0 += unswapped;
                } else {
                    total1 += unswapped;
                }
            }
        }
    }

    function _distributeDirection(
        mapping(uint256 => TWAMMOrder) storage orders,
        uint256[] storage ids,
        bool zeroForOne,
        uint256 totalUnswapped,
        uint256 actualIn,
        uint256 actualOut
    ) private {
        uint256 remUnswapped = totalUnswapped;
        uint256 remActualIn = actualIn >= totalUnswapped ? totalUnswapped : actualIn;
        for (uint256 j = 0; j < ids.length; j++) {
            TWAMMOrder storage order = orders[ids[j]];
            if (!order.cancelled && order.zeroForOne == zeroForOne && order.streamedAmount > order.swappedInputAmount) {
                uint256 unswapped = uint256(order.streamedAmount - order.swappedInputAmount);
                uint256 inShare = remUnswapped <= unswapped
                    ? remActualIn
                    : Math.mulDiv(remActualIn, unswapped, remUnswapped, Math.Rounding.Ceil);
                if (inShare > unswapped) inShare = unswapped;
                if (inShare > remActualIn) inShare = remActualIn;
                remActualIn -= inShare;
                remUnswapped -= unswapped;
                uint256 outShare = Math.mulDiv(actualOut, unswapped, totalUnswapped);
                order.swappedInputAmount += uint128(inShare);
                order.claimableOutput += outShare;
            }
        }
    }

    function _pruneSettledOrders(mapping(uint256 => TWAMMOrder) storage orders, uint256[] storage ids) private {
        uint64 nowTs = uint64(block.timestamp);
        uint256 j = 0;
        while (j < ids.length) {
            TWAMMOrder storage order = orders[ids[j]];
            if (
                order.cancelled
                    || (order.expirationTimestamp <= nowTs && order.swappedInputAmount == order.streamedAmount)
            ) {
                ids[j] = ids[ids.length - 1];
                ids.pop();
            } else {
                j++;
            }
        }
    }

    function _swapVirtualInput(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 inputAmount,
        bool inUnlock,
        TWAMMSwapExecutor executor
    ) private returns (uint256 actualIn, uint256 actualOut) {
        if (inputAmount == 0) return (0, 0);
        IPoolManager poolManager = IHasPoolManager(address(this)).poolManager();
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        if (
            sqrtPriceX96 == 0
                || (zeroForOne
                        ? sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE + 1
                        : sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE - 1)
        ) {
            return (0, 0);
        }
        if (inUnlock) {
            (bool ok, bytes memory ret) = address(executor)
                .delegatecall(abi.encodeCall(TWAMMSwapExecutor.trySwapInUnlock, (key, zeroForOne, inputAmount)));
            if (ok) {
                (actualIn, actualOut) = abi.decode(ret, (uint256, uint256));
            }
        } else {
            Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
            if (inputCurrency.isAddressZero()) {
                (actualIn, actualOut) = executor.executeVirtualSwap{value: inputAmount}(key, zeroForOne, inputAmount);
            } else {
                IERC20(Currency.unwrap(inputCurrency)).safeTransfer(address(executor), inputAmount);
                (actualIn, actualOut) = executor.executeVirtualSwap(key, zeroForOne, inputAmount);
            }
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
            if (order.rateRemoved || order.cancelled) continue;
            uint64 endTs = order.expirationTimestamp < nowTs ? order.expirationTimestamp : nowTs;
            uint256 vol = 0;
            if (endTs > lastTs) {
                uint256 activeSeconds = uint256(endTs - lastTs);
                vol = uint256(order.sellRatePerSecond) * activeSeconds;
                uint256 remaining = uint256(order.totalAmount) - uint256(order.streamedAmount);
                if (vol > remaining) {
                    vol = remaining;
                }
            }
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
/// @dev Trust Level: Low (bounded virtual order streaming between checkpoints with automatic expiration retirement
///      and real pool swap settlement).
abstract contract TWAMMBlock is IHookRigBlock {
    using PoolIdLibrary for PoolKey;

    uint256 internal nextTWAMMOrderId = 1;
    TWAMMSwapExecutor internal _twammExecutor;
    mapping(PoolId poolId => TWAMMLogic.TWAMMState state) internal _twammStates;
    mapping(uint256 orderId => TWAMMLogic.TWAMMOrder order) internal _twammOrders;
    mapping(PoolId poolId => uint256[] activeOrderIds) internal _poolTWAMMOrderIds;

    function _validateTWAMMBeforeInitialize(int24 tickSpacing) internal pure {
        if (tickSpacing <= 0) revert TWAMMLogic.InvalidTWAMMInterval();
    }

    function _initTWAMM(PoolId poolId) internal {
        _twammStates[poolId].lastVirtualOrderTimestamp = uint64(block.timestamp);
    }

    function _ensureTWAMMExecutor() internal returns (TWAMMSwapExecutor executor) {
        executor = _twammExecutor;
        if (address(executor) == address(0)) {
            executor = TWAMMLogic.ensureExecutor(executor);
            _twammExecutor = executor;
        }
    }

    /// @notice Submits a new TWAMM streaming order that executes over `durationSeconds` against the pool.
    function submitTWAMMOrder(PoolKey calldata key, bool zeroForOne, uint128 totalAmount, uint64 durationSeconds)
        external
        payable
        virtual
        returns (uint256 orderId)
    {
        orderId = nextTWAMMOrderId++;
        PoolId poolId = key.toId();
        TWAMMSwapExecutor executor = _poolTWAMMOrderIds[poolId].length > 0 ? _ensureTWAMMExecutor() : _twammExecutor;
        TWAMMLogic.submitOrder(
            _twammStates,
            _twammOrders,
            _poolTWAMMOrderIds,
            orderId,
            poolId,
            key,
            zeroForOne,
            totalAmount,
            durationSeconds,
            executor
        );
    }

    /// @notice Cancels an active TWAMM order, settling any already-streamed volume (when liquidity exists), refunding
    ///         unswapped input tokens, and paying out any accrued output tokens.
    function cancelTWAMMOrder(PoolKey calldata key, uint256 orderId) external virtual returns (uint256 refundAmount) {
        TWAMMSwapExecutor executor = _ensureTWAMMExecutor();
        return TWAMMLogic.cancelOrder(_twammStates, _twammOrders, _poolTWAMMOrderIds, key, orderId, executor);
    }

    /// @notice Claims accrued output tokens (and any remaining unswapped/truncation-dust input once expired) for a
    ///         TWAMM order.
    function claimTWAMMOrder(PoolKey calldata key, uint256 orderId)
        external
        virtual
        returns (uint256 amountOut, uint256 refundAmount)
    {
        return _claimTWAMMOrder(key, orderId);
    }

    function _claimTWAMMOrder(PoolKey calldata key, uint256 orderId)
        internal
        returns (uint256 amountOut, uint256 refundAmount)
    {
        TWAMMSwapExecutor executor = _ensureTWAMMExecutor();
        return TWAMMLogic.claimOrder(_twammStates, _twammOrders, _poolTWAMMOrderIds, key, orderId, executor);
    }

    /// @notice Advances TWAMM virtual order streaming up to `block.timestamp`.
    function _executePendingTWAMMOrders(PoolId poolId) internal {
        TWAMMLogic.executePending(_twammStates, _twammOrders, _poolTWAMMOrderIds, poolId);
    }

    /// @notice Advances TWAMM virtual order streaming up to `block.timestamp` and settles streamed volume against the
    ///         already-unlocked `PoolManager`.
    function _executePendingTWAMMOrders(PoolKey calldata key, PoolId poolId) internal {
        TWAMMLogic.executePendingWithSwap(
            _twammStates, _twammOrders, _poolTWAMMOrderIds, key, poolId, true, TWAMMSwapExecutor(payable(address(0)))
        );
    }

    function _previewTWAMMState(PoolId poolId) internal view returns (TWAMMLogic.TWAMMState memory) {
        return TWAMMLogic.previewState(_twammStates, _twammOrders, _poolTWAMMOrderIds, poolId);
    }
}
