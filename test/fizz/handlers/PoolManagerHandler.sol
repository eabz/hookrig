// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../Base.sol";
import {Properties} from "../Properties.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Handles swaps, liquidity changes, and donations routed through Uniswap v4 PoolManager into the hook.
/// @dev `routeMode` selects how the hook resolves the user (`HookRigBase._resolveUser`):
///      0 = trusted router (`IMsgSender` → actor), 1 = plain router + honest hookData (actor),
///      2 = plain router + spoofed hookData (another actor), 3 = plain router + empty hookData (router address).
abstract contract PoolManagerHandler is Properties {
    using PoolIdLibrary for PoolKey;

    uint8 internal constant ROUTE_MODES = 4;
    uint256 internal constant MAX_SWAP_AMOUNT = 1_000_000 ether;
    uint256 internal constant MAX_LIQUIDITY = 1_000_000 ether;
    uint32 internal constant JIT_BITS = HookPermissionMasks.BIT_MEV_PROTECTION | HookPermissionMasks.BIT_JIT_GUARD;
    /// @notice Longest hold the LP round trip waits out: past ~23.3 h the oracle checkpoint math overflows (SP-21).
    uint256 internal constant MAX_RT_HOLD_SECONDS = 80_000;

    /// @notice Per-swap context captured before the router call (kept in storage to stay below the stack limit).
    struct SwapCtx {
        uint256 idx;
        bool zeroForOne;
        int256 amountSpecified;
        address user; // identity the hook resolves
        uint32 bitmap;
        int24 preTick;
        uint256 prevTouch; // `ghosts.lastOracleTouch[idx]` before the call
        uint256 bal0; // actor balances before the call
        uint256 bal1;
    }

    SwapCtx internal swapCtx;

    /// @notice Inputs of an LP round trip (SP-29).
    struct LpRoundTrip {
        uint256 idx;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidity;
        bool useTrusted;
        bytes hookData;
        bytes32 salt;
        uint256 b0;
        uint256 b1;
    }

    /// @notice Balances around a pool swap round trip (SP-04).
    struct SwapRoundTrip {
        Currency inA;
        Currency outB;
        uint256 balA;
        uint256 balB;
        uint256 claimsA;
    }

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    function pool_swap_clamped(
        uint256 poolSeed,
        bool zeroForOne,
        bool exactInput,
        uint256 amount,
        uint8 routeMode,
        address spoofSeed
    ) public tracked {
        uint256 idx = _poolIdx(poolSeed);
        if (!_isPoolLive(idx)) return;
        amount = clampBetween(amount, 1e6, MAX_SWAP_AMOUNT);
        (bool useTrusted, bytes memory hookData) = _route(routeMode, spoofSeed);
        pool_swap(idx, zeroForOne, exactInput ? -int256(amount) : int256(amount), useTrusted, hookData);
    }

    /// @notice Near-zero stress: sub-unit swaps where every floor-rounded cut truncates.
    function pool_swap_dust(uint256 poolSeed, bool zeroForOne, bool exactInput, uint256 amount, uint8 routeMode)
        public
        tracked
    {
        uint256 idx = _poolIdx(poolSeed);
        if (!_isPoolLive(idx)) return;
        amount = clampBetween(amount, 1, 1e6);
        (bool useTrusted, bytes memory hookData) = _route(routeMode, address(0));
        pool_swap(idx, zeroForOne, exactInput ? -int256(amount) : int256(amount), useTrusted, hookData);
    }

    /// @notice Full-amount stress: spends the actor's whole input balance in one exact-input swap.
    function pool_swap_fullBalance(uint256 poolSeed, bool zeroForOne, uint8 routeMode) public tracked {
        uint256 idx = _poolIdx(poolSeed);
        if (!_isPoolLive(idx)) return;
        PoolKey memory key = poolKeys[idx];
        address input = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        uint256 balance = MockBurnableERC20(input).balanceOf(actor);
        if (balance == 0) return;
        (bool useTrusted, bytes memory hookData) = _route(routeMode, address(0));
        pool_swap(idx, zeroForOne, -int256(balance), useTrusted, hookData);
    }

    /// @notice Honest seller (SP-18): a trusted-route exact-input sell of at most maxDailySellBps of the balance by an
    ///         actor that has not sold on this pool in the current epoch.
    function pool_swap_honestSell(uint256 poolSeed, uint256 amount) public tracked {
        uint256 idx = _poolIdx(poolSeed);
        if (!_isPoolLive(idx)) return;
        PoolKey memory key = poolKeys[idx];
        PoolId pid = key.toId();
        uint16 maxBps = ghosts.vestingMaxBps[idx];
        if ((orchestrator.getPoolEnabledBlocks(pid) & HookPermissionMasks.BIT_VESTING_SELL_CAP) == 0) return;
        if (maxBps == 0 || maxBps >= 10_000 || !orchestrator.isTrustedRouter(address(trustedRouter))) return;
        if (ghosts.soldInEpoch[pid][actor][block.timestamp / 1 days] != 0) return;
        uint256 cap = (_currencyBalance(key.currency1, actor) * maxBps) / 10_000;
        if (cap == 0) return;
        amount = clampBetween(amount, 1, cap);

        _beginSwap(idx, false, -int256(amount), true, "");
        vm.prank(actor);
        try trustedRouter.swap(key, _swapParams(false, -int256(amount)), "") {
            _finishSwap();
        } catch (bytes memory err) {
            property_SP18_vestingCapNoGrief(_revertSelector(err));
        }
    }

    /// @notice Round trip (SP-04): exact-input A → B, then all B received back to A, with one route mode.
    function pool_swapRoundTrip(uint256 poolSeed, bool zeroForOne, uint256 amount, uint8 routeMode, bool dust)
        public
        tracked
    {
        uint256 idx = _poolIdx(poolSeed);
        if (!_isPoolLive(idx)) return;
        amount = dust ? clampBetween(amount, 1, 1e6) : clampBetween(amount, 1e6, MAX_SWAP_AMOUNT);
        (bool useTrusted, bytes memory hookData) = _route(routeMode, address(uint160(poolSeed >> 8)));

        SwapRoundTrip memory r = _swapRoundTripStart(idx, zeroForOne);
        if (r.balA < amount) return;
        _swapRaw(idx, zeroForOne, -int256(amount), useTrusted, hookData);
        uint256 balBMid = _currencyBalance(r.outB, actor);
        uint256 received = balBMid > r.balB ? balBMid - r.balB : 0;
        if (received > 0) _swapRaw(idx, !zeroForOne, -int256(received), useTrusted, hookData);
        snapshotAfter();

        uint256 claimsA = orchestrator.poolClaims(poolKeys[idx].toId(), r.inA, actor);
        property_SP04_swapRoundTrip(
            r.balA,
            _currencyBalance(r.inA, actor),
            claimsA > r.claimsA ? claimsA - r.claimsA : 0,
            r.balB,
            _currencyBalance(r.outB, actor)
        );
        property_SP09_swapDeltaIdentity(idx, 2);
    }

    /// @notice SP-24: JIT add (route 1) → swap through the buyback floor → remove (route 3, fresh identity, no hold)
    ///         → swap back, on POOL_MULTI (the only setup pool with AutoBuyback).
    function pool_jitBuybackSnipe(uint256 liquidity, uint256 swapAmount) public tracked {
        uint256 idx = POOL_MULTI;
        PoolKey memory key = poolKeys[idx];
        if ((orchestrator.getPoolEnabledBlocks(key.toId()) & HookPermissionMasks.BIT_AUTO_BUYBACK) == 0) return;
        liquidity = clampBetween(liquidity, 1e18, MAX_LIQUIDITY);
        swapAmount = clampBetween(swapAmount, 1e15, MAX_SWAP_AMOUNT);
        (uint160 sqrtP0,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        uint256 valueBefore = _portfolioValue(key, sqrtP0);
        bytes32 salt = keccak256(abi.encode("jit", actor, ghosts.rtNonce++));

        _liquidityRaw(idx, -600, 600, int256(liquidity), false, abi.encode(actor), salt);
        uint256 bal1 = _currencyBalance(key.currency1, actor);
        // zeroForOne pushes the tick down through `triggerFloorTick`, deploying the buyback reserve as an LP donation
        _swapRaw(idx, true, -int256(swapAmount), true, "");
        uint256 bal1Mid = _currencyBalance(key.currency1, actor);
        _liquidityRaw(idx, -600, 600, -int256(liquidity), false, "", salt);
        if (bal1Mid > bal1) _swapRaw(idx, false, -int256(bal1Mid - bal1), true, "");
        snapshotAfter();

        property_SP24_noJitDonationCapture(valueBefore, _portfolioValue(key, sqrtP0));
    }

    function pool_addLiquidity_clamped(
        uint256 poolSeed,
        uint8 rangeSeed,
        uint256 liquidity,
        uint8 routeMode,
        address spoofSeed
    ) public tracked {
        uint256 idx = _poolIdx(poolSeed);
        if (!_isPoolLive(idx)) return;
        (int24 tickLower, int24 tickUpper) = _range(rangeSeed);
        liquidity = clampBetween(liquidity, 1e15, MAX_LIQUIDITY);
        (bool useTrusted, bytes memory hookData) = _route(routeMode, spoofSeed);
        pool_modifyLiquidity(idx, tickLower, tickUpper, int256(liquidity), useTrusted, hookData);
    }

    function pool_removeLiquidity_clamped(
        uint256 poolSeed,
        uint8 rangeSeed,
        uint256 liquidity,
        uint8 routeMode,
        address spoofSeed
    ) public tracked {
        uint256 idx = _poolIdx(poolSeed);
        if (!_isPoolLive(idx)) return;
        (int24 tickLower, int24 tickUpper) = _range(rangeSeed);
        (bool useTrusted, bytes memory hookData) = _route(routeMode, spoofSeed);
        uint128 owned = _positionLiquidity(idx, _router(useTrusted), tickLower, tickUpper);
        if (owned == 0) return;
        liquidity = clampBetween(liquidity, 1, owned);
        pool_modifyLiquidity(idx, tickLower, tickUpper, -int256(liquidity), useTrusted, hookData);
    }

    /// @notice Full-amount stress: exits the whole position (LP exit must never be blocked by access control).
    ///         Once the hold for the identity used has expired, the exit must not revert (SP-21).
    function pool_removeLiquidity_full(uint256 poolSeed, uint8 rangeSeed, uint8 routeMode, address spoofSeed)
        public
        tracked
    {
        uint256 idx = _poolIdx(poolSeed);
        if (!_isPoolLive(idx)) return;
        (int24 tickLower, int24 tickUpper) = _range(rangeSeed);
        (bool useTrusted, bytes memory hookData) = _route(routeMode, spoofSeed);
        uint128 owned = _positionLiquidity(idx, _router(useTrusted), tickLower, tickUpper);
        if (owned == 0) return;
        address user = _resolvedUser(useTrusted, hookData);
        bool liveness = _holdExpired(idx, user, tickLower, tickUpper, _positionSalt(actor));
        _modifyLiquidityChecked(idx, tickLower, tickUpper, -int256(uint256(owned)), useTrusted, hookData, liveness);
    }

    /// @notice Round trip (SP-29): add L on a fresh salt, wait out the JIT hold, remove the same L with the same route.
    /// @dev Waits `minHold` blocks rather than a fixed 7201 so oracle pools stay below the 23.3 h checkpoint overflow.
    function pool_liquidityRoundTrip(uint256 poolSeed, uint8 rangeSeed, uint256 liquidity, uint8 routeMode)
        public
        tracked
    {
        uint256 idx = _poolIdx(poolSeed);
        if (!_isPoolLive(idx)) return;
        LpRoundTrip memory r;
        r.idx = idx;
        (r.tickLower, r.tickUpper) = _range(rangeSeed);
        r.liquidity = int256(clampBetween(liquidity, 1e15, MAX_LIQUIDITY));
        (r.useTrusted, r.hookData) = _route(routeMode, address(uint160(poolSeed >> 8)));
        uint256 hold = (orchestrator.getPoolEnabledBlocks(poolKeys[idx].toId()) & JIT_BITS) != 0 ? ghosts.minHold[idx] : 0;
        if (hold * BLOCK_INTERVAL > MAX_RT_HOLD_SECONDS) return;
        r.salt = keccak256(abi.encode("rt", actor, ghosts.rtNonce++));
        r.b0 = _currencyBalance(poolKeys[idx].currency0, actor);
        r.b1 = _currencyBalance(poolKeys[idx].currency1, actor);

        _liquidityRaw(r.idx, r.tickLower, r.tickUpper, r.liquidity, r.useTrusted, r.hookData, r.salt);
        if (hold > 0) skipBlocks(hold);
        _liquidityRaw(r.idx, r.tickLower, r.tickUpper, -r.liquidity, r.useTrusted, r.hookData, r.salt);
        snapshotAfter();

        property_SP29_lpRoundTrip(
            r.b0, _currencyBalance(poolKeys[idx].currency0, actor), r.b1, _currencyBalance(poolKeys[idx].currency1, actor)
        );
    }

    function pool_donate_clamped(uint256 poolSeed, uint256 amount0, uint256 amount1) public tracked {
        uint256 idx = _poolIdx(poolSeed);
        if (!_isPoolLive(idx)) return;
        amount0 = clampLte(amount0, 10_000 ether);
        amount1 = clampLte(amount1, 10_000 ether);
        pool_donate(idx, amount0, amount1);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function pool_swap(
        uint256 poolIdx,
        bool zeroForOne,
        int256 amountSpecified,
        bool useTrustedRouter,
        bytes memory hookData
    ) public tracked {
        uint256 idx = _poolIdx(poolIdx);
        _beginSwap(idx, zeroForOne, amountSpecified, useTrustedRouter, hookData);
        vm.prank(actor);
        _router(useTrustedRouter).swap(poolKeys[idx], _swapParams(zeroForOne, amountSpecified), hookData);
        _finishSwap();
    }

    function pool_modifyLiquidity(
        uint256 poolIdx,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bool useTrustedRouter,
        bytes memory hookData
    ) public tracked {
        _modifyLiquidityChecked(_poolIdx(poolIdx), tickLower, tickUpper, liquidityDelta, useTrustedRouter, hookData, false);
    }

    function pool_donate(uint256 poolIdx, uint256 amount0, uint256 amount1) public tracked asActor {
        _setCallContext(CallKind.DONATE, actor, _poolIdx(poolIdx), address(0));
        trustedRouter.donate(poolKeys[_poolIdx(poolIdx)], amount0, amount1, "");
    }

    // ――――――――――――――――――――――― Swap internals ――――――――――――――――――――――――

    /// @notice Records the pre-swap context and the call-context ghosts.
    function _beginSwap(uint256 idx, bool zeroForOne, int256 amountSpecified, bool useTrusted, bytes memory hookData)
        internal
    {
        PoolKey memory key = poolKeys[idx];
        SwapCtx storage c = swapCtx;
        c.idx = idx;
        c.zeroForOne = zeroForOne;
        c.amountSpecified = amountSpecified;
        c.user = _resolvedUser(useTrusted, hookData);
        c.bitmap = orchestrator.getPoolEnabledBlocks(key.toId());
        (, c.preTick,,) = StateLibrary.getSlot0(poolManager, key.toId());
        c.prevTouch = ghosts.lastOracleTouch[idx];
        c.bal0 = _currencyBalance(key.currency0, actor);
        c.bal1 = _currencyBalance(key.currency1, actor);
        _setCallContext(CallKind.SWAP, actor, idx, address(0));
    }

    /// @notice Single-swap epilogue: after-snapshot, ghosts, then every per-swap specific property.
    function _finishSwap() internal {
        snapshotAfter();
        _swapGhosts();
        _checkSwapProperties();
    }

    /// @notice One swap inside a composite handler (ghosts only; the caller asserts its own properties).
    function _swapRaw(uint256 idx, bool zeroForOne, int256 amountSpecified, bool useTrusted, bytes memory hookData)
        internal
    {
        _beginSwap(idx, zeroForOne, amountSpecified, useTrusted, hookData);
        vm.prank(actor);
        _router(useTrusted).swap(poolKeys[idx], _swapParams(zeroForOne, amountSpecified), hookData);
        _swapGhosts();
    }

    function _swapGhosts() internal {
        SwapCtx storage c = swapCtx;
        PoolKey memory key = poolKeys[c.idx];
        PoolId pid = key.toId();
        ghosts.lastSwappedPoolIdx = c.idx;
        ghosts.lastOracleTouch[c.idx] = block.timestamp;
        (, int24 postTick,,) = StateLibrary.getSlot0(poolManager, pid);
        _updateOrderTickRanges(pid, c.preTick, postTick);
        if (!c.zeroForOne && (c.bitmap & HookPermissionMasks.BIT_VESTING_SELL_CAP) != 0) {
            _recordVestingSell(pid, key.currency1);
        }
    }

    /// @notice Mirrors `VestingSellCapLogic.enforceSellCap` for the real wallet (start = pre-balance + first sale).
    function _recordVestingSell(PoolId pid, Currency project) internal {
        SwapCtx storage c = swapCtx;
        uint16 maxBps = ghosts.vestingMaxBps[c.idx];
        if (maxBps == 0 || maxBps >= 10_000) return;
        uint256 balAfter = _currencyBalance(project, actor);
        uint256 sold = c.amountSpecified < 0
            ? uint256(-c.amountSpecified)
            : (c.bal1 > balAfter ? c.bal1 - balAfter : 0);
        if (sold == 0) return;
        uint256 epoch = block.timestamp / 1 days;
        if (ghosts.epochStartBal[pid][actor][epoch] == 0) ghosts.epochStartBal[pid][actor][epoch] = c.bal1 + sold;
        ghosts.soldInEpoch[pid][actor][epoch] += sold;
    }

    /// @notice GL-16: widen the tick range seen by every open tracked order on the swapped pool.
    function _updateOrderTickRanges(PoolId pid, int24 preTick, int24 postTick) internal {
        int24 lo = preTick < postTick ? preTick : postTick;
        int24 hi = preTick < postTick ? postTick : preTick;
        for (uint256 o; o < trackedOrders.length; o++) {
            TrackedOrder storage order = trackedOrders[o];
            if (order.closed || PoolId.unwrap(order.key.toId()) != PoolId.unwrap(pid)) continue;
            if (lo < order.minTickSeen) order.minTickSeen = lo;
            if (hi > order.maxTickSeen) order.maxTickSeen = hi;
        }
    }

    function _checkSwapProperties() internal {
        SwapCtx storage c = swapCtx;
        uint256 i = c.idx;
        bool exactIn = c.amountSpecified < 0;
        // PoolTokenDir: the specified currency is token0 iff zeroForOne == exactInput
        uint256 uSide = c.zeroForOne == exactIn ? 1 : 0;

        property_SP09_swapDeltaIdentity(i, uSide);
        property_SP14_swapIsolation(i);
        property_SP15_accessControlNoSpoof(i, false);
        property_SP20_oracleCheckpointLiveness(i, c.prevTouch);

        PoolKey memory key = poolKeys[i];
        uint256 bal0 = _currencyBalance(key.currency0, actor);
        uint256 bal1 = _currencyBalance(key.currency1, actor);
        if (exactIn) {
            uint256 net = uSide == 1 ? (bal1 > c.bal1 ? bal1 - c.bal1 : 0) : (bal0 > c.bal0 ? bal0 - c.bal0 : 0);
            property_SP10_aggregateCutCap(i, uSide, net);
            int256 withheld = _withheld(i, uSide);
            if (withheld >= 0) property_SP26_claimSlicesFloored(i, uSide, net + uint256(withheld), c.zeroForOne);
        } else if (i == POOL_XYK && !c.zeroForOne && c.bal1 >= bal1) {
            property_SP11_exactOutputCeil(c.bal1 - bal1);
        }

        if (c.zeroForOne) {
            property_SP25_walletCapNoBypass(i);
        } else if ((c.bitmap & HookPermissionMasks.BIT_VESTING_SELL_CAP) != 0) {
            uint16 maxBps = ghosts.vestingMaxBps[i];
            if (maxBps > 0 && maxBps < 10_000) {
                property_SP17_vestingCapNoBypass(key.toId(), actor, block.timestamp / 1 days, maxBps);
            }
        }
    }

    function _swapRoundTripStart(uint256 idx, bool zeroForOne) internal view returns (SwapRoundTrip memory r) {
        PoolKey memory key = poolKeys[idx];
        r.inA = zeroForOne ? key.currency0 : key.currency1;
        r.outB = zeroForOne ? key.currency1 : key.currency0;
        r.balA = _currencyBalance(r.inA, actor);
        r.balB = _currencyBalance(r.outB, actor);
        r.claimsA = orchestrator.poolClaims(key.toId(), r.inA, actor);
    }

    // ――――――――――――――――――――― Liquidity internals ―――――――――――――――――――――

    /// @notice Liquidity change on the actor's standard position (`_positionSalt(actor)`) with its specific properties.
    function _modifyLiquidityChecked(
        uint256 idx,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bool useTrusted,
        bytes memory hookData,
        bool liveness
    ) internal {
        PoolKey memory key = poolKeys[idx];
        uint256 prevTouch = ghosts.lastOracleTouch[idx];
        address user = _resolvedUser(useTrusted, hookData);
        bytes32 salt = _positionSalt(actor);
        _setCallContext(
            liquidityDelta > 0 ? CallKind.ADD_LIQUIDITY : CallKind.REMOVE_LIQUIDITY, actor, idx, address(0)
        );
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: salt
        });

        HookRigTestRouter router = _router(useTrusted);
        vm.prank(actor);
        if (liveness) {
            try router.modifyLiquidity(key, params, hookData) {}
            catch {
                property_SP21_lpExitLiveness(false);
                return;
            }
        } else {
            router.modifyLiquidity(key, params, hookData);
        }
        snapshotAfter();
        _liquidityGhosts(idx, tickLower, tickUpper, liquidityDelta, address(router), user, salt);

        if (liquidityDelta > 0) {
            property_SP15_accessControlNoSpoof(idx, true);
        } else {
            property_SP16_jitHoldNoBypass(idx, Position.calculatePositionKey(address(router), tickLower, tickUpper, salt));
        }
        property_SP20_oracleCheckpointLiveness(idx, prevTouch);
    }

    /// @notice One liquidity change inside a composite handler (ghosts only).
    function _liquidityRaw(
        uint256 idx,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bool useTrusted,
        bytes memory hookData,
        bytes32 salt
    ) internal {
        address user = _resolvedUser(useTrusted, hookData);
        HookRigTestRouter router = _router(useTrusted);
        vm.prank(actor);
        router.modifyLiquidity(
            poolKeys[idx],
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: salt
            }),
            hookData
        );
        _liquidityGhosts(idx, tickLower, tickUpper, liquidityDelta, address(router), user, salt);
    }

    /// @notice Oracle touch on every hook liquidity call; JIT add blocks (router key for SP-16, hook key for SP-21).
    function _liquidityGhosts(
        uint256 idx,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        address router,
        address user,
        bytes32 salt
    ) internal {
        ghosts.lastOracleTouch[idx] = block.timestamp;
        if (liquidityDelta <= 0) return;
        if ((orchestrator.getPoolEnabledBlocks(poolKeys[idx].toId()) & JIT_BITS) == 0) return;
        ghosts.lpAddBlock[idx][Position.calculatePositionKey(router, tickLower, tickUpper, salt)] = block.number;
        ghosts.lpUserAddBlock[idx][keccak256(abi.encodePacked(user, tickLower, tickUpper, salt))] = block.number;
    }

    /// @notice True when the hook's JIT hold for `(user, range, salt)` has expired (or does not apply).
    function _holdExpired(uint256 idx, address user, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        view
        returns (bool)
    {
        if ((orchestrator.getPoolEnabledBlocks(poolKeys[idx].toId()) & JIT_BITS) == 0) return true;
        uint256 added = ghosts.lpUserAddBlock[idx][keccak256(abi.encodePacked(user, tickLower, tickUpper, salt))];
        uint256 plainAdded =
            ghosts.lpAddBlock[idx][Position.calculatePositionKey(address(plainRouter), tickLower, tickUpper, salt)];
        if (plainAdded > added) added = plainAdded;
        uint256 trustedAdded =
            ghosts.lpAddBlock[idx][Position.calculatePositionKey(address(trustedRouter), tickLower, tickUpper, salt)];
        if (trustedAdded > added) added = trustedAdded;
        return added == 0 || block.number >= added + ghosts.minHold[idx];
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    function _swapParams(bool zeroForOne, int256 amountSpecified) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
    }

    function _route(uint8 routeMode, address spoofSeed)
        internal
        view
        returns (bool useTrustedRouter, bytes memory hookData)
    {
        uint8 mode = routeMode % ROUTE_MODES;
        if (mode == 0) return (true, "");
        if (mode == 1) return (false, abi.encode(actor));
        if (mode == 2) return (false, abi.encode(toActorNotCurrent(spoofSeed)));
        return (false, "");
    }

    /// @notice The address `HookRigBase._resolveUser` resolves for a handler call by `actor` through this route.
    function _resolvedUser(bool useTrustedRouter, bytes memory) internal view returns (address user) {
        address router = address(_router(useTrustedRouter));
        if (orchestrator.isTrustedRouter(router)) return actor; // the test router reports its caller (the actor)
        return router;
    }

    function _router(bool useTrustedRouter) internal view returns (HookRigTestRouter) {
        return useTrustedRouter ? trustedRouter : plainRouter;
    }

    /// @notice Three ranges whose bounds are multiples of every tick spacing used (10, 30, 60).
    function _range(uint8 rangeSeed) internal pure returns (int24 tickLower, int24 tickUpper) {
        uint8 r = rangeSeed % 3;
        if (r == 0) return (-6000, 6000);
        if (r == 1) return (-600, 600);
        return (-1200, -60);
    }

    function _positionLiquidity(uint256 idx, HookRigTestRouter router, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128)
    {
        bytes32 positionKey = Position.calculatePositionKey(address(router), tickLower, tickUpper, _positionSalt(actor));
        return StateLibrary.getPositionLiquidity(poolManager, poolKeys[idx].toId(), positionKey);
    }

    /// @notice Actor's currency0 + currency1 holdings valued in currency0 at `sqrtPriceX96` (SP-24).
    function _portfolioValue(PoolKey memory key, uint160 sqrtPriceX96) internal view returns (uint256) {
        uint256 bal1 = _currencyBalance(key.currency1, actor);
        uint256 bal1In0 = FullMath.mulDiv(FullMath.mulDiv(bal1, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
        return _currencyBalance(key.currency0, actor) + bal1In0;
    }
}
