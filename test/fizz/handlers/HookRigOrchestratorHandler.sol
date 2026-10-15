// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../Base.sol";
import {Properties} from "../Properties.sol";
import {KingOfThePoolLogic} from "../../../src/blocks/rewards/KingOfThePoolBlock.sol";
import {LimitOrdersLogic} from "../../../src/blocks/trading/LimitOrdersBlock.sol";

/// @notice Handles the interaction with HookRigOrchestrator
abstract contract HookRigOrchestratorHandler is Properties {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant MAX_ORDER_AMOUNT = 1_000_000 ether;
    uint256 internal constant MAX_FUZZ_POOLS = 12;
    uint16 internal constant FUZZ_CUT_BPS_MAX = 300; // 7 return-delta blocks × 300 = 2100 ≤ 2500 aggregate cap
    uint24 internal constant MAX_MANAGED_FEE_CAP = 50_000; // `ManagedFeeLogic.MAX_MANAGED_FEE_CAP`
    uint32 internal constant MAX_LP_HOLD_BLOCKS = 7200; // `JITGuardBlock.MAX_LP_HOLD_BLOCKS`

    /// @notice Maker balances around a limit-order cancel / claim (SP-03, SP-28).
    struct SettleObs {
        bool tracked;
        uint256 idx;
        uint256 inBefore;
        uint256 outBefore;
    }

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    function hookRigOrchestrator_placeLimitOrder_clamped(
        uint256 poolSeed,
        int24 tickOffset,
        bool zeroForOne,
        uint128 inputAmount,
        bool nativeKey
    ) public tracked {
        (bool ok, PoolKey memory key, int24 targetTick, uint128 amount) =
            _clampOrder(poolSeed, tickOffset, zeroForOne, inputAmount, nativeKey);
        if (!ok) return;
        hookRigOrchestrator_placeLimitOrder(key, targetTick, zeroForOne, amount);
    }

    /// @notice Honest maker cancel: may only revert with `BucketAlreadyFilled` (SP-03).
    function hookRigOrchestrator_cancelLimitOrder_clamped(uint256 orderSeed) public tracked {
        if (trackedOrders.length == 0) return;
        TrackedOrder storage order = trackedOrders[orderSeed % trackedOrders.length];
        if (order.closed) return;
        actor = order.maker;
        _settleOrder(order.key, order.id, false, true);
    }

    /// @notice Honest maker claim: may only revert with `BucketNotYetFilled` (SP-03, SP-28).
    function hookRigOrchestrator_claimLimitOrder_clamped(uint256 orderSeed) public tracked {
        if (trackedOrders.length == 0) return;
        TrackedOrder storage order = trackedOrders[orderSeed % trackedOrders.length];
        if (order.closed) return;
        actor = order.maker;
        _settleOrder(order.key, order.id, true, true);
    }

    /// @notice Round trip (SP-03): place an order and immediately cancel it (or claim it if its bucket was already
    ///         filled); the maker must not end with more of the input currency than it started with.
    function hookRigOrchestrator_limitOrderRoundTrip(
        uint256 poolSeed,
        int24 tickOffset,
        bool zeroForOne,
        uint128 inputAmount,
        bool nativeKey
    ) public tracked {
        (bool ok, PoolKey memory key, int24 targetTick, uint128 amount) =
            _clampOrder(poolSeed, tickOffset, zeroForOne, inputAmount, nativeKey);
        if (!ok) return;
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        uint256 balBefore = _currencyBalance(inputCurrency, actor);

        hookRigOrchestrator_placeLimitOrder(key, targetTick, zeroForOne, amount);
        uint256 last = trackedOrders.length - 1;
        _settleOrder(key, trackedOrders[last].id, false, true);
        if (!trackedOrders[last].closed) _settleOrder(key, trackedOrders[last].id, true, true);

        bool erc20Closed = trackedOrders[last].closed && !inputCurrency.isAddressZero();
        property_SP03_limitOrderRefundBounded(_currencyBalance(inputCurrency, actor), balBefore, erc20Closed);
    }

    function hookRigOrchestrator_withdrawClaim_clamped(
        uint256 poolSeed,
        uint256 currencySeed,
        uint256 claimantSeed,
        uint256 amount,
        address to
    ) public tracked {
        PoolId poolId = poolKeys[_poolIdx(poolSeed)].toId();
        Currency currency = trackedCurrencies[currencySeed % trackedCurrencies.length];
        address claimant = claimants[claimantSeed % claimants.length];
        uint256 available = orchestrator.poolClaims(poolId, currency, claimant);
        if (available == 0) return;
        amount = clampBetween(amount, 1, available);
        _withdrawClaimAs(claimant, poolId, currency, amount, toActor(to), false);
    }

    /// @notice Full-amount stress: drains a claimant's entire ledger entry for one pool/currency (must not revert).
    function hookRigOrchestrator_withdrawClaim_full(uint256 poolSeed, uint256 currencySeed, uint256 claimantSeed)
        public
        tracked
    {
        PoolId poolId = poolKeys[_poolIdx(poolSeed)].toId();
        Currency currency = trackedCurrencies[currencySeed % trackedCurrencies.length];
        address claimant = claimants[claimantSeed % claimants.length];
        uint256 available = orchestrator.poolClaims(poolId, currency, claimant);
        if (available == 0) return;
        _withdrawClaimAs(claimant, poolId, currency, available, claimant, true);
    }

    function hookRigOrchestrator_claimKingPot_clamped(uint256 poolSeed, uint64 roundId, uint256 winnerSeed)
        public
        tracked
    {
        PoolId poolId = poolKeys[_poolIdx(poolSeed)].toId();
        (uint64 currentRound,,,) = orchestrator.getCurrentKing(poolId);
        if (currentRound <= 1) return;
        roundId = uint64(clampBetween(roundId, 1, currentRound - 1));
        actor = actors[winnerSeed % actors.length];
        hookRigOrchestrator_claimKingPot(PoolId.unwrap(poolId), roundId, actor);
    }

    /// @notice The recorded winner (any address, incl. routers) claims a settled round; must succeed if unclaimed (SP-02).
    function hookRigOrchestrator_claimKingPot_asWinner(uint256 poolSeed, uint256 roundSeed) public tracked {
        PoolId poolId = poolKeys[_poolIdx(poolSeed)].toId();
        (uint64 currentRound,,,) = orchestrator.getCurrentKing(poolId);
        if (currentRound <= 1) return;
        uint64 roundId = uint64(clampBetween(roundSeed, 1, currentRound - 1));
        KingOfThePoolLogic.SettledKingRound memory settled = orchestrator.settledKingRound(poolId, roundId);
        if (settled.winner == address(0)) return;
        _claimKingAs(settled.winner, poolId, roundId, settled.winner, !settled.claimed && settled.amount > 0);
    }

    function hookRigOrchestrator_finalizeExpiredKingRound_clamped(uint256 poolSeed) public tracked {
        hookRigOrchestrator_finalizeExpiredKingRound(PoolId.unwrap(poolKeys[_poolIdx(poolSeed)].toId()));
    }

    function hookRigOrchestrator_registerReferrer_clamped(uint256 poolSeed, address referrer) public tracked {
        hookRigOrchestrator_registerReferrer(
            PoolId.unwrap(poolKeys[_poolIdx(poolSeed)].toId()), toActorNotCurrent(referrer)
        );
    }

    function hookRigOrchestrator_donateETH(uint256 amount) public tracked {
        if (actor.balance == 0) return;
        amount = clampBetween(amount, 1, actor.balance);
        _setCallContext(CallKind.OTHER, actor, 0, address(orchestrator));
        Actor(payable(actor)).forceSendETH(address(orchestrator), amount);
    }

    function hookRigOrchestrator_donateERC20(uint256 currencySeed, uint256 amount) public tracked {
        address token = Currency.unwrap(trackedCurrencies[currencySeed % trackedCurrencies.length]);
        uint256 balance = MockBurnableERC20(token).balanceOf(actor);
        if (balance == 0) return;
        amount = clampBetween(amount, 1, balance);
        _setCallContext(CallKind.OTHER, actor, 0, address(orchestrator));
        vm.prank(actor);
        MockBurnableERC20(token).transfer(address(orchestrator), amount);
    }

    function hookRigOrchestrator_secondary(
        uint8 selector,
        uint256 arg0,
        uint256 arg1,
        uint256 arg2,
        uint256 arg3,
        address arg4
    ) public tracked {
        selector = uint8(selector % 6);
        if (selector == 0) _registerPoolStack_clamped(arg0, arg1, arg2);
        else if (selector == 1) _setAccessMerkleRoot_clamped(arg0, arg1, bytes32(arg2));
        else if (selector == 2) _setAllowlistAccount_clamped(arg0, arg1, arg4, arg2 % 2 == 0);
        else if (selector == 3) _setManagedPoolFee_clamped(arg0, arg1);
        else if (selector == 4) _submitTWAMMOrder_clamped(arg0, arg1 % 2 == 0, arg2, arg3);
        else _setTrustedRouter_clamped(arg0, arg4, arg1 % 2 == 0);
    }

    /// @notice SP-23: an actor (never an authorized curve nor the factory) cannot call the curve-only hooks.
    function hookRigOrchestrator_unauthorizedCurveCalls(uint256 poolSeed, uint256 amount) public tracked {
        uint256 idx = _poolIdx(poolSeed);
        PoolKey memory key = poolKeys[idx];
        _setCallContext(CallKind.OTHER, actor, idx, address(0));

        bool notified;
        vm.prank(actor);
        try orchestrator.notifyPoolGraduated(key.toId()) {
            notified = true;
        } catch {}
        property_SP23_noPrivilegeEscalation(!notified, "SP-23: notifyPoolGraduated succeeded for an actor");

        bool seeded;
        vm.prank(actor);
        try orchestrator.seedKingPotFromLaunchCurve(key.toId(), key.currency0, amount) {
            seeded = true;
        } catch {}
        property_SP23_noPrivilegeEscalation(!seeded, "SP-23: seedKingPotFromLaunchCurve succeeded for an actor");
    }

    /// @notice SP-30: a max free TWAMM order (`uint128.max`, 1 s) / max native limit order followed by an honest small
    ///         order in the same direction / bucket. Both run in reverting probes, so the grief never persists.
    function hookRigOrchestrator_accumulatorGrief(uint256 poolSeed, int24 nativeTick) public tracked {
        uint256 idx = _poolIdx(poolSeed);
        bool zeroForOne = (poolSeed >> 8) % 2 == 0;
        int24 tick = (int24(clampBetween(int256(nativeTick), -887_220, 887_220)) / 60) * 60;
        _setCallContext(CallKind.OTHER, actor, idx, address(0));
        property_SP30_accumulatorGrief(
            _runGriefProbe(idx, zeroForOne, tick, false), "SP-30: max free TWAMM order blocked an honest TWAMM order"
        );
        property_SP30_accumulatorGrief(
            _runGriefProbe(idx, zeroForOne, tick, true), "SP-30: max free native limit order blocked an honest order"
        );
    }

    /// @notice Stateless SP-30 probe: always reverts with the abi-encoded outcome (only callable by this contract).
    function fizz_probeAccumulatorGrief(uint256 idx, bool zeroForOne, int24 tick, bool native) external {
        if (msg.sender != address(this)) return;
        uint8 status = native ? _probeNativeBucket(tick) : _probeTwamm(idx, zeroForOne);
        bytes memory ret = abi.encode(status);
        assembly ("memory-safe") {
            revert(add(ret, 32), mload(ret))
        }
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function hookRigOrchestrator_cancelLimitOrder(PoolKey memory key, uint256 orderId) public tracked {
        _settleOrder(key, orderId, false, false);
    }

    function hookRigOrchestrator_claimKingPot(bytes32 poolId, uint64 roundId, address to) public tracked {
        _claimKingAs(actor, PoolId.wrap(poolId), roundId, to, false);
    }

    function hookRigOrchestrator_claimLimitOrder(PoolKey memory key, uint256 orderId) public tracked {
        _settleOrder(key, orderId, true, false);
    }

    function hookRigOrchestrator_finalizeExpiredKingRound(bytes32 poolId) public tracked asActor {
        (, uint256 idx) = _findPoolIdx(PoolId.wrap(poolId));
        _setCallContext(CallKind.FINALIZE_KING, actor, idx, address(0));
        orchestrator.finalizeExpiredKingRound(PoolId.wrap(poolId));
    }

    function hookRigOrchestrator_placeLimitOrder(
        PoolKey memory key,
        int24 targetTick,
        bool zeroForOne,
        uint128 inputAmount
    ) public tracked {
        _setCallContext(CallKind.PLACE_ORDER, actor, 0, address(0));
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        uint256 balBefore = _currencyBalance(inputCurrency, actor);
        uint256 hookBefore = _currencyBalance(inputCurrency, address(orchestrator));
        vm.prank(actor);
        uint256 orderId = orchestrator.placeLimitOrder(key, targetTick, zeroForOne, inputAmount);
        uint256 balAfter = _currencyBalance(inputCurrency, actor);
        uint256 hookAfter = _currencyBalance(inputCurrency, address(orchestrator));

        TrackedOrder storage order = trackedOrders.push();
        order.id = orderId;
        order.key = key;
        order.maker = actor;
        order.targetTick = targetTick;
        order.zeroForOne = zeroForOne;
        order.inputAmount = inputAmount;
        order.inputCurrency = inputCurrency;
        order.paid = balBefore > balAfter ? balBefore - balAfter : 0;
        order.placeTick = _currentTick(key);
        order.minTickSeen = order.placeTick;
        order.maxTickSeen = order.placeTick;
        order.limitsEnabled =
            (orchestrator.getPoolEnabledBlocks(key.toId()) & HookPermissionMasks.BIT_LIMIT_ORDERS) != 0;

        property_SP03_limitOrderPlaceEscrow(
            hookAfter > hookBefore ? hookAfter - hookBefore : 0, order.paid, inputAmount
        );
    }

    function hookRigOrchestrator_registerReferrer(bytes32 poolId, address referrer) public tracked asActor {
        (, uint256 idx) = _findPoolIdx(PoolId.wrap(poolId));
        _setCallContext(CallKind.REGISTER_REFERRER, actor, idx, referrer);
        orchestrator.registerReferrer(PoolId.wrap(poolId), referrer);
    }

    function hookRigOrchestrator_withdrawClaim(bytes32 poolId, address currency, uint256 amount, address to)
        public
        tracked
    {
        _withdrawClaimAs(actor, PoolId.wrap(poolId), Currency.wrap(currency), amount, to, false);
    }

    /// @notice withdrawClaim as `claimant` with its SP-01 checks; `mustSucceed` turns a revert into an SP-01 failure.
    function _withdrawClaimAs(
        address claimant,
        PoolId poolId,
        Currency currency,
        uint256 amount,
        address to,
        bool mustSucceed
    ) internal {
        WithdrawObs memory w = _withdrawObsBefore(claimant, poolId, currency, amount, to);
        _setCallContext(CallKind.WITHDRAW_CLAIM, claimant, w.poolIdx, to);
        ghosts.lastCallWasWithdraw = true;

        vm.prank(claimant);
        if (mustSucceed) {
            try orchestrator.withdrawClaim(poolId, currency, amount, to) {}
            catch {
                property_SP01_fullWithdrawLive(false);
                return;
            }
        } else {
            orchestrator.withdrawClaim(poolId, currency, amount, to);
        }
        snapshotAfter();

        w.claimAfter = orchestrator.poolClaims(poolId, currency, claimant);
        w.hook6909After = _hook6909(currency);
        w.toAfter = _currencyBalance(currency, to);
        property_SP01_withdrawClaimExact(w);
    }

    function _withdrawObsBefore(address claimant, PoolId poolId, Currency currency, uint256 amount, address to)
        internal
        view
        returns (WithdrawObs memory w)
    {
        w.poolIdx = type(uint256).max;
        w.side = type(uint256).max;
        (bool found, uint256 idx) = _findPoolIdx(poolId);
        if (found) {
            w.poolIdx = idx;
            if (poolKeys[idx].currency0 == currency) w.side = 0;
            else if (poolKeys[idx].currency1 == currency) w.side = 1;
        }
        w.claimantIdx = _claimantIdx(claimant);
        w.amount = amount;
        w.claimBefore = orchestrator.poolClaims(poolId, currency, claimant);
        w.hook6909Before = _hook6909(currency);
        w.to = to;
        w.toBefore = _currencyBalance(currency, to);
    }

    /// @notice claimKingPot as `caller` with its SP-02 checks; `mustSucceed` turns a revert into an SP-02 failure.
    function _claimKingAs(address caller, PoolId poolId, uint64 roundId, address to, bool mustSucceed) internal {
        (, uint256 idx) = _findPoolIdx(poolId);
        _setCallContext(CallKind.CLAIM_KING, caller, idx, to);
        ghosts.lastCallWasWithdraw = true;

        KingClaimObs memory k;
        k.pid = poolId;
        k.roundId = roundId;
        k.caller = caller;
        k.to = to;
        k.settled = orchestrator.settledKingRound(poolId, roundId);
        k.ghostClaimed = ghosts.kingClaimed[poolId][roundId];
        bool settledBefore = k.settled.amount > 0;
        k.cur6909Before = _hook6909(k.settled.currency);
        k.toBefore = _currencyBalance(k.settled.currency, to);

        vm.prank(caller);
        if (mustSucceed) {
            try orchestrator.claimKingPot(poolId, roundId, to) {}
            catch {
                property_SP02_winnerClaimLive(false);
                return;
            }
        } else {
            orchestrator.claimKingPot(poolId, roundId, to);
        }
        snapshotAfter();
        ghosts.kingClaimed[poolId][roundId] = true;

        if (!settledBefore) {
            // The round was finalized inside this call (`validateAndMarkClaimed` rolls first): use the new record
            k.settled = orchestrator.settledKingRound(poolId, roundId);
            k.settled.claimed = false;
            uint256 c = _currencyIdx(k.settled.currency);
            if (c >= stateBefore.nCurrencies) return;
            k.cur6909Before = stateBefore.hook6909[c];
            k.to = address(poolManager); // recipient balance before is unknown: skip that clause
        }
        k.cur6909After = _hook6909(k.settled.currency);
        k.toAfter = _currencyBalance(k.settled.currency, to);
        property_SP02_kingPayoutExact(k);
    }

    /// @notice Cancel / claim with SP-03 / SP-28 checks. `honest` (clamped makers) catches the revert and only allows
    ///         the bucket-state error; otherwise reverts propagate.
    function _settleOrder(PoolKey memory key, uint256 orderId, bool claim, bool honest) internal {
        _setCallContext(claim ? CallKind.CLAIM_ORDER : CallKind.CANCEL_ORDER, actor, 0, address(0));
        SettleObs memory o;
        (o.tracked, o.idx) = _findTrackedOrder(orderId);
        o.tracked = o.tracked && trackedOrders[o.idx].maker == actor;
        if (o.tracked) {
            TrackedOrder storage order = trackedOrders[o.idx];
            o.inBefore = _currencyBalance(order.inputCurrency, actor);
            o.outBefore = _currencyBalance(order.zeroForOne ? order.key.currency1 : order.key.currency0, actor);
        }

        if (!_callSettle(key, orderId, claim, honest)) return;
        _markOrderClosed(orderId);
        if (!o.tracked) return;

        TrackedOrder storage settled = trackedOrders[o.idx];
        uint256 inAfter = _currencyBalance(settled.inputCurrency, actor);
        property_SP03_limitOrderRefundBounded(
            inAfter > o.inBefore ? inAfter - o.inBefore : 0,
            settled.paid,
            !claim && !settled.inputCurrency.isAddressZero()
        );
        if (claim) {
            property_SP28_filledOrderPaysOutput(
                o.outBefore, _currencyBalance(settled.zeroForOne ? settled.key.currency1 : settled.key.currency0, actor)
            );
        }
    }

    function _callSettle(PoolKey memory key, uint256 orderId, bool claim, bool honest) internal returns (bool) {
        vm.prank(actor);
        if (!honest) {
            if (claim) orchestrator.claimLimitOrder(key, orderId);
            else orchestrator.cancelLimitOrder(key, orderId);
            return true;
        }
        if (claim) {
            try orchestrator.claimLimitOrder(key, orderId) {
                return true;
            } catch (bytes memory err) {
                property_SP03_honestSettleRevert(_revertSelector(err), LimitOrdersLogic.BucketNotYetFilled.selector);
                return false;
            }
        }
        try orchestrator.cancelLimitOrder(key, orderId) {
            return true;
        } catch (bytes memory err) {
            property_SP03_honestSettleRevert(_revertSelector(err), LimitOrdersLogic.BucketAlreadyFilled.selector);
            return false;
        }
    }

    function _hookRigOrchestrator_registerPoolStack(PoolKey memory key, IHookRigBlock.PoolStackConfig memory config)
        internal
        asActor
    {
        orchestrator.registerPoolStack(key, config);
    }

    function _hookRigOrchestrator_setAccessMerkleRoot(address caller, bytes32 poolId, bytes32 newRoot) internal {
        vm.prank(caller);
        orchestrator.setAccessMerkleRoot(PoolId.wrap(poolId), newRoot);
    }

    function _hookRigOrchestrator_setAllowlistAccount(address caller, bytes32 poolId, address account, bool allowed)
        internal
    {
        vm.prank(caller);
        orchestrator.setAllowlistAccount(PoolId.wrap(poolId), account, allowed);
    }

    function _hookRigOrchestrator_setManagedPoolFee(address caller, PoolKey memory key, uint24 newFee) internal {
        vm.prank(caller);
        orchestrator.setManagedPoolFee(key, newFee);
    }

    function _hookRigOrchestrator_submitTWAMMOrder(
        PoolKey memory key,
        bool zeroForOne,
        uint128 totalAmount,
        uint64 durationSeconds
    ) internal asActor returns (uint256 orderId) {
        orderId = orchestrator.submitTWAMMOrder(key, zeroForOne, totalAmount, durationSeconds);
    }

    function _hookRigOrchestrator_setTrustedRouter(address router, bool trusted) internal asAdmin {
        orchestrator.setTrustedRouter(router, trusted);
    }

    /// @notice Cancels an active tracked TWAMM order and verifies the unstreamed refund and rate removal (GL-17).
    function hookRigOrchestrator_cancelTWAMMOrder_clamped(uint256 orderSeed) public tracked {
        if (ghosts.twammOrders.length == 0) return;
        TwammOrder storage order = ghosts.twammOrders[orderSeed % ghosts.twammOrders.length];
        if (order.cancelled || order.expiry <= block.timestamp || order.poolIdx >= poolKeys.length) return;
        PoolKey memory key = poolKeys[order.poolIdx];
        Currency inputCurrency = order.zeroForOne ? key.currency0 : key.currency1;
        uint256 balBefore = _currencyBalance(inputCurrency, order.owner);
        _setCallContext(CallKind.OTHER, order.owner, order.poolIdx, address(0));

        vm.prank(order.owner);
        uint256 refund = orchestrator.cancelTWAMMOrder(key, order.id);
        order.cancelled = true;
        uint256 balAfter = _currencyBalance(inputCurrency, order.owner);
        lte(refund, order.total, "TWAMM cancel refunded more than totalAmount");
        eq(balAfter - balBefore, refund, "TWAMM cancel balance credit != refundAmount");
    }

    /// @notice Updates buy/sell tax on a pool (exercising poolAdmin auth, decayOnly enforcement, and SP-23/SP-26).
    function hookRigOrchestrator_setBuySellTax_clamped(
        uint256 poolSeed,
        uint16 newBuyTaxBps,
        uint16 newSellTaxBps,
        address newRecipient
    ) public tracked {
        uint256 idx = _poolIdx(poolSeed);
        PoolId pid = poolKeys[idx].toId();
        address expectedAdmin = ghosts.poolAdmin[idx];
        address caller = poolSeed % 4 == 0 ? actor : expectedAdmin;
        if (caller == address(0)) caller = actor;
        address recipient = idx == POOL_XYK ? actors[1] : toActor(newRecipient);
        uint16 curBuy = ghosts.cfgBps[idx][0];
        uint16 curSell = ghosts.cfgBps[idx][1];
        // 75% of the time clamp within decayOnly bounds; 25% of the time allow higher bps to exercise revert guards
        if ((poolSeed >> 8) % 4 != 0) {
            newBuyTaxBps = uint16(clampLte(newBuyTaxBps, curBuy));
            newSellTaxBps = uint16(clampLte(newSellTaxBps, curSell));
        } else {
            newBuyTaxBps = uint16(clampLte(newBuyTaxBps, 1200));
            newSellTaxBps = uint16(clampLte(newSellTaxBps, 1200));
        }
        _setCallContext(CallKind.OTHER, caller, idx, recipient);

        vm.prank(caller);
        orchestrator.setBuySellTax(pid, newBuyTaxBps, newSellTaxBps, recipient);
        ghosts.cfgBps[idx][0] = newBuyTaxBps;
        ghosts.cfgBps[idx][1] = newSellTaxBps;
        property_SP23_noPrivilegeEscalation(
            caller == expectedAdmin, "SP-23: setBuySellTax succeeded for a non-poolAdmin"
        );
    }

    /// @notice Exercises view getters, preset hooks, bitmap validations, and reverting block guard paths.
    function hookRigOrchestrator_exerciseCoverage(uint8 branch) public {
        coverageHelper.run(
            branch,
            poolKeys[POOL_MULTI],
            xykCurves.length > 0 ? address(xykCurves[0]) : address(0),
            trancheCurves.length > 0 ? address(trancheCurves[0]) : address(0),
            launchTokens.length > 0 ? launchTokens[0] : address(0)
        );
    }

    // ――――――――――――――――――――― Secondary clamping ―――――――――――――――――――――

    /// @notice Registers a fuzzed (cap-respecting) stack on an existing pool (usually POOL_UNREGISTERED, which is
    ///         already live) or on a fresh key that is then initialized and seeded so it becomes swappable.
    function _registerPoolStack_clamped(uint256 targetSeed, uint256 bitmapSeed, uint256 paramSeed) internal {
        PoolKey memory key;
        bool fresh = targetSeed % 3 == 0 && poolKeys.length < MAX_FUZZ_POOLS;
        if (fresh) {
            int24 spacing = int24(int256(clampBetween(targetSeed >> 8, 1, 200)));
            key = _standardKey(LPFeeLibrary.DYNAMIC_FEE_FLAG, spacing);
        } else {
            key = poolKeys[targetSeed % 2 == 0 ? POOL_UNREGISTERED : _poolIdx(targetSeed >> 8)];
        }
        _setCallContext(CallKind.REGISTER_STACK, actor, 0, address(0));

        IHookRigBlock.PoolStackConfig memory cfg = _fuzzStackConfig(bitmapSeed, paramSeed);
        (uint160 sqrtPriceBefore,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        _hookRigOrchestrator_registerPoolStack(key, cfg);

        bool pushed;
        if (fresh && sqrtPriceBefore == 0) {
            poolManager.initialize(key, SQRT_PRICE_1_1);
            int24 spacing = key.tickSpacing;
            _seedLiquidity(key, (-6000 / spacing) * spacing, (6000 / spacing) * spacing, 1_000_000 ether);
            poolKeys.push(key);
            poolCurves.push(address(0));
            pushed = true;
        }
        (bool found, uint256 idx) = _findPoolIdx(key.toId());
        if (found) _recordStackGhosts(idx, key.toId(), cfg, pushed);

        property_SP19_noRetroRegistration(sqrtPriceBefore);
    }

    function _setAccessMerkleRoot_clamped(uint256 poolSeed, uint256 callerSeed, bytes32 newRoot) internal {
        uint256 idx = _poolIdx(poolSeed);
        address caller = callerSeed % 2 == 0 ? actors[2] : actor;
        _setCallContext(CallKind.SET_MERKLE_ROOT, caller, idx, address(0));
        _hookRigOrchestrator_setAccessMerkleRoot(caller, PoolId.unwrap(poolKeys[idx].toId()), newRoot);
        if (newRoot != bytes32(0)) ghosts.merkleRootSet[idx] = true;
        property_SP23_noPrivilegeEscalation(
            caller == ghosts.acManager[idx], "SP-23: setAccessMerkleRoot succeeded for a non-manager"
        );
    }

    function _setAllowlistAccount_clamped(uint256 poolSeed, uint256 callerSeed, address account, bool allowed)
        internal
    {
        uint256 idx = _poolIdx(poolSeed);
        address caller = callerSeed % 2 == 0 ? actors[2] : actor;
        address target = toActor(account);
        _setCallContext(CallKind.SET_ALLOWLIST, caller, idx, target);
        _hookRigOrchestrator_setAllowlistAccount(caller, PoolId.unwrap(poolKeys[idx].toId()), target, allowed);
        property_SP23_noPrivilegeEscalation(
            caller == ghosts.acManager[idx], "SP-23: setAllowlistAccount succeeded for a non-manager"
        );
    }

    function _setManagedPoolFee_clamped(uint256 poolSeed, uint256 newFee) internal {
        uint256 idx = _poolIdx(poolSeed);
        address caller = poolSeed % 4 == 0 ? actor : actors[1];
        _setCallContext(CallKind.SET_MANAGED_FEE, caller, idx, address(0));
        // 1.5x the managed cap so the cap guard is exercised too
        _hookRigOrchestrator_setManagedPoolFee(caller, poolKeys[idx], uint24(clampLte(newFee, 75_000)));
        property_SP23_noPrivilegeEscalation(
            caller == ghosts.feeManager[idx], "SP-23: setManagedPoolFee succeeded for a non-manager"
        );
    }

    function _submitTWAMMOrder_clamped(uint256 poolSeed, bool zeroForOne, uint256 totalAmount, uint256 duration)
        internal
    {
        uint256 idx = _poolIdx(poolSeed);
        uint64 durationSeconds = uint64(clampBetween(duration, 1, 30 days));
        uint128 amount = uint128(clampBetween(totalAmount, durationSeconds, MAX_ORDER_AMOUNT));
        _setCallContext(CallKind.SUBMIT_TWAMM, actor, idx, address(0));
        uint256 orderId = _hookRigOrchestrator_submitTWAMMOrder(poolKeys[idx], zeroForOne, amount, durationSeconds);

        // GL-17: `rate = floor(total / duration)` (`TWAMMBlock.sol:54`)
        ghosts.twammOrders
            .push(
                TwammOrder({
                    id: orderId,
                    owner: actor,
                    poolIdx: idx,
                    zeroForOne: zeroForOne,
                    rate: uint128(amount / durationSeconds),
                    expiry: uint64(block.timestamp) + durationSeconds,
                    total: amount,
                    cancelled: false
                })
            );
        ghosts.twammSubmitted[poolKeys[idx].toId()][zeroForOne] += amount;
    }

    function _setTrustedRouter_clamped(uint256 routerSeed, address arbitraryRouter, bool trusted) internal {
        uint256 r = routerSeed % 3;
        address router = r == 0 ? address(plainRouter) : r == 1 ? address(trustedRouter) : arbitraryRouter;
        _setCallContext(CallKind.SET_TRUSTED_ROUTER, admin, 0, router);
        _hookRigOrchestrator_setTrustedRouter(router, trusted);
        property_SP23_noPrivilegeEscalation(
            admin == orchestrator.owner(), "SP-23: setTrustedRouter succeeded for a non-owner"
        );
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    /// @notice Records the per-pool configuration ghosts after a successful fuzz registration (GL-22, SP-15..SP-26).
    function _recordStackGhosts(uint256 idx, PoolId pid, IHookRigBlock.PoolStackConfig memory cfg, bool initialized)
        internal
    {
        uint32 bm = orchestrator.getPoolEnabledBlocks(pid);
        ghosts.registeredAtBlock[idx] = block.number;
        ghosts.poolAdmin[idx] = cfg.poolAdmin != address(0) ? cfg.poolAdmin : actor;
        ghosts.acManager[idx] = cfg.accessControl.manager;
        ghosts.acChecks[idx] =
            (cfg.accessControl.checkBeforeSwap ? 1 : 0) | (cfg.accessControl.checkBeforeAddLiquidity ? 2 : 0);
        ghosts.feeManager[idx] = cfg.managedFee.manager;
        uint24 cap = cfg.managedFee.feeCap;
        ghosts.feeCap[idx] = cap == 0 || cap > MAX_MANAGED_FEE_CAP ? MAX_MANAGED_FEE_CAP : cap;
        uint32 hold = cfg.mevProtection.minLPHoldBlocks;
        bool jit = (bm & (HookPermissionMasks.BIT_MEV_PROTECTION | HookPermissionMasks.BIT_JIT_GUARD)) != 0;
        ghosts.minHold[idx] = jit ? (hold > MAX_LP_HOLD_BLOCKS ? MAX_LP_HOLD_BLOCKS : hold) : 0;
        if ((bm & HookPermissionMasks.BIT_VESTING_SELL_CAP) != 0) {
            ghosts.vestingMaxBps[idx] = cfg.vestingSellCap.maxDailySellBps;
        }
        if ((bm & HookPermissionMasks.BIT_WALLET_CAP) != 0) ghosts.walletCapCfg[idx] = cfg.walletCap;
        ghosts.cfgBps[idx] = [
            (bm & HookPermissionMasks.BIT_BUY_SELL_TAX) != 0 ? cfg.buySellTax.buyTaxBps : 0,
            (bm & HookPermissionMasks.BIT_BUY_SELL_TAX) != 0 ? cfg.buySellTax.sellTaxBps : 0,
            (bm & HookPermissionMasks.BIT_FEE_SHARING) != 0 ? cfg.feeSharing.feeShareBps : 0,
            (bm & HookPermissionMasks.BIT_REFERRAL_SPLIT) != 0 ? cfg.referralSplit.referralFeeBps : 0
        ];
        if (initialized) ghosts.lastOracleTouch[idx] = block.timestamp; // oracle (if any) initialized in this call
    }

    /// @notice Clamps a limit order to a tick near the current one and an amount the actor can fund.
    function _clampOrder(uint256 poolSeed, int24 tickOffset, bool zeroForOne, uint128 inputAmount, bool nativeKey)
        internal
        returns (bool ok, PoolKey memory key, int24 targetTick, uint128 amount)
    {
        key = nativeKey ? nativeOrderKey : poolKeys[_poolIdx(poolSeed)];
        int24 spacing = key.tickSpacing;
        int24 offset = int24(clampBetween(int256(tickOffset), -20, 20));
        targetTick = (_currentTick(key) / spacing + offset) * spacing;

        if (!key.currency0.isAddressZero() || !zeroForOne) {
            address input = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
            uint256 balance = MockBurnableERC20(input).balanceOf(actor);
            if (balance == 0) return (false, key, targetTick, 0);
            amount = uint128(clampBetween(inputAmount, 1, balance < MAX_ORDER_AMOUNT ? balance : MAX_ORDER_AMOUNT));
        } else {
            amount = uint128(clampBetween(inputAmount, 1, MAX_ORDER_AMOUNT));
        }
        ok = true;
    }

    /// @notice Builds a registration config whose every cut is ≤ FUZZ_CUT_BPS_MAX so the aggregate check passes,
    ///         with recipients/managers drawn from actors (third-party registration of someone else's pool).
    function _fuzzStackConfig(uint256 bitmapSeed, uint256 p)
        internal
        returns (IHookRigBlock.PoolStackConfig memory cfg)
    {
        cfg.enabledBlocksBitmap = uint32(clampBetween(bitmapSeed, 1, (uint256(1) << 22) - 1));
        // Half the time register a compiled preset (bitmap resolved by HookPermissionMasks.getPresetBitmap)
        if ((bitmapSeed >> 24) % 2 == 0) {
            cfg.presetId = IHookRigBlock.PresetId(uint8((bitmapSeed >> 25) % 13));
        }
        address recipient = toActor(address(uint160(p)));
        uint16 bps = uint16(p % (FUZZ_CUT_BPS_MAX + 1));

        cfg.poolAdmin = actor;
        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 2000, maxFee: 10_000, volatilityTickThreshold: 50});
        cfg.managedFee = IHookRigBlock.ManagedFeeParams({startingFee: 2500, feeCap: 15_000, manager: actor});
        cfg.marketHoursFee = IHookRigBlock.MarketHoursFeeParams({
            openHourUtc: 13, closeHourUtc: 20, openFee: 1500, closedFee: 4000, weekendClosed: true
        });
        cfg.antiSnipe = IHookRigBlock.AntiSnipeParams({
            launchFee: uint24(clampBetween(p >> 16, 2000, 800_000)), normalFee: 2000, decayBlocks: 10
        });
        cfg.mevProtection = IHookRigBlock.MEVProtectionParams({
            maxTickDeltaPerSwap: int24(int256(clampBetween(p >> 40, 0, 5000))),
            minLPHoldBlocks: uint32(clampLte(p >> 56, 10_000)),
            jitExitPenaltyBps: 0
        });
        cfg.arbRecapture = IHookRigBlock.ArbRecaptureParams({
            recaptureShareBps: uint16(clampLte(p >> 72, 8000)), arbTriggerTickDelta: 10
        });
        cfg.accessControl = IHookRigBlock.AccessControlParams({
            checkBeforeAddLiquidity: (p >> 88) % 2 == 0,
            checkBeforeSwap: (p >> 89) % 2 == 0,
            merkleRoot: bytes32(0),
            manager: actor
        });
        cfg.walletCap =
            IHookRigBlock.WalletCapParams({maxWalletBps: uint16(clampBetween(p >> 90, 10, 10_000)), sunsetBlocks: 100});
        cfg.buySellTax =
            IHookRigBlock.BuySellTaxParams({buyTaxBps: bps, sellTaxBps: bps, taxRecipient: recipient, decayOnly: true});
        cfg.autoBurn = IHookRigBlock.AutoBurnParams({burnOnBuyBps: bps, useTokenBurnCall: (p >> 106) % 2 == 0});
        cfg.feeSharing = IHookRigBlock.FeeSharingParams({
            feeShareBps: bps, primaryRecipient: recipient, secondaryRecipient: TREASURY, secondaryShareBps: 5000
        });
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: bps});
        cfg.swapRewards = IHookRigBlock.SwapRewardsParams({pointsPerUnitVolume: 1e18});
        cfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: bps, roundDurationSeconds: 600, minBuyAmountForReset: 1 ether
        });
        cfg.circuitBreaker = IHookRigBlock.CircuitBreakerParams({
            maxWindowTickDeviation: int24(int256(clampBetween(p >> 107, 1, 5000))), windowSeconds: 300
        });
        cfg.referralSplit = IHookRigBlock.ReferralSplitParams({referralFeeBps: bps});
        cfg.vestingSellCap =
            IHookRigBlock.VestingSellCapParams({maxDailySellBps: uint16(clampBetween(p >> 123, 50, 10_000))});
        cfg.autoBuyback =
            IHookRigBlock.AutoBuybackParams({buybackFeeBps: bps, triggerFloorTick: -50, minBuybackReserve: 1 ether});
    }

    /// @notice Runs a SP-30 probe in a reverting self-call and decodes its outcome.
    function _runGriefProbe(uint256 idx, bool zeroForOne, int24 tick, bool native) internal returns (uint8) {
        try this.fizz_probeAccumulatorGrief(idx, zeroForOne, tick, native) {}
        catch (bytes memory ret) {
            if (ret.length == 32) return abi.decode(ret, (uint8));
        }
        return PROBE_ATTACK_FAILED;
    }

    function _probeTwamm(uint256 idx, bool zeroForOne) internal returns (uint8) {
        PoolKey memory key = poolKeys[idx];
        vm.prank(actor);
        try orchestrator.submitTWAMMOrder(key, zeroForOne, type(uint128).max, 1) {}
        catch {
            return PROBE_ATTACK_FAILED;
        }
        vm.prank(toActorNotCurrent(address(0)));
        try orchestrator.submitTWAMMOrder(key, zeroForOne, 1 ether, 3600) {
            return PROBE_HONEST_OK;
        } catch {
            return PROBE_HONEST_FAILED;
        }
    }

    function _probeNativeBucket(int24 tick) internal returns (uint8) {
        PoolKey memory key = nativeOrderKey;
        vm.prank(actor);
        try orchestrator.placeLimitOrder(key, tick, true, type(uint128).max) {}
        catch {
            return PROBE_ATTACK_FAILED;
        }
        vm.prank(toActorNotCurrent(address(0)));
        try orchestrator.placeLimitOrder(key, tick, true, 1 ether) {
            return PROBE_HONEST_OK;
        } catch {
            return PROBE_HONEST_FAILED;
        }
    }

    function _currentTick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(poolManager, key.toId());
    }

    function _findTrackedOrder(uint256 orderId) internal view returns (bool found, uint256 idx) {
        for (uint256 i; i < trackedOrders.length; i++) {
            if (trackedOrders[i].id == orderId) return (true, i);
        }
    }

    function _markOrderClosed(uint256 orderId) internal {
        for (uint256 i; i < trackedOrders.length; i++) {
            if (trackedOrders[i].id == orderId) {
                trackedOrders[i].closed = true;
                return;
            }
        }
    }
}
