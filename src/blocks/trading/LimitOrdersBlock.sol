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
import {IMsgSender} from "../../interfaces/IMsgSender.sol";

/// @notice Executes claim swaps through the full hook pipeline and reports the order maker as `msgSender()`
///         so the hook attributes fees, crowns and rewards to the maker rather than to the executor.
contract LimitOrderSwapExecutor is IUnlockCallback, IMsgSender {
    using CurrencySettler for Currency;

    IPoolManager public immutable poolManager;
    address public immutable hook;

    error OnlyHookCaller(address caller);

    bytes32 private constant RECIPIENT_SLOT = keccak256("hookrig.transient.limitOrderRecipient.v1");

    struct FillCallbackData {
        PoolKey key;
        bool zeroForOne;
        uint128 inputAmount;
        address recipient;
    }

    constructor(IPoolManager _poolManager, address _hook) {
        poolManager = _poolManager;
        hook = _hook;
    }

    receive() external payable {}

    function executeFillSwap(PoolKey calldata key, bool zeroForOne, uint128 inputAmount, address recipient)
        external
        payable
        returns (uint256 outputAmount)
    {
        if (msg.sender != hook) revert OnlyHookCaller(msg.sender);
        bytes32 slot = RECIPIENT_SLOT;
        assembly ("memory-safe") {
            tstore(slot, recipient)
        }
        bytes memory res = poolManager.unlock(
            abi.encode(
                FillCallbackData({key: key, zeroForOne: zeroForOne, inputAmount: inputAmount, recipient: recipient})
            )
        );
        outputAmount = abi.decode(res, (uint256));
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    /// @notice The order maker for the claim swap in progress (zero outside a claim).
    function msgSender() external view override returns (address sender) {
        bytes32 slot = RECIPIENT_SLOT;
        assembly ("memory-safe") {
            sender := tload(slot)
        }
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
    error InsufficientPoolEscrow(PoolId poolId, Currency currency, uint256 requested, uint256 available);
    error ClaimOutputBelowMinimum(uint256 orderId, uint256 outAmount, uint256 minAmountOut);

    function placeOrder(
        mapping(uint256 => UserLimitOrder) storage orders,
        mapping(PoolId => mapping(int24 => mapping(bool => LimitOrderBucket))) storage buckets,
        mapping(PoolId => mapping(Currency => uint256)) storage poolEscrow,
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
                (, int24 currentTick,,) = StateLibrary.getSlot0(IHasPoolManager(address(this)).poolManager(), poolId);
                if (zeroForOne ? currentTick > targetTick : currentTick < targetTick) {
                    bucket.filled = false;
                } else {
                    revert BucketAlreadyFilled(orderId);
                }
            }
        }

        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        if (inputCurrency.isAddressZero()) {
            if (msg.value != inputAmount) revert InvalidOrderAmount();
        } else {
            if (msg.value != 0) revert InvalidOrderAmount();
            IERC20 token = IERC20(Currency.unwrap(inputCurrency));
            uint256 balBefore = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), inputAmount);
            if (token.balanceOf(address(this)) - balBefore != inputAmount) revert InvalidOrderAmount();
        }
        poolEscrow[poolId][inputCurrency] += inputAmount;

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
        mapping(PoolId => mapping(Currency => uint256)) storage poolEscrow,
        PoolKey calldata key,
        uint256 orderId
    ) external {
        UserLimitOrder storage order = orders[orderId];
        if (order.maker != msg.sender) revert NotOrderMaker(msg.sender);
        if (order.claimedOrCancelled) revert OrderAlreadyHandled(orderId);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(order.poolId)) revert OrderPoolKeyMismatch();

        // A filled bucket only marks that its tick was crossed; the input stays escrowed until claim, so a maker
        // can always take it back (no lock when a claim swap cannot execute).
        LimitOrderBucket storage bucket = buckets[order.poolId][order.targetTick][order.zeroForOne];
        order.claimedOrCancelled = true;
        bucket.totalInputAmount -= order.inputAmount;
        if (bucket.totalInputAmount == 0) {
            bucket.filled = false;
        }

        Currency inputCurrency = order.zeroForOne ? key.currency0 : key.currency1;
        uint256 escrowed = poolEscrow[order.poolId][inputCurrency];
        if (escrowed < order.inputAmount) {
            revert InsufficientPoolEscrow(order.poolId, inputCurrency, order.inputAmount, escrowed);
        }
        poolEscrow[order.poolId][inputCurrency] = escrowed - order.inputAmount;
        inputCurrency.transfer(msg.sender, order.inputAmount);

        emit LimitOrderCancelled(orderId, order.poolId, msg.sender, order.inputAmount);
    }

    function ensureExecutor(LimitOrderSwapExecutor executor) external returns (LimitOrderSwapExecutor) {
        if (address(executor) == address(0)) {
            executor = new LimitOrderSwapExecutor(IHasPoolManager(address(this)).poolManager(), address(this));
        }
        return executor;
    }

    function claimOrder(
        mapping(uint256 => UserLimitOrder) storage orders,
        mapping(PoolId => mapping(int24 => mapping(bool => LimitOrderBucket))) storage buckets,
        mapping(PoolId => mapping(Currency => uint256)) storage poolEscrow,
        mapping(PoolId => int24) storage lastTicks,
        PoolKey calldata key,
        uint256 orderId,
        uint256 minAmountOut,
        bool swapOnClaim,
        LimitOrderSwapExecutor executor
    ) external {
        UserLimitOrder storage order = orders[orderId];
        if (order.maker != msg.sender) revert NotOrderMaker(msg.sender);
        if (order.claimedOrCancelled) revert OrderAlreadyHandled(orderId);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(order.poolId)) revert OrderPoolKeyMismatch();

        {
            LimitOrderBucket storage bucket = buckets[order.poolId][order.targetTick][order.zeroForOne];
            if (!bucket.filled) revert BucketNotYetFilled(orderId);

            order.claimedOrCancelled = true;
            bucket.totalInputAmount -= order.inputAmount;
            if (bucket.totalInputAmount == 0) {
                bucket.filled = false;
            }
        }

        Currency inputCurrency = order.zeroForOne ? key.currency0 : key.currency1;
        {
            uint256 escrowed = poolEscrow[order.poolId][inputCurrency];
            if (escrowed < order.inputAmount) {
                revert InsufficientPoolEscrow(order.poolId, inputCurrency, order.inputAmount, escrowed);
            }
            poolEscrow[order.poolId][inputCurrency] = escrowed - order.inputAmount;
        }

        uint128 paidOut = order.inputAmount;
        if (swapOnClaim && address(executor) != address(0)) {
            paidOut = _executeClaimSwap(lastTicks, buckets, key, order, inputCurrency, orderId, minAmountOut, executor);
        } else {
            inputCurrency.transfer(msg.sender, order.inputAmount);
        }

        emit LimitOrderClaimed(orderId, order.poolId, msg.sender, paidOut);
    }

    function _executeClaimSwap(
        mapping(PoolId => int24) storage lastTicks,
        mapping(PoolId => mapping(int24 => mapping(bool => LimitOrderBucket))) storage buckets,
        PoolKey calldata key,
        UserLimitOrder storage order,
        Currency inputCurrency,
        uint256 orderId,
        uint256 minAmountOut,
        LimitOrderSwapExecutor executor
    ) private returns (uint128 paidOut) {
        PoolId poolId = order.poolId;
        uint128 inAmt = order.inputAmount;
        bool zeroForOne = order.zeroForOne;

        // The claim swap runs through the full hook pipeline (fees, cuts, protections) like any other swap.
        uint256 outAmount;
        if (inputCurrency.isAddressZero()) {
            outAmount = executor.executeFillSwap{value: inAmt}(key, zeroForOne, inAmt, msg.sender);
        } else {
            IERC20(Currency.unwrap(inputCurrency)).safeTransfer(address(executor), inAmt);
            outAmount = executor.executeFillSwap(key, zeroForOne, inAmt, msg.sender);
        }
        if (outAmount == 0) revert BucketNotYetFilled(orderId);
        if (outAmount < minAmountOut) revert ClaimOutputBelowMinimum(orderId, outAmount, minAmountOut);
        paidOut = outAmount > type(uint128).max ? type(uint128).max : uint128(outAmount);

        (, int24 postTick,,) = StateLibrary.getSlot0(executor.poolManager(), poolId);
        processCrossedTicks(lastTicks, buckets, poolId, key.tickSpacing, postTick);
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

        if (movedUp) {
            int24 rem = prevTick % step;
            int24 aligned = rem == 0 ? prevTick : (rem > 0 ? prevTick + (step - rem) : prevTick - rem);
            int24 t = aligned;
            for (; t <= postSwapTick && stepsChecked < MAX_TICK_FILLS_PER_SWAP; t += step) {
                stepsChecked++;
                LimitOrderBucket storage b = buckets[poolId][t][false];
                if (b.totalInputAmount > 0 && !b.filled) {
                    b.filled = true;
                    emit LimitOrderTickCrossed(poolId, t, false, b.totalInputAmount);
                }
            }
        } else {
            int24 rem = prevTick % step;
            int24 aligned = rem == 0 ? prevTick : (rem > 0 ? prevTick - rem : prevTick - (rem + step));
            int24 t = aligned;
            for (; t >= postSwapTick && stepsChecked < MAX_TICK_FILLS_PER_SWAP; t -= step) {
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
    mapping(PoolId poolId => mapping(Currency currency => uint256 amount)) public limitOrderPoolEscrow;

    function _initLimitOrders(PoolId poolId, int24 initialTick) internal {
        _limitOrderLastTick[poolId] = initialTick;
    }

    function _swapFilledOrderOnClaim() internal view virtual returns (bool) {
        return true;
    }

    function placeLimitOrder(PoolKey calldata key, int24 targetTick, bool zeroForOne, uint128 inputAmount)
        external
        payable
        returns (uint256 orderId)
    {
        orderId = nextLimitOrderId++;
        LimitOrdersLogic.placeOrder(
            _limitOrders,
            _limitOrderBuckets,
            limitOrderPoolEscrow,
            orderId,
            key.toId(),
            key,
            targetTick,
            zeroForOne,
            inputAmount
        );
    }

    /// @notice Guarantee liveness: makers can always cancel unclaimed orders and recover escrowed tokens.
    function cancelLimitOrder(PoolKey calldata key, uint256 orderId) external {
        LimitOrdersLogic.cancelOrder(_limitOrders, _limitOrderBuckets, limitOrderPoolEscrow, key, orderId);
    }

    /// @notice Claims a filled order with no output floor. Prefer the overload with `minAmountOut`.
    function claimLimitOrder(PoolKey calldata key, uint256 orderId) external virtual {
        _claimLimitOrder(key, orderId, 0);
    }

    /// @notice Guarantee liveness: makers can always claim/withdraw orders once their target tick has been crossed.
    /// @param minAmountOut Reverts when the claim swap pays the maker less than this amount (sandwich protection).
    function claimLimitOrder(PoolKey calldata key, uint256 orderId, uint256 minAmountOut) external virtual {
        _claimLimitOrder(key, orderId, minAmountOut);
    }

    function _claimLimitOrder(PoolKey calldata key, uint256 orderId, uint256 minAmountOut) internal {
        bool swapOnClaim = _swapFilledOrderOnClaim();
        LimitOrderSwapExecutor executor = _limitOrderExecutor;
        if (swapOnClaim && address(executor) == address(0)) {
            executor = LimitOrdersLogic.ensureExecutor(executor);
            _limitOrderExecutor = executor;
        }
        LimitOrdersLogic.claimOrder(
            _limitOrders,
            _limitOrderBuckets,
            limitOrderPoolEscrow,
            _limitOrderLastTick,
            key,
            orderId,
            minAmountOut,
            swapOnClaim,
            executor
        );
    }

    function _processCrossedLimitOrderTicks(PoolId poolId, int24 tickSpacing, int24 postSwapTick) internal {
        LimitOrdersLogic.processCrossedTicks(_limitOrderLastTick, _limitOrderBuckets, poolId, tickSpacing, postSwapTick);
    }
}
