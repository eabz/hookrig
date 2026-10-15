STATE TRANSITION MAPPER: PROPERTY LIST (HookRig fizz Step 9b, agent #3)

Notation for all properties:
- P = poolKeys[i].toId() for i < poolKeys.length.
- C = trackedCurrencies.
- A = claimants (actors, admin, TREASURY).
- TRADERS = actors ∪ {address(plainRouter), address(trustedRouter)}. These are every identity _resolveUser can return in this harness.
- B/A = stateBefore/stateAfter from Snapshots.
- "Live" = _isPoolLive(i).

Snapshot arrays are indexed by pool index and stay bounded: at most 12 fuzz pools plus 8 launches.

=====================================================================
A. POOL REGISTRATION / BITMAP STATE MACHINE
=====================================================================

PROPERTY_ID: [ST-01]
TYPE: GLOBAL (B/A on every handler)
ENGLISH: Once a pool's enabled-blocks bitmap is non-zero, it never changes. Registration is one-shot and the bitmap is locked.
SOLIDITY_SKETCH: for i: if (B.bitmap[i] != 0) assertEq(A.bitmap[i], B.bitmap[i]); // bitmap = orchestrator.getPoolEnabledBlocks(P)
GHOST_NEEDS: none
SNAPSHOT_NEEDS: uint32[] bitmap (per pool index)
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 AV-07: registerPoolStack "reverts ... on any subsequent call". Code: `if (_poolMeta[poolId].configured) revert PoolAlreadyConfigured` (HookRigOrchestrator.sol:81). invariant-context: "Bitmap locked at registration".
RATIONALE: The fuzzer re-registers POOL_UNREGISTERED, existing pools, presets and launch keys. Any overwrite would let someone reconfigure taxes or recipients mid-life.

PROPERTY_ID: [ST-02]
TYPE: SPECIFIC (after _registerPoolStack_clamped succeeds)
ENGLISH: A successful registration moves the bitmap from 0 to non-zero. If presetId != Blank, the bitmap equals HookPermissionMasks.getPresetBitmap(presetId); otherwise it equals cfg.enabledBlocksBitmap. No other pool's bitmap changes.
SOLIDITY_SKETCH: assertEq(B.bitmap[target], 0); uint32 exp = cfg.presetId==Blank ? cfg.enabledBlocksBitmap : HookPermissionMasks.getPresetBitmap(cfg.presetId); assertEq(A.bitmap[target], exp); for j != target: assertEq(A.bitmap[j], B.bitmap[j]);
GHOST_NEEDS: lastRegisteredCfgBitmap / lastRegisteredPreset, recorded in the handler.
SNAPSHOT_NEEDS: bitmap[]
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: HookRigOrchestrator.sol:108-133 (bitmap resolution, `if (bitmap == 0) revert InvalidBlockBitmap`). docs/06 AV-07.
RATIONALE: Pattern A/B for registration. It also catches cross-pool writes, which docs/02 4.2 rules out ("No block ever uses global state").

PROPERTY_ID: [VS-01]
TYPE: GLOBAL
ENGLISH: A pool with bitmap == 0 has no hook-side economic state: no claims, no King round, no burns, no LP donations and no swap points. Swaps on POOL_UNREGISTERED before registration must leave the hook ledger untouched.
SOLIDITY_SKETCH: for i with bitmap[i]==0: for c in C, a in A: assertEq(orchestrator.poolClaims(P,c,a),0); (uint64 r,address k,uint256 pot,) = orchestrator.getCurrentKing(P); assertEq(r,0); assertEq(k,address(0)); assertEq(pot,0); assertEq(orchestrator.totalLPRewardsDonated(P),0); assertEq(orchestrator.totalAutoBurnedByPool(P),0); assertEq(orchestrator.totalPoolSwapPoints(P),0);
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none (direct reads)
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: All block paths are gated by `(bitmap & BIT_x) != 0` and AFTER_SWAP_RETURN_DELTA_BLOCKS_MASK (AfterSwapDeltaAggregator.sol:536). docs/02 4.2 per-pool isolation.
RATIONALE: Biconditional between configuration and accumulated state. Catches stray writes from another pool or a stale context.

PROPERTY_ID: [VS-02]
TYPE: GLOBAL
ENGLISH: Accumulators only move for pools whose bitmap enables the matching block.
SOLIDITY_SKETCH: for i: if (!(bitmap & BIT_AUTO_BURN)) assertEq(totalAutoBurnedByPool(P),0); if (!(bitmap & (BIT_LP_REWARDS|BIT_ARB_RECAPTURE|BIT_AUTO_BUYBACK))) assertEq(totalLPRewardsDonated(P),0); if (!(bitmap & BIT_SWAP_REWARDS)) assertEq(totalPoolSwapPoints(P),0); if (!(bitmap & BIT_KING_OF_THE_POOL)) { (r,k,pot,)=getCurrentKing(P); assertEq(pot,0); assertEq(k,address(0)); }
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: Bitmap gating at every write site (AfterSwapDeltaAggregator.sol:546-662; HookRigOrchestrator.sol:403, 432). seedKingPotFromLaunchCurve sends seeds to admin claims when the King bit is off (:432-439).
RATIONALE: Flag-data synchronisation (Pattern G).

PROPERTY_ID: [VS-03]
TYPE: GLOBAL
ENGLISH: Hook-side poolClaims can be non-zero only on pools whose bitmap includes BUY_SELL_TAX, FEE_SHARING or REFERRAL_SPLIT, or on SteppedTranche launch pools (graduation seed fallback to poolAdmin).
SOLIDITY_SKETCH: for i: bool claimable = bitmap & (BIT_BUY_SELL_TAX|BIT_FEE_SHARING|BIT_REFERRAL_SPLIT) != 0 || _isTranchePool(i); if (!claimable) for c,a: assertEq(poolClaims(P,c,a),0);
GHOST_NEEDS: none. The helper _isTranchePool(i) checks whether poolCurves[i] is in trancheCurves.
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none, inferred (only writers: _creditPoolClaim from tax/fee-share/referral, and seedKingPotFromLaunchCurve).
RATIONALE: Detects phantom claim creation from unexpected paths.

=====================================================================
B. CLAIMS LEDGER POSTCONDITIONS
=====================================================================

PROPERTY_ID: [ST-03]
TYPE: SPECIFIC (after withdrawClaim_clamped / withdrawClaim_full / unclamped withdrawClaim)
ENGLISH: withdrawClaim(p, c, amount) by claimant X lowers exactly poolClaims[p][c][X] by `amount`. Every other (pool, currency, account) entry is unchanged. The hook's ERC-6909 balance of c drops by exactly `amount`.
SOLIDITY_SKETCH: assertEq(A.claims[p][c][X], B.claims[p][c][X] - amount); for (p',c',a') != (p,c,X): assertEq(A.claims[p'][c'][a'], B.claims[p'][c'][a']); assertEq(A.hook6909[c], B.hook6909[c] - amount); // hook6909[c] = poolManager.balanceOf(address(orchestrator), c.toId())
GHOST_NEEDS: lastWithdraw {poolIdx, currencyIdx, claimant, amount}
SNAPSHOT_NEEDS: claims[pool][currency][claimant] (3-D, bounded: ≤20×(2+8)×5); hook6909[currency]
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 AV-01 and docs/02 4.2: claims "double-keyed per pool". HookRigBase.withdrawClaim (`poolClaims[...][msg.sender] = available - amount`) plus unlockCallback burn(amount).
RATIONALE: Pattern A+B. Per-pool isolation is the stated guarantee, and the shared hook-wide ERC-6909 balance is where cross-pool leakage would show up.

PROPERTY_ID: [VT-01]
TYPE: GLOBAL (B/A on every handler that is not a withdraw)
ENGLISH: No handler other than withdrawClaim decreases any poolClaims entry. Claims are pull-only and never clawed back.
SOLIDITY_SKETCH: if (!lastCallWasWithdraw) for p,c,a: assertGe(A.claims[p][c][a], B.claims[p][c][a]);
GHOST_NEEDS: bool lastCallWasWithdraw
SNAPSHOT_NEEDS: claims[][][]
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: invariant-context: "Claims are pull-based: withdrawClaim / claimKingPot burn ... and take". The only decrementing writer is HookRigBase.sol withdrawClaim.
RATIONALE: Monotonicity of the per-account ledger.

PROPERTY_ID: [ST-04]
TYPE: SPECIFIC (after any pool_swap* on pool p)
ENGLISH: A swap credits claims only to configured beneficiaries of that same pool: taxRecipient, the fee-sharing primary and secondary, or traderReferrer[p][trader]. Claims of every other pool are unchanged. For POOL_MULTI that means only actors[1] (tax), actors[2] and TREASURY (fee share), or the registered referrer of the resolved trader.
SOLIDITY_SKETCH: for p' != p: claims unchanged; for c,a: if (A.claims[p][c][a] > B.claims[p][c][a]) assertTrue(isConfiguredBeneficiary(p,a) || a == orchestrator.traderReferrer(P,resolvedTrader));
GHOST_NEEDS: per-pool beneficiary set recorded at registration (setup pools are hard-coded; fuzz registrations store recipient and TREASURY); resolvedTrader for the swap (actor / spoofed actor / router per routeMode).
SNAPSHOT_NEEDS: claims[][][]
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none, inferred
RATIONALE: Pattern B. Catches misrouted credits, credits landing under the wrong pool key, and spoof-driven referral credits.

=====================================================================
C. KING OF THE POOL STATE MACHINE
=====================================================================

PROPERTY_ID: [VT-02]
TYPE: GLOBAL
ENGLISH: King currentRoundId never decreases and advances by at most 1 per handler call. Each call rolls at most once per pool: processBuy, finalizeExpired and claimKingPot each roll at most once, and a swap triggers one afterSwap per pool.
SOLIDITY_SKETCH: for i: assertGe(A.kRound[i], B.kRound[i]); assertLe(A.kRound[i], B.kRound[i] + 1);
GHOST_NEEDS: none
SNAPSHOT_NEEDS: uint64[] kRound, address[] kKing, uint256[] kPot, uint64[] kDeadline (from getCurrentKing)
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: The only writers are initKing (`currentRoundId: 1`, one-shot behind PoolAlreadyConfigured) and _rollKingRound (`currentRoundId = finishedRound + 1`). x-ray I-19.
RATIONALE: Round-id monotonicity backs the uniqueness of settled rounds.

PROPERTY_ID: [ST-05]
TYPE: GLOBAL (B/A)
ENGLISH: A round may roll only if, before the call, block.timestamp >= roundDeadline, currentKing != 0 and pot > 0. The roll must not be premature or empty.
SOLIDITY_SKETCH: if (A.kRound[i] > B.kRound[i]) { assertGe(block.timestamp, B.kDeadline[i]); assertTrue(B.kKing[i] != address(0)); assertGt(B.kPot[i], 0); }
GHOST_NEEDS: none
SNAPSHOT_NEEDS: kRound, kKing, kPot, kDeadline, timestamp
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: Explicit guard in finalizeExpired and processBuy: `if (block.timestamp >= state.roundDeadline && state.currentKing != address(0) && state.currentPotAmount > 0)`. x-ray I-33.
RATIONALE: Valid state transition (Pattern F).

PROPERTY_ID: [ST-06]
TYPE: SPECIFIC (after finalizeExpiredKingRound_clamped / claimKingPot_clamped)
ENGLISH: When a non-swap handler rolls the round, the new round starts empty: king == 0, pot == 0, deadline == block.timestamp + roundDuration (≥ previous deadline).
SOLIDITY_SKETCH: if (A.kRound[i] == B.kRound[i] + 1) { assertEq(A.kKing[i], address(0)); assertEq(A.kPot[i], 0); assertGe(A.kDeadline[i], B.kDeadline[i]); }
GHOST_NEEDS: none
SNAPSHOT_NEEDS: kRound, kKing, kPot, kDeadline
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: _rollKingRound sets currentKing=0, currentPotAmount=0, roundDeadline=now+duration (KingOfThePoolBlock.sol).
RATIONALE: Postcondition of roll. Leftover pot carried into the next round would double-pay.

PROPERTY_ID: [VS-04]
TYPE: GLOBAL
ENGLISH: A crowned king implies a funded pot (currentKing != 0 ⇒ currentPotAmount > 0). The converse need not hold, because a launch-curve seed can fund the pot with no king.
SOLIDITY_SKETCH: for i: (,address k,uint256 pot,) = getCurrentKing(P); if (k != address(0)) assertGt(pot, 0);
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none, inferred (a king is set only in processBuy after potContribution>0; roll zeroes both).
RATIONALE: Flag-data sync. A king with an empty pot means accounting broke.

PROPERTY_ID: [VT-03]
TYPE: GLOBAL (B/A)
ENGLISH: Within one round the pot only grows. If roundId is unchanged, pot_after >= pot_before. Separately, roundDeadline never decreases.
SOLIDITY_SKETCH: if (A.kRound[i] == B.kRound[i]) assertGe(A.kPot[i], B.kPot[i]); assertGe(A.kDeadline[i], B.kDeadline[i]);
GHOST_NEEDS: none
SNAPSHOT_NEEDS: kRound, kPot, kDeadline
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none, inferred (pot changes only via += or roll; deadline = now + constant duration)
RATIONALE: Accumulator monotonicity.

PROPERTY_ID: [ST-07] [MANDATORY: lead #1 / I-3 / X-5]
TYPE: SPECIFIC (after any pool_swap* on a pool with BIT_KING_OF_THE_POOL; after tranche graduation)
ENGLISH: Within a round the pot currency never changes. If a pot already holds amount > 0 in currency X (for example, quote token0 seeded at SteppedTranche graduation), a later swap in the same round must not add a contribution while switching or mixing the currency.
SOLIDITY_SKETCH: ghost.potCurrency[i] is set when the pot goes 0 -> >0 (seed: currency0 when B.kPot==0 at graduation; buy: projectCurrency). After a swap: if (A.kRound[i]==B.kRound[i] && B.kPot[i] > 0 && A.kPot[i] > B.kPot[i]) assertEq(contributionCurrency, ghost.potCurrency[i]); // contributionCurrency is the project currency (exact-in buy). Preferred stronger version with a getter: assertEq(potCurrency_after, potCurrency_before) whenever B.kPot>0 && same round.
GHOST_NEEDS: Currency[] ghostPotCurrency (per pool), set in the tranche buy handler when launchState flips to Graduated and kingPotSeed>0 and B.kPot==0, and in swap handlers when the pot goes 0 -> >0.
SNAPSHOT_NEEDS: kRound, kPot. Optionally potCurrency, which needs a harness getter: _kingStates[poolId].potCurrency is internal, so read it with vm.load on the _kingStates mapping slot.
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 FF-03 and invariant-context: "King pot contributions only in project currency; mismatched seeds to admin claims". FF-03 says overwriting potCurrency while accumulating both currencies freezes the pot.
RATIONALE: processBuy runs `state.potCurrency = cutCurrency; currentPotAmount += potContribution` with no currency check. After graduation (surchargeToKingPotBps=5000) POOL_TRANCHE's pot is seeded in token0, and the first exact-in buy adds project tokens and flips potCurrency. Directly reachable in the harness.

PROPERTY_ID: [ST-08]
TYPE: SPECIFIC (after claimKingPot_clamped succeeds)
ENGLISH: A settled round pays out once. The same (pool, roundId) never succeeds a second time. The hook's ERC-6909 balance of the round currency drops by exactly the reward, and the current round state (king, pot, roundId) changes only by a possible roll.
SOLIDITY_SKETCH: assertFalse(ghost.kingClaimed[poolIdx][roundId]); ghost.kingClaimed[poolIdx][roundId] = true; // also check Σ_c (B.hook6909[c] - A.hook6909[c]) == reward and A.kPot == B.kPot unless rolled
GHOST_NEEDS: mapping(uint256 => mapping(uint64 => bool)) kingClaimed; lastKingReward (decode from the token balance delta of `to`).
SNAPSHOT_NEEDS: hook6909[], kRound, kPot
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: KingOfThePoolLogic.validateAndMarkClaimed: `if (round.amount == 0 || round.claimed) revert RoundNotClaimable`, then `round.claimed = true`. x-ray I-19.
RATIONALE: claimed: false -> true exactly once.

=====================================================================
D. LIMIT ORDERS
=====================================================================

PROPERTY_ID: [ST-09]
TYPE: SPECIFIC (after cancelLimitOrder / claimLimitOrder unclamped and clamped)
ENGLISH: An order closes once. A successful cancel or claim implies the tracked order was open before. Afterwards it is closed and no later cancel or claim on that id succeeds.
SOLIDITY_SKETCH: on success: assertFalse(ghost.orderClosedBefore[id]); ghost.orderClosedBefore[id] = true; // note: the unclamped handlers can target already-closed ids, so they reach the revert branch
GHOST_NEEDS: mapping(uint256 => bool) orderClosed (mirrors trackedOrders[].closed, set after success)
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: LimitOrdersLogic: `if (order.claimedOrCancelled) revert OrderAlreadyHandled`.
RATIONALE: The order state machine Open -> {Cancelled | Claimed} is terminal.

PROPERTY_ID: [VT-04]
TYPE: SPECIFIC (after a successful claimLimitOrder, then any later cancelLimitOrder)
ENGLISH: Bucket fill is monotonic (false -> true, never reset). Once any order in bucket (pool, targetTick, zeroForOne) has been claimed, the bucket is filled, so no order in that bucket can be cancelled afterwards.
SOLIDITY_SKETCH: on claim success: ghost.bucketFilled[key(pool,tick,dir)] = true; on cancel success: assertFalse(ghost.bucketFilled[key(order)]);
GHOST_NEEDS: mapping(bytes32 => bool) bucketFilled. TrackedOrder must be extended with targetTick, zeroForOne and inputAmount (currently it holds only id/key/maker/closed).
SNAPSHOT_NEEDS: none (or a harness getter via vm.load on _limitOrderBuckets for a direct check)
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none, inferred (`b.filled = true` is the only write; cancel reverts `BucketAlreadyFilled`).
RATIONALE: Monotonic flag. A reset would allow cancelling an order whose liquidity was already treated as crossed.

PROPERTY_ID: [ST-10] [MANDATORY: lead #4 / I-21]
TYPE: SPECIFIC (after a cancelLimitOrder or claimLimitOrder success)
ENGLISH: Place -> cancel round-trip symmetry. A maker's net change in the order's input currency over the order's lifetime is zero: the balance increase at cancel or claim equals the inputAmount the maker actually paid at placement. For native-input orders on nativeOrderKey the maker pays 0 ETH at placement, so any ETH received at cancel is a net gain.
SOLIDITY_SKETCH: at place: ghost.paid[id] = balBefore(maker,inputCcy) - balAfter(maker,inputCcy) (ETH: actor.balance delta); at cancel/claim: uint256 received = balAfter - balBefore; assertEq(received, ghost.paid[id]); // native: paid==0, received==inputAmount -> fails
GHOST_NEEDS: mapping(uint256 => uint256) orderPaid; TrackedOrder.inputAmount; input currency per order.
SNAPSHOT_NEEDS: maker balance of the input currency (ERC20 or native) before/after.
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none, inferred. Related doc: docs/04 §5 #3 "valueOut <= valueIn" (scoped to swaps/curves/LP cycles, not limit orders).
RATIONALE: placeOrder skips the transfer for address(0) input (and is not payable), yet records inputAmount; cancel/claim then `transfer`s ETH from the hook. With hookRigOrchestrator_donateETH funding the hook, an actor can drain donated ETH.

PROPERTY_ID: [VT-05]
TYPE: SPECIFIC (after placeLimitOrder)
ENGLISH: Order ids are strictly increasing. A new order id is greater than every earlier tracked id.
SOLIDITY_SKETCH: if (trackedOrders.length > 1) assertGt(trackedOrders[n-1].id, trackedOrders[n-2].id);
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none, inferred (`orderId = nextLimitOrderId++`)
RATIONALE: Entity-count consistency (Pattern C). An id collision would overwrite an escrowed order.

=====================================================================
E. REWARD / BURN / DONATION ACCUMULATORS
=====================================================================

PROPERTY_ID: [VT-06]
TYPE: GLOBAL
ENGLISH: The per-pool accumulators totalLPRewardsDonated, totalAutoBurnedByPool, totalPoolSwapPoints and swapRewardPoints[p][t] never decrease.
SOLIDITY_SKETCH: for i: assertGe(A.lpDonated[i],B.lpDonated[i]); assertGe(A.burned[i],B.burned[i]); assertGe(A.poolPoints[i],B.poolPoints[i]); for t in TRADERS: assertGe(A.points[i][t],B.points[i][t]);
GHOST_NEEDS: none
SNAPSHOT_NEEDS: lpDonated[], burned[], poolPoints[], points[pool][trader]
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none, inferred (only `+=` writers)
RATIONALE: Monotonic accumulators (Pattern E).

PROPERTY_ID: [VS-05]
TYPE: GLOBAL
ENGLISH: The swap-points aggregate stays in sync with per-trader points: totalPoolSwapPoints[p] == Σ_{t∈TRADERS} swapRewardPoints[p][t].
SOLIDITY_SKETCH: for i: uint256 s; for t in TRADERS: s += orchestrator.swapRewardPoints(P,t); assertEq(orchestrator.totalPoolSwapPoints(P), s);
GHOST_NEEDS: none. TRADERS must include both routers, because routeMode 3 or an untrusted trustedRouter resolves to the router address.
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: Accounting identity: SwapRewardsLogic.accrue does `swapRewardPoints[p][t] = updated` and `totalPoolSwapPoints[p] += points` with the same `points`.
RATIONALE: Biconditional aggregate sync (Pattern G). If it fails while the identity holds, a trader identity outside TRADERS was resolved, which is itself a finding about identity resolution.

PROPERTY_ID: [ST-11]
TYPE: SPECIFIC (after a pool_swap* on pool p)
ENGLISH: A swap changes accumulators only on the swapped pool. For every other pool p', claims, King state, lpDonated, burned and points are unchanged.
SOLIDITY_SKETCH: for j != swappedIdx: assertEq(A.lpDonated[j],B.lpDonated[j]); assertEq(A.burned[j],B.burned[j]); assertEq(A.poolPoints[j],B.poolPoints[j]); assertEq(A.kPot[j],B.kPot[j]); assertEq(A.kRound[j],B.kRound[j]); claims[j][*][*] unchanged
GHOST_NEEDS: lastSwappedPoolIdx
SNAPSHOT_NEEDS: all of the above per pool
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/02 4.2 and invariant-context: "No block in hookrig ever uses global state". docs/06 AV-01: claims double-keyed per pool.
RATIONALE: Pattern B, negative postcondition for per-pool isolation.

PROPERTY_ID: [ST-12]
TYPE: SPECIFIC (after a pool_swap* where totalLPRewardsDonated[p] increased)
ENGLISH: LP donations happen only when the pool had active liquidity at swap time. With zero liquidity the donation share is not withheld and lpDonated stays unchanged.
SOLIDITY_SKETCH: if (A.lpDonated[i] > B.lpDonated[i]) assertGt(B.liquidity[i], 0); // liquidity = StateLibrary.getLiquidity(poolManager,P)
GHOST_NEEDS: none
SNAPSHOT_NEEDS: uint128[] liquidity
PRIORITY: LOW
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 code excerpt: "Fallback when active liquidity is zero so swaps never revert". AfterSwapDeltaAggregator.sol:665-675.
RATIONALE: State-dependent postcondition.

PROPERTY_ID: [ST-13]
TYPE: SPECIFIC (needs a harness getter)
ENGLISH: The auto-buyback reserve only grows except on a trigger. A trigger resets it to exactly 0 in the same swap that raises totalLPRewardsDonated[p] by at least the prior reserve.
SOLIDITY_SKETCH: if (A.bbReserve[i][c] < B.bbReserve[i][c]) { assertEq(A.bbReserve[i][c], 0); assertGe(A.lpDonated[i] - B.lpDonated[i], B.bbReserve[i][c]); }
GHOST_NEEDS: none
SNAPSHOT_NEEDS: bbReserve[pool][currency]. Needs a harness getter: _autoBuybackStates[poolId].reserveByCurrency[c] is internal, so read it with vm.load on the mapping slot.
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none, inferred
RATIONALE: Paired operation accumulate <-> deploy.

=====================================================================
F. REFERRAL / ACCESS / MANAGED FEE (permissioned state)
=====================================================================

PROPERTY_ID: [ST-14]
TYPE: GLOBAL (B/A)
ENGLISH: traderReferrer[p][t] is first-touch immutable: once non-zero it never changes, and it never equals t.
SOLIDITY_SKETCH: for i, t in TRADERS: address r = A.ref[i][t]; assertTrue(r != t); if (B.ref[i][t] != address(0)) assertEq(r, B.ref[i][t]);
GHOST_NEEDS: none
SNAPSHOT_NEEDS: ref[pool][trader]
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 AV-13: "`trader == referrer` revert + immutable first-touch binding". docs/04 §4: "First-touch referrer binding with strict anti-self-referral check".
RATIONALE: State machine 0 -> referrer, terminal.

PROPERTY_ID: [ST-15]
TYPE: GLOBAL (B/A)
ENGLISH: isAccountAllowlisted changes only through a successful setAllowlistAccount by that pool's AccessControl manager. For POOL_PRIVATE the manager is actors[2]; for fuzz-registered pools it is the registering actor.
SOLIDITY_SKETCH: for i, a in claimants: if (A.allow[i][a] != B.allow[i][a]) assertTrue(lastCall == SET_ALLOWLIST && lastCaller == ghost.acManager[i] && a == lastAccount);
GHOST_NEEDS: acManager[poolIdx] (set at registration), lastCall / lastCaller / lastAccount
SNAPSHOT_NEEDS: allow[pool][claimant]
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: AccessControlBlock.setAllowlistAccount: `if (msg.sender != _accessConfigs[poolId].manager) revert UnauthorizedAccessControlManager`.
RATIONALE: Pattern B. Unauthorised allowlist mutation. The handler calls with caller = actor half the time.

PROPERTY_ID: [ST-16]
TYPE: GLOBAL (B/A)
ENGLISH: For pools with BIT_MANAGED_FEE, slot0.lpFee changes only through a successful setManagedPoolFee by the configured manager, and the new value is ≤ feeCap (POOL_MULTI: manager actors[1], cap 10_000). For dynamic-fee pools without the managed block, slot0.lpFee never changes after initialization.
SOLIDITY_SKETCH: (,,,uint24 lpFee) = StateLibrary.getSlot0(poolManager,P); if (A.lpFee[i] != B.lpFee[i]) { assertTrue(lastCall==SET_MANAGED_FEE && lastCaller==ghost.feeManager[i] && lastPoolIdx==i); assertLe(A.lpFee[i], ghost.feeCap[i]); }
GHOST_NEEDS: feeManager[poolIdx], feeCap[poolIdx] (effective cap = min(cfg.feeCap or 50_000, 50_000)); lastCall / lastCaller / lastPoolIdx. Also record fresh-pool initialization, which legitimately sets lpFee once via _applyInitialManagedFee.
SNAPSHOT_NEEDS: lpFee[pool]
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §4: Managed fee "Manager can update LP fee | Cannot exceed immutable feeCap set at initialization (max ≤ 5%)". ManagedFeeLogic.update guards.
RATIONALE: Permissioned-transition postcondition. The handler calls with a 1.5× over-cap value and a non-manager caller.

=====================================================================
G. TEMPORAL / CLOCK STATE (oracle, anti-snipe, TWAMM, JIT)
=====================================================================

PROPERTY_ID: [ST-17]
TYPE: GLOBAL (B/A)
ENGLISH: The oracle moves by at most 100 ticks per elapsed second, and its state is unchanged within the same timestamp.
SOLIDITY_SKETCH: (int24 lt, int56 cum) = orchestrator.getOracleTickCumulative(P); uint256 dt = A.ts - B.ts; if (dt == 0) { assertEq(A.oLast[i],B.oLast[i]); assertEq(A.oCum[i],B.oCum[i]); } else assertLe(abs(A.oLast[i]-B.oLast[i]), 100*dt);
GHOST_NEEDS: none
SNAPSHOT_NEEDS: oLast[pool], oCum[pool], timestamp
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: OracleBlock natspec: "truncates max tick delta per block to resist single-block flash-loan manipulation". Code clamp MAX_ORACLE_TICK_DELTA_PER_SEC = 100 and `if (elapsed == 0) return`.
RATIONALE: Temporal transition bound.

PROPERTY_ID: [ST-18] [MANDATORY: I-29 / lead #3]
TYPE: SPECIFIC (after pool_swap* / add / remove on a live pool with BIT_ORACLE)
ENGLISH: Every live pool with BIT_ORACLE actually checkpoints. If at least 1 s has passed since that pool's previous checkpoint opportunity and the clamped tick is non-zero, getOracleTickCumulative changes. Pools whose stack was registered after initialization (POOL_UNREGISTERED retro-registration) never set `initialized`, so they stay at (0,0) forever.
SOLIDITY_SKETCH: if ((bitmap & BIT_ORACLE)!=0 && block.timestamp > ghost.lastOracleTouch[i] && B.tick[i] != 0) assertTrue(A.oCum[i] != B.oCum[i] || A.oLast[i] != B.oLast[i]); ghost.lastOracleTouch[i] = block.timestamp;
GHOST_NEEDS: uint256[] lastOracleTouch (per pool)
SNAPSHOT_NEEDS: oLast, oCum, tick (slot0)
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none, inferred (x-ray I-29, on-chain=No)
RATIONALE: Flag-data sync between the enabled bit and the initialized state. The same root cause leaves the TWAMM, LimitOrders, DynamicFee and Arb anchors unset after retro-registration.

PROPERTY_ID: [ST-19] [MANDATORY: I-23]
TYPE: GLOBAL (needs a harness getter)
ENGLISH: The anti-snipe clock is never re-armed after trading starts. _antiSnipeStates[p].startBlock changes only in the transaction where that pool's own curve graduates (launchState ActiveBonding -> Graduated) or at first registration.
SOLIDITY_SKETCH: if (A.snipeStart[i] != B.snipeStart[i]) assertTrue((B.bitmap[i]==0 && A.bitmap[i]!=0) || (B.launchState[i]==ActiveBonding && A.launchState[i]==Graduated));
GHOST_NEEDS: none
SNAPSHOT_NEEDS: snipeStart[pool] and launchState[pool]. Needs a harness getter: _antiSnipeStates is internal, so read it with vm.load on the mapping slot (startBlock is packed with launchFee/normalFee/decayBlocks).
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §4: Anti-snipe "Monotonically decreases from launchFee to baseFee over N blocks; can never be re-triggered after block N".
RATIONALE: notifyPoolGraduated has no once-only latch and is also callable by launchpadFactory. A related check: retro-registering anti-snipe on live POOL_UNREGISTERED arms an 80% fee on an active pool (lead #3).

PROPERTY_ID: [VS-06] [MANDATORY: I-22 / lead #5]
TYPE: GLOBAL (needs a harness getter)
ENGLISH: TWAMM aggregate sell rates match the orders that are still active: sellRate0For1[p] == Σ rate of submitted zeroForOne orders on p with expirationTimestamp > block.timestamp, and the same for 1For0. accruedVirtualVolume0/1 never decrease.
SOLIDITY_SKETCH: assertEq(twamm.sellRate0For1, Σ_{o: o.pool==p && o.z41 && o.expiry > now} o.rate); assertGe(A.vol0[i],B.vol0[i]);
GHOST_NEEDS: TWAMMOrder[] trackedTwamm {poolIdx, zeroForOne, rate = floor(total/duration), expiry}, recorded in _submitTWAMMOrder_clamped.
SNAPSHOT_NEEDS: sellRate0For1/1For0, accruedVirtualVolume0/1 per pool. Needs a harness getter: _twammStates is internal, so read it with vm.load.
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none, inferred (x-ray I-22: expirationTimestamp is written but never read; rates only `+=`)
RATIONALE: Aggregate-to-entity sync. Rates that never expire make virtual volume grow without bound.

PROPERTY_ID: [ST-20]
TYPE: SPECIFIC (after pool_removeLiquidity_* succeeds on a pool with BIT_JIT_GUARD or BIT_MEV_PROTECTION and minLPHoldBlocks > 0)
ENGLISH: No same-block add -> remove for the same PoolManager position: (router, tickLower, tickUpper, salt=_positionSalt(actor)). A successful remove implies block.number >= the last add block for that position + minLPHoldBlocks (POOL_PRIVATE: 5; POOL_MULTI: 2).
SOLIDITY_SKETCH: bytes32 pk = Position.calculatePositionKey(router, tl, tu, _positionSalt(actor)); assertGe(block.number, ghost.lastAddBlock[i][pk] + ghost.minHold[i]);
GHOST_NEEDS: mapping(uint256 => mapping(bytes32 => uint256)) lastAddBlock (set on every successful add); minHold[poolIdx]
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §4: JIT Guard "Prevents same-block `addLiquidity -> donate -> removeLiquidity` MEV dilution".
RATIONALE: The hook keys the hold on `_resolveUser` (spoofable hookData) instead of the economic position. Adding with routeMode 2 (spoofed) and removing with mode 1 (honest) bypasses the hold (X-3/E-4).

=====================================================================
H. LAUNCH CURVE STATE MACHINE
=====================================================================

PROPERTY_ID: [ST-21]
TYPE: GLOBAL (B/A, every curve in xykCurves, trancheCurves and NativeTick launches)
ENGLISH: launchState moves only forward, Uninitialized -> ActiveBonding -> Graduated, and Graduated is terminal. Curves observed by the harness are never Uninitialized.
SOLIDITY_SKETCH: for each curve: assertGe(uint8(A.state), uint8(B.state)); assertTrue(A.state != Uninitialized);
GHOST_NEEDS: none
SNAPSHOT_NEEDS: launchState[curve]
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: Explicit enum guards: `if (launchState != LaunchState.Uninitialized || msg.sender != factory) revert`, `if (launchState != ActiveBonding) revert CurveNotActive`. x-ray I-13.
RATIONALE: Core lifecycle state machine (Pattern F).

PROPERTY_ID: [VS-07]
TYPE: GLOBAL
ENGLISH: A launch pool is initialized in PoolManager if and only if its curve has graduated. While ActiveBonding, slot0.sqrtPriceX96 == 0 (nobody front-ran initialization). Once Graduated, sqrtPriceX96 != 0.
SOLIDITY_SKETCH: for i with poolCurves[i] != 0: (uint160 sp,,,) = getSlot0(poolManager,P); if (_launchState(curve)==ActiveBonding) assertEq(sp,0); else if (_launchState(curve)==Graduated) assertGt(sp,0);
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: HookRigBase natspec: "Guards launchpad pools against pre-initialization front-running". _beforeInitialize reverts UnauthorizedPoolInitializer for non-curve, non-factory senders.
RATIONALE: Biconditional between launch phase and pool existence. Early initialization would bypass the curve and brick graduation (initialize would revert).

PROPERTY_ID: [VS-08]
TYPE: GLOBAL
ENGLISH: While ActiveBonding, both graduation thresholds are still unmet: realQuoteRaised < graduationQuoteTarget and curveTokensSold < curveTokenAllocation. A buy that reaches either one graduates atomically. In every state, realQuoteRaised ≤ graduationQuoteTarget (cap-and-refund) and curveTokensSold ≤ curveTokenAllocation.
SOLIDITY_SKETCH: for xyk/tranche: if (state==ActiveBonding) { assertLt(c.realQuoteRaised(), target); assertLt(c.curveTokensSold(), alloc); } assertLe(c.realQuoteRaised(), target); assertLe(c.curveTokensSold(), alloc);
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none (read curveConfig() / trancheConfig())
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: Code: `if (realQuoteRaised >= target || curveTokensSold >= allocation) _graduateToV4()`. docs/06 FF-04: "added cap-and-refund at graduationQuoteTarget". docs/04 §5 #5: graduation "refunds excess final buy amounts accurately". For Stepped, net = floor(ceil(rem·1e4/(1e4−s))·(1e4−s)/1e4) == rem.
RATIONALE: Phase-to-counter sync. A stalled ActiveBonding curve above target means graduation was skipped or reverted.

PROPERTY_ID: [ST-22]
TYPE: GLOBAL (B/A)
ENGLISH: Graduated curves are frozen. Once Graduated, realQuoteRaised, curveTokensSold, virtualQuoteReserve, virtualTokenReserve, invariantK and totalSurchargeCollected never change.
SOLIDITY_SKETCH: if (B.state[c]==Graduated) { assertEq(A.rqr[c],B.rqr[c]); assertEq(A.sold[c],B.sold[c]); assertEq(A.vQ[c],B.vQ[c]); assertEq(A.vT[c],B.vT[c]); assertEq(A.surch[c],B.surch[c]); }
GHOST_NEEDS: none
SNAPSHOT_NEEDS: per curve: rqr, sold, vQ, vT, k, surch, state
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: buy/sell guard `if (launchState != LaunchState.ActiveBonding) revert CurveNotActive()`.
RATIONALE: Terminal-state negative postcondition.

PROPERTY_ID: [ST-23]
TYPE: SPECIFIC (after a curve buy / sell that stays in ActiveBonding)
ENGLISH: Direction of counters: a buy never decreases realQuoteRaised, curveTokensSold or totalSurchargeCollected, and for XYK it never increases virtualTokenReserve. A sell never increases realQuoteRaised or curveTokensSold and never changes totalSurchargeCollected.
SOLIDITY_SKETCH: buy: assertGe(A.rqr,B.rqr); assertGe(A.sold,B.sold); assertGe(A.surch,B.surch); assertLe(A.vT,B.vT); sell: assertLe(A.rqr,B.rqr); assertLe(A.sold,B.sold); assertEq(A.surch,B.surch);
GHOST_NEEDS: lastCurveOp {curve, isBuy}
SNAPSHOT_NEEDS: rqr, sold, surch, vT per curve
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none, inferred
RATIONALE: Pattern A per operation.

PROPERTY_ID: [VS-09]
TYPE: GLOBAL (VirtualXYK curves)
ENGLISH: Virtual reserves stay in sync with the real counters: virtualQuoteReserve == cfg.virtualQuoteReserve + realQuoteRaised. While ActiveBonding with no creator vesting (as in the harness), virtualTokenReserve + curveTokensSold == cfg.virtualTokenReserve.
SOLIDITY_SKETCH: assertEq(c.virtualQuoteReserve(), cfg.virtualQuoteReserve + c.realQuoteRaised()); if (ActiveBonding) assertEq(c.virtualTokenReserve() + c.curveTokensSold(), cfg.virtualTokenReserve);
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD for the quote identity; EXPLORATORY for the token identity.
EVIDENCE: Quote: closed-form identity. buy adds quoteUsed to both `virtualQuoteReserve` and `realQuoteRaised`, and sell subtracts quoteOut from both (x-ray I-14). Token identity: none, inferred.
RATIONALE: In sell, `curveTokensSold` is clamped to 0 (`curveTokensSold > in ? ... : 0`) while virtualTokenReserve grows by the full amount in. Any token supply outside the curve's sold counter (creator vesting, or a different curve's token) desyncs the curve. This should be fuzzed with creatorVestingBps > 0.

PROPERTY_ID: [VS-10]
TYPE: GLOBAL (Stepped and XYK, ActiveBonding, launches with creatorVestingBps == 0)
ENGLISH: The project-token supply held outside the curve never exceeds curveTokensSold: totalSupply − balanceOf(curve) ≤ curveTokensSold. Donations to the curve make it strict.
SOLIDITY_SKETCH: if (ActiveBonding) assertLe(T.totalSupply() - T.balanceOf(curve), c.curveTokensSold());
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none, inferred
RATIONALE: Sync between the sold counter and actual distribution. A violation means tokens left the curve without being counted, or the counter was clamped on sell.

PROPERTY_ID: [ST-24]
TYPE: SPECIFIC (handler where a curve flips ActiveBonding -> Graduated: *_buy*, *_toGraduation)
ENGLISH: Graduation postconditions:
(a) the pool is initialized and the curve's full-range position (owner = curve, salt 0) has liquidity > 0;
(b) for Stepped, the King-pot increase plus the poolAdmin claim increase on that pool in currency0 equals floor(totalSurchargeCollected × surchargeToKingPotBps / 1e4);
(c) no other pool's state changes.
SOLIDITY_SKETCH: assertGt(sqrtP_after,0); assertGt(getPositionLiquidity(curve, fullRange, 0), 0); uint256 seed = mulDiv(surch, bps, 1e4); assertEq((A.kPot[i]-B.kPot[i]) + (A.claims[i][token0][poolAdmin]-B.claims[i][token0][poolAdmin]), seed);
GHOST_NEEDS: none
SNAPSHOT_NEEDS: kPot, claims, sqrtP, curve position liquidity (Position.calculatePositionKey(curve, (MIN_TICK/sp)*sp, (MAX_TICK/sp)*sp, 0))
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: invariant-context: "Curves graduate by initializing the v4 pool and seeding full-range LP that is never removed". SteppedTranche natspec: "Surcharges seed extra graduation LP depth and Round #1 KingOfThePool jackpot". docs/06 FF-03: mismatched seeds go to admin claims.
RATIONALE: Transition postcondition. It pairs with ST-07, because the seed sets potCurrency = currency0.

PROPERTY_ID: [VT-07]
TYPE: GLOBAL
ENGLISH: Graduation LP is permanently locked. After graduation, the curve's full-range position liquidity never decreases.
SOLIDITY_SKETCH: if (B.state[c]==Graduated) assertGe(A.curvePosLiq[c], B.curvePosLiq[c]);
GHOST_NEEDS: none
SNAPSHOT_NEEDS: curvePosLiq per curve
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: VirtualXYKLaunch @dev: "irreversible LP lock". invariant-context: "full-range LP that is never removed".
RATIONALE: Monotonicity of locked liquidity.

PROPERTY_ID: [VS-11]
TYPE: GLOBAL
ENGLISH: Launch bookkeeping matches the harness:
- launchpadFactory.totalLaunches() == launchTokens.length;
- tokenToCurve(launchTokens[k]) is the curve tracked for it and never changes;
- every launch pool has bitmap != 0;
- each curve's poolId() equals its tracked key.toId();
- for VirtualXYK and SteppedTranche curves, poolKey.currency1 is the launched token.
SOLIDITY_SKETCH: assertEq(launchpadFactory.totalLaunches(), launchTokens.length); for i with poolCurves[i]!=0: assertEq(launchpadFactory.tokenToCurve(Currency.unwrap(poolKeys[i].currency1)), poolCurves[i]); assertTrue(bitmap(P)!=0); assertEq(PoolId.unwrap(curve.poolId()), PoolId.unwrap(P));
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none, inferred (`totalLaunches++` and `tokenToCurve[token] = curve` in _deploySortedTokenAndRegisterPool)
RATIONALE: Entity-count consistency (Pattern C) across factory, curve and orchestrator.

NOTES FOR THE HARNESS BUILDER
- Snapshots.State must hold per-pool arrays (bitmap, kRound/kKing/kPot/kDeadline, lpDonated, burned, poolPoints, lpFee, sqrtP, tick, liquidity, oLast/oCum). It also needs per-pool×currency×claimant claims, per-pool×trader points and ref, per-pool×claimant allow, per-currency hook6909, and per-curve (state, rqr, sold, vQ, vT, k, surch, curvePosLiq), plus block.timestamp and block.number.
- Internal state that needs vm.load getters: _kingStates.potCurrency (ST-07 strong form), _autoBuybackStates.reserveByCurrency (ST-13), _antiSnipeStates.startBlock (ST-19), _twammStates (VS-06), _limitOrderBuckets (VT-04 direct form).
- TrackedOrder must gain targetTick, zeroForOne, inputAmount and the amount actually paid (ST-10, VT-04).
- The TRADERS set must include both routers (VS-05, VT-06, ST-14).

Highest-signal items, expected to fail:
- ST-07: King pot currency flip after a SteppedTranche seed.
- ST-10: native limit-order cancel pays out ETH that was never escrowed.
- ST-18: oracle on retro-registered pools never initializes.
- ST-20: JIT hold bypassed via spoofed hookData.
- VS-06: TWAMM rates never expire. Needs a getter.
- VS-09 token identity: sold-counter clamp on sell. Needs launches with creator vesting enabled.