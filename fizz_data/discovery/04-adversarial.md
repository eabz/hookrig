PROPERTY_ID: [ADV-01]
TYPE: SPECIFIC (in `hookRigOrchestrator_cancelLimitOrder_clamped` / `_claimLimitOrder_clamped`) plus a GLOBAL ghost check
ENGLISH: An attacker cannot get more out of a limit order (by cancelling or claiming it) than they actually paid in. Native-currency orders are the main case. `placeLimitOrder` is not `payable` and never pulls ETH when `currency0 == address(0)`, yet `cancelOrder`/`claimOrder` still send `inputAmount` of ETH out of the hook.
SOLIDITY_SKETCH:
  // in placeLimitOrder handler: depositedDelta = balBefore(maker, inCcy) - balAfter(maker, inCcy)  (ETH: actor.balance)
  ghosts.orderDeposit[orderId] = depositedDelta;
  // in cancel/claim handler:
  uint256 paid = balAfter(maker, inCcy) - balBefore(maker, inCcy);
  t(paid <= ghosts.orderDeposit[orderId], "ADV-01: limit order paid out more than deposited");
  // global: for each currency c: ghosts.limitOrderOut[c] <= ghosts.limitOrderIn[c]
GHOST_NEEDS: mapping(uint256 => uint256) orderDeposit; mapping(Currency => uint256) limitOrderIn, limitOrderOut. TrackedOrder needs inputCurrency and inputAmount added.
SNAPSHOT_NEEDS: the maker's balance of the input currency (ETH or ERC20) before and after place, cancel and claim.
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 FF-01 says the fix stops a crafted call from withdrawing "another token from HookRigOrchestrator". docs/04 §5 #3: "valueOut <= valueIn".
RATIONALE: Native orders are unbacked (I-21). An attacker places a native zeroForOne order on `nativeOrderKey` with any `inputAmount` (1e24) and pays nothing, then cancels it. The cancel sends real ETH taken from `hookRigOrchestrator_donateETH` donations or from other makers. This is direct theft.

PROPERTY_ID: [ADV-02]
TYPE: SPECIFIC (cancel/claim handlers, try/catch)
ENGLISH: An attacker cannot stop an honest maker from cancelling an unfilled order or claiming a filled one.
SOLIDITY_SKETCH:
  try orchestrator.cancelLimitOrder(o.key, o.id) { } catch (bytes memory err) {
      // allowed reverts: BucketAlreadyFilled (then claim must work), NotOrderMaker, OrderAlreadyHandled
      t(selector(err) == BucketAlreadyFilled.selector, "ADV-02: unfilled limit order cannot be cancelled");
  }
  // same for claimLimitOrder: the only allowed revert is BucketNotYetFilled
GHOST_NEEDS: none beyond trackedOrders (the order is not closed and the actor is the maker)
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 table: "Users can always cancel unfilled orders (`cancelOrder`) regardless of pool state". The LimitOrdersBlock NatSpec says "Guarantee liveness".
RATIONALE: Native orders are unbacked, so an honest maker's cancel reverts on the ETH transfer whenever the hook holds less ETH than the order amount. Free native orders can also push the uint128 bucket `totalInputAmount` toward overflow (see ADV-17).

PROPERTY_ID: [ADV-03]
TYPE: SPECIFIC (`hookRigOrchestrator_withdrawClaim_full`, try/catch)
ENGLISH: An attacker cannot leave any claimant unable to withdraw their full `poolClaims` balance.
SOLIDITY_SKETCH:
  uint256 avail = orchestrator.poolClaims(pid, c, claimant);
  if (avail == 0) return;
  vm.prank(claimant);
  try orchestrator.withdrawClaim(pid, c, avail, claimant) {
      t(orchestrator.poolClaims(pid, c, claimant) == 0, "ADV-03: residual claim");
  } catch { t(false, "ADV-03: full claim withdrawal reverted"); }
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §5 #2 solvency: "sum(claims) <= actual_reserves". docs/06 AV-10 says recipients withdraw asynchronously through pull-based ERC-6909 claims.
RATIONALE: Detects anything that burns the hook-wide ERC-6909 balance beyond what was credited, so a later claimant's burn underflows. Example: a King winner paid a mixed-currency pot (ADV-04) takes ERC-6909 that backs tax, fee-share or referral claims in the same currency. Fuzzed launches with Tax + Buyback + King hit this.

PROPERTY_ID: [ADV-04]
TYPE: SPECIFIC (`hookRigOrchestrator_claimKingPot_clamped`) plus ghost tracking in swap, finalize and curve-buy handlers
ENGLISH: A King winner cannot receive more of currency C than was put into that pool's pot in currency C. Pots must never mix currencies.
SOLIDITY_SKETCH:
  // swap handler, pools with King: (r0,k0,pot0,) = getCurrentKing(pid) before; (r1,,pot1,) after.
  //   if r1 > r0: ghosts.settled[pid][r0] = Round(k0, pot0); ghosts.potIn[pid][project] adds the post-roll pot1
  //   else ghosts.potIn[pid][project] += pot1 - pot0
  // curve buy that graduates a SteppedTranche: seed = totalSurchargeCollected * surchargeToKingPotBps / 1e4
  //   ghosts.potIn[pid][currency0] += seed   (when King is on and the pot is empty or in the same currency)
  // claim handler: received = Δ balance of winner in each tracked currency
  for each c: t(received[c] <= ghosts.potIn[pid][c] - ghosts.potOut[pid][c], "ADV-04: King pot paid in a currency it never received");
  ghosts.potOut[pid][c] += received[c];
GHOST_NEEDS: mapping(PoolId=>mapping(Currency=>uint256)) potIn, potOut; mapping(PoolId=>mapping(uint64=>Round{winner,amount,claimed})) settled. Alternative: a harness getter for `_kingStates[pid].potCurrency` and `_settledKingRounds[pid][r]`.
SNAPSHOT_NEEDS: getCurrentKing(pid) before and after each swap/finalize; winner balances in trackedCurrencies before and after the claim
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 FF-03 says contributions are restricted to projectCurrency and "mismatched currency seeds [are routed] to poolClaims[poolId][currency][admin] rather than corrupting potCurrency".
RATIONALE: This is the I-3/X-5 lead. On POOL_TRANCHE, graduation seeds a quote-currency (token0) pot into an empty pot, so the mismatch branch is skipped. The next exact-in buy calls `processBuy`, which sets `potCurrency = project` and adds to the same amount. The winner is then owed (quote seed + project cut) in project tokens: either the claim reverts (pot frozen) or it drains other claimants' project ERC-6909.

PROPERTY_ID: [ADV-05]
TYPE: SPECIFIC (claimKingPot handler, using the ghost from ADV-04)
ENGLISH: An attacker cannot freeze a settled King round. The recorded winner can always claim an unclaimed round once.
SOLIDITY_SKETCH:
  Round storage rd = ghosts.settled[pid][r];
  if (rd.winner == address(0) || rd.claimed || rd.amount == 0) return;
  vm.prank(rd.winner);
  try orchestrator.claimKingPot(pid, r, rd.winner) { rd.claimed = true; }
  catch { t(false, "ADV-05: settled King round unclaimable by its winner"); }
GHOST_NEEDS: the settled-round ghost from ADV-04 (or a harness getter on `_settledKingRounds`)
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 FF-03 (the jackpot must not be frozen). docs/04 table: "Winner claims jackpot via pull".
RATIONALE: The current handler pulls a random actor as winner, so it almost never takes the successful path. This property claims as the true winner, which surfaces the mixed-currency freeze.

PROPERTY_ID: [ADV-06]
TYPE: SPECIFIC (`pool_swap*` and `pool_addLiquidity_clamped` on pools with AccessControl, e.g. POOL_PRIVATE)
ENGLISH: An attacker who is not allowlisted cannot swap or add liquidity on an access-controlled pool by putting an allowlisted address in `hookData[0:32]` through an untrusted router.
SOLIDITY_SKETCH:
  // after a successful swap/add on pool idx with BIT_ACCESS_CONTROL and the matching check flag on:
  bool payerAllowed = orchestrator.isAccountAllowlisted(pid, actor);   // actor = the economic payer
  t(payerAllowed || merkleRootSetFor(pid), "ADV-06: non-allowlisted actor traded via spoofed hookData");
GHOST_NEEDS: per pool, whether a non-zero merkle root was ever set (from `_setAccessMerkleRoot_clamped`), so those pools can be excluded
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 #1: Access control ... "resolve the true user only via an Allowlisted Router (IMsgSender) or an EIP-712 signed hookData permit". docs/06 AV-06 says the hookData fallback is only "for non-privileged recipient attribution".
RATIONALE: This is the X-3 lead. `_resolveUser` trusts unsigned `hookData` for any untrusted router. With routeMode 2, actors[1]/actors[2] spoof actors[0] and pass `_verifyAccess` on POOL_PRIVATE.

PROPERTY_ID: [ADV-07]
TYPE: SPECIFIC (`pool_removeLiquidity_*` handlers)
ENGLISH: An attacker cannot remove liquidity before `minLPHoldBlocks` have passed since it was added. Switching the identity resolved from hookData between add and remove must not bypass the guard.
SOLIDITY_SKETCH:
  // on a successful add: ghosts.lpAddBlock[pid][router][tickLower][tickUpper][salt] = block.number
  // on a successful remove (pool has MEV/JIT bit, minHold = ghosts.minHold[pid]):
  t(block.number >= ghosts.lpAddBlock[...] + ghosts.minHold[pid], "ADV-07: JIT hold bypassed");
GHOST_NEEDS: lpAddBlock keyed by the real v4 position (router, ticks, salt); minHold per pool (POOL_MULTI 2, POOL_PRIVATE 5, fuzzed pools min(cfg.minLPHoldBlocks, 7200))
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 AV-08: revert "in beforeRemoveLiquidity if block.number < lastAddBlock + minHoldBlocks".
RATIONALE: The JIT posKey is built from `_resolveUser` instead of the PoolManager position owner. Add via plainRouter with honest hookData (mode 1), then remove the same router position with empty hookData (mode 3) or spoofed hookData (mode 2). The posKey changes, `addedBlock == 0`, and the guard passes. This enables same-block JIT capture of LP-reward, arb and buyback donations. A related grief (not reachable with the current handlers, which fix the salt per actor): an attacker can refresh a victim's posKey with the victim's identity and salt to keep them locked.

PROPERTY_ID: [ADV-08]
TYPE: SPECIFIC (`pool_removeLiquidity_full`, try/catch)
ENGLISH: An attacker cannot stop an LP from fully exiting a position whose JIT hold has expired. This includes hijacked or retro-registered pools and pools whose Oracle has gone idle for a long time.
SOLIDITY_SKETCH:
  if (block.number < ghosts.lpAddBlock[...] + ghosts.minHold[pid]) return;
  try router.modifyLiquidity(key, (tl, tu, -owned, salt), sameIdentityHookData) { }
  catch { t(false, "ADV-08: LP full exit reverted"); }
GHOST_NEEDS: lpAddBlock and minHold from ADV-07
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 #4: "beforeRemoveLiquidity never runs Access control or reverting external checks". docs/06 AV-11: "guaranteeing LPs can always withdraw their liquidity".
RATIONALE: `beforeRemoveLiquidity` calls `OracleLogic.updateCheckpoint`. There, `int24(int256(elapsed) * 100)` silently truncates once `elapsed > 83_886 s` (about 23.3 h). That gives a negative `maxChange`, and `obs.lastTick + maxChange` can overflow int24 and revert. Example: elapsed = 83_887 with lastTick < -92. After a long enough idle gap, swaps and LP exits on Oracle pools (POOL_MULTI) revert.

PROPERTY_ID: [ADV-09]
TYPE: GLOBAL
ENGLISH: An attacker cannot push the Oracle checkpoint tick outside the valid v4 tick range (for example by waiting out an idle gap).
SOLIDITY_SKETCH:
  for each poolKey with BIT_ORACLE: (int24 lastTick,) = orchestrator.getOracleTickCumulative(pid);
  t(lastTick >= TickMath.MIN_TICK && lastTick <= TickMath.MAX_TICK, "ADV-09: oracle tick out of range");
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none (inferred). docs/06 AV-09 only promises a per-step clamp.
RATIONALE: The same int24 truncation as ADV-08. When the revert path is not hit, the "clamp" moves lastTick by about -8.3M ticks. A capital-free attacker can then poison the TWAP just by timing a call after a gap of about 23 h. This is an I-b narrowing check.

PROPERTY_ID: [ADV-10]
TYPE: SPECIFIC (sell swaps on pools with VestingSellCap, e.g. POOL_MULTI)
ENGLISH: An attacker cannot sell more than `maxDailySellBps` of their own start-of-day balance in one epoch by attributing sells to another address through hookData or the router.
SOLIDITY_SKETCH:
  // after a successful sell (project in) by actor, epoch = block.timestamp / 1 days:
  if (ghosts.epochStartBal[pid][actor][epoch] == 0) ghosts.epochStartBal[...] = balBefore(actor, project);
  ghosts.soldInEpoch[pid][actor][epoch] += projectSold;
  t(ghosts.soldInEpoch[...] <= ghosts.epochStartBal[...] * maxBps / 1e4, "ADV-10: vesting sell cap bypassed");
GHOST_NEEDS: epochStartBal and soldInEpoch keyed by (pool, actor, epoch); maxBps per pool (POOL_MULTI 2000, fuzzed from cfg)
SNAPSHOT_NEEDS: actor project-token balance before and after the swap
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 AV-06 lists VestingSellCap among the blocks that trusting a non-authenticated identity "breaks". The hookData fallback is only for "non-privileged recipient attribution".
RATIONALE: `enforceSellCap` keys `_walletSellEpochs` and `balanceOf` on the resolved user. Mode 2 charges the sell to another actor's (larger) allowance. Mode 3 uses the router, whose balance is about 0 so `startOfEpochBalance = tokensSold`, but with bps 10_000 it is skipped. This is an I-d cumulative bypass.

PROPERTY_ID: [ADV-11]
TYPE: SPECIFIC (honest sell through the trusted router, try/catch on the revert selector)
ENGLISH: An attacker cannot use up an honest holder's daily sell allowance. A seller on the trusted route who has not sold this epoch can always sell up to the floor `maxDailySellBps × balance`.
SOLIDITY_SKETCH:
  // routeMode 0, actor has not sold in this epoch (ghost), amount <= bal * maxBps / 1e4
  try swap(...) {} catch (bytes memory e) {
      t(selector(e) != DailyVestingSellCapExceeded.selector, "ADV-11: honest sell blocked by someone else's sells");
  }
GHOST_NEEDS: soldInEpoch per (pool, actor, epoch) for the actor's own trades (from ADV-10). Optionally a harness getter for `_walletSellEpochs[pid][acct]` to compare attributed against own.
SNAPSHOT_NEEDS: actor project balance
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 table: VestingSellCap "so selling can never be completely disabled". docs/06 AV-11 point 2.
RATIONALE: At each epoch start the attacker sells their own tokens with `hookData = victim`, filling `ep.soldInEpoch` for the victim. The victim's honest sells then revert with `DailyVestingSellCapExceeded`. Repeating this daily disables the victim's selling for good.

PROPERTY_ID: [ADV-12]
TYPE: SPECIFIC (buy swaps on pools with an active, non-sunset WalletCap)
ENGLISH: An attacker cannot hold more than `maxWalletBps` of supply after a buy by routing it under a different resolved identity.
SOLIDITY_SKETCH:
  // after a successful buy on pool with walletCap (maxBps < 10_000, not sunset):
  t(IERC20(project).balanceOf(actor) <= IERC20(project).totalSupply() * maxBps / 1e4, "ADV-12: wallet cap bypassed");
GHOST_NEEDS: walletCap config per pool (maxBps, startBlock, sunsetBlocks) recorded at registration
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 #1: "Wallet cap ... resolve the true user only via an Allowlisted Router (IMsgSender) or an EIP-712 signed hookData permit".
RATIONALE: `enforceAfterBuy` checks `balanceOf(resolvedUser)`. Mode 3 checks the router (balance 0) and mode 2 checks a spoofed actor, while the tokens go to the router's caller. Fuzzed stacks on POOL_UNREGISTERED with maxWalletBps of 10 bps make this reachable.

PROPERTY_ID: [ADV-13]
TYPE: SPECIFIC (`_registerPoolStack_clamped`)
ENGLISH: An attacker cannot claim an already-initialized, already-liquid pool they did not create by registering a stack on it after the fact. For example, setting tax, fee-share or referral to themselves, or AccessControl/CircuitBreaker that blocks other users.
SOLIDITY_SKETCH:
  (uint160 sqrtBefore,,,) = StateLibrary.getSlot0(poolManager, key.toId());
  bool ok = try register(...);
  if (ok) t(sqrtBefore == 0, "ADV-13: stack registered on an already-initialized pool");
GHOST_NEEDS: none
SNAPSHOT_NEEDS: slot0.sqrtPriceX96 before registration
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none (inferred). docs/06 AV-07 only covers re-registration and lists "alter tax rates ... or recipients mid-flight" as the threat.
RATIONALE: This is the X-4/E-5 lead. `registerPoolStack` is permissionless for non-launchpad keys and does not check initialization. On POOL_UNREGISTERED (admin-seeded LP), the first caller sets themselves as taxRecipient, fee-share primary, AccessControl manager and Managed-fee manager. They then skim every trade or gate the pool. The `afterInitialize` anchors also never run (ArbRecapture referenceTick 0, so a max 10% cut is donated to LPs).

PROPERTY_ID: [ADV-14]
TYPE: SPECIFIC (new atomic handler `pool_swap_roundTrip`: honest route, exact-in buy then exact-in sell of the full output)
ENGLISH: An attacker cannot profit from an atomic buy-then-sell (or sell-then-buy) round trip on any HookRig pool.
SOLIDITY_SKETCH:
  (b0,b1) = balances(actor); swap(zeroForOne, -x); y = Δtoken1; swap(!zeroForOne, -y);
  t(token0.balanceOf(actor) <= b0 && token1.balanceOf(actor) <= b1, "ADV-14: free round-trip profit");
GHOST_NEEDS: none
SNAPSHOT_NEEDS: actor token0 and token1 balances before and after
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §5 #3: "valueOut <= valueIn" for dust swaps.
RATIONALE: Pattern D/F. Catches cut-accounting errors, such as the zero-liquidity fallback subtracting a donation slice already settled by buyback burn/mint, or exact-out polarity bugs, that would leave a trader owing less than they received.

PROPERTY_ID: [ADV-15]
TYPE: SPECIFIC (new atomic handler `pool_jitBuybackSnipe`: add in-range liquidity with route 1, sell below triggerFloorTick, remove with route 3)
ENGLISH: An attacker cannot atomically capture the accumulated Auto-buyback reserve, or LP-reward/arb donations paid by other traders, using a JIT position.
SOLIDITY_SKETCH:
  v0 = value(actor) at pre-tick price; add(L); swap sell to tick <= floor; remove(L) (identity switched); swap back;
  t(value(actor) <= v0 + DUST, "ADV-15: JIT capture of buyback/LP donations");
GHOST_NEEDS: none
SNAPSHOT_NEEDS: actor token0 and token1 balances, slot0 tick before
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none (inferred). Related to docs/06 AV-08, but the composite profit is not promised.
RATIONALE: On POOL_MULTI, the buyback reserve (from other traders' 1% cuts) is donated to in-range LPs in full once the tick is at or below -100 and the reserve is at least 1 ether. Combined with the ADV-07 identity switch, the attacker owns most of the in-range liquidity for one tx and keeps most of the reserve.

PROPERTY_ID: [ADV-16]
TYPE: SPECIFIC (new atomic handlers `virtualXYK_roundTrip` / `steppedTranche_roundTrip`)
ENGLISH: An attacker cannot profit from buying on a bonding curve and immediately selling the received tokens back. This includes dust amounts and the allocation cap.
SOLIDITY_SKETCH:
  q0 = token0.balanceOf(actor); (tokensOut,) = curve.buy(q, 0, actor); curve.sell(tokensOut, 0, actor);
  t(token0.balanceOf(actor) <= q0, "ADV-16: curve buy/sell cycle profit");
GHOST_NEEDS: none
SNAPSHOT_NEEDS: actor token0 balance
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §5 #3: "valueOut <= valueIn" for curve buy/sell cycles.
RATIONALE: Checks the Ceil/Floor directions in the XYK math (`newVirtualToken` Ceil, `quoteOut` Floor), the Stepped base/pro-rata redemption, and the tranche index falling after a sell (`curveTokensSold` decrement) so the attacker re-buys cheaper. This is I-a near-zero via `buy_dust`/`sell` with 1-wei inputs.

PROPERTY_ID: [ADV-17]
TYPE: SPECIFIC (`steppedTrancheLaunch_sell_*` / `virtualXYKLaunch_sell_*`, try/catch) plus GLOBAL
ENGLISH: An attacker cannot stop pre-graduation holders from selling their full balance back to the curve. The curve always holds at least the quote it owes.
SOLIDITY_SKETCH:
  // global per active curve:
  t(token0.balanceOf(curve) >= curve.realQuoteRaised() (+ totalSurchargeCollected for Stepped), "ADV-17: curve under-collateralized");
  // sell_full: try curve.sell(bal, 0, actor) {} catch { t(false, "ADV-17: pre-graduation exit reverted"); }
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 FF-04: "buyers can always exit against realQuoteRaised". The SteppedTranche NatSpec: "stalled launches can never freeze buyer capital".
RATIONALE: Detects quote leaking out of the curve: over-refund in buy, sells paying above what was raised, or donated project tokens (`hookRigToken_donateToCurve`) skewing the pro-rata cap. Any of these would let early sellers drain later sellers.

PROPERTY_ID: [ADV-18]
TYPE: SPECIFIC (`*_buy_toGraduation`, try/catch)
ENGLISH: An attacker cannot make graduation revert, which would brick the final buy and freeze the launch.
SOLIDITY_SKETCH:
  try curve.buy(gross, 0, actor) {
      t(curve.launchState() == Graduated, "ADV-18: target reached but not graduated");
      (uint160 sp,,,) = getSlot0(poolManager, curve.poolId()); t(sp != 0, "ADV-18: pool not initialized");
  } catch { t(false, "ADV-18: graduation buy reverted"); }
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §"Graduation Continuity Test": "graduation never reverts, refunds excess final buy amounts accurately".
RATIONALE: Graduation does a lot in one step: price clamp at MIN/MAX sqrt, settling `liquidityEstimate`, Stepped `kingPotSeed` settle + mint, `seedKingPotFromLaunchCurve`, and `notifyPoolGraduated`. Prior sells, dust buys or donations can unbalance the amounts the curve holds against what it must settle.

PROPERTY_ID: [ADV-19]
TYPE: SPECIFIC (any curve buy that graduates)
ENGLISH: An attacker cannot buy tokens on the new v4 pool right after graduation at a price meaningfully better than the curve's final marginal price.
SOLIDITY_SKETCH:
  // before the graduating buy: XYK marginal = virtualTokenReserve/virtualQuoteReserve (after the buy's deltas); Stepped = 2^96/currentMarginalPriceQ96()
  // after: v4 price from slot0.sqrtPriceX96 (token1 per token0)
  t(absDiffBps(v4Price, curveMarginalPrice) <= TOL_BPS, "ADV-19: graduation price discontinuity");
GHOST_NEEDS: none
SNAPSHOT_NEEDS: curve virtual reserves and marginal price, and slot0 after
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §"Graduation Continuity Test": "initializes the v4 pool at the exact marginal curve price".
RATIONALE: Graduation prices at `lpTokenReserve / realQuoteRaised`, not at the curve's virtual marginal price. With the default XYK config that is 4.0M against 3.75M tokens per quote, and Stepped differs too. The graduating sniper gets underpriced tokens from the locked LP at curve buyers' expense.

PROPERTY_ID: [ADV-20]
TYPE: SPECIFIC (`_setManagedPoolFee_clamped`, `_setAllowlistAccount_clamped`, `_setAccessMerkleRoot_clamped`, `_setTrustedRouter_clamped`, plus direct non-authorized calls to `seedKingPotFromLaunchCurve` / `notifyPoolGraduated`)
ENGLISH: An attacker cannot call privileged functions: Managed-fee, allowlist and merkle setters as a non-manager; setTrustedRouter or setLaunchpadFactory as a non-owner; King seeding or graduation notices as a non-curve.
SOLIDITY_SKETCH:
  bool ok = try call as caller;
  if (ok) t(caller == ghosts.manager[pid][kind] (or owner / authorizedCurve), "ADV-20: privilege escalation");
  // add handler: actor calls orchestrator.notifyPoolGraduated(pid) and seedKingPotFromLaunchCurve(pid, c, x); both must revert
GHOST_NEEDS: per pool, the managedFee manager, accessControl manager and authorizedCurve recorded at registration/launch
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: Code ACCESS_CONTROL list (invariant-context): `onlyOwner`, manager-only setters, "authorizedCurve/factory-only notifyPoolGraduated / seedKingPotFromLaunchCurve". docs/04 trust-level table.
RATIONALE: A non-curve `notifyPoolGraduated` would re-arm the Anti-snipe fee (up to 80%). A forged `seedKingPotFromLaunchCurve` would credit unbacked pot or poolClaims, which can then be withdrawn as other users' ERC-6909.

PROPERTY_ID: [ADV-21]
TYPE: SPECIFIC (swap handlers on pools with AntiSnipe; needs a harness getter)
ENGLISH: An attacker cannot re-trigger the Anti-snipe launch fee after it has decayed. Once the effective anti-snipe fee reaches normalFee, it never rises again.
SOLIDITY_SKETCH:
  uint24 f = harness_getAntiSnipeFee(pid);   // needs a getter exposing _computeAntiSnipeFee / _antiSnipeStates[pid].startBlock
  if (ghosts.antiSnipeDecayed[pid]) t(f <= ghosts.antiSnipeNormal[pid], "ADV-21: anti-snipe re-armed");
  if (f == ghosts.antiSnipeNormal[pid]) ghosts.antiSnipeDecayed[pid] = true;
GHOST_NEEDS: antiSnipeDecayed and antiSnipeNormal per pool. Needs a harness getter for `_antiSnipeStates[pid]` (internal).
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 table: Anti-snipe "Monotonically decreases ... can never be re-triggered after block N".
RATIONALE: This is the I-23 lead. `_resetAntiSnipeGraduationClock` resets `startBlock` whenever `notifyPoolGraduated` runs, and a non-launchpad registration on a live pool starts the clock at an arbitrary later block. Either way traders can be charged up to 80% again.

PROPERTY_ID: [ADV-22]
TYPE: SPECIFIC (new unclamped handler `twamm_submit_max` / `limit_place_native_max`)
ENGLISH: An attacker cannot permanently DoS TWAMM submissions, or native limit-order placement at a tick, by pushing uint128 accumulators to overflow with free (unbacked) orders.
SOLIDITY_SKETCH:
  // attacker: submitTWAMMOrder(key, dir, type(uint128).max, 1)  (no tokens pulled)
  // honest: try submitTWAMMOrder(key, dir, 1e18, 3600) {} catch { t(false, "ADV-22: TWAMM submission bricked"); }
  // same for placeLimitOrder(nativeKey, tick, true, type(uint128).max) followed by an honest small order at the same tick
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none (inferred). docs/04 calls TWAMM "Fully permissionless".
RATIONALE: This is an I-b case. `submitOrder` pulls no tokens and rates never expire (I-22), so `sellRate0For1 += rate` (uint128) can be filled once for free and every later submission in that direction reverts. Native limit orders (uint128 `totalInputAmount`) can be filled the same way. The current clamps (≤1e24, duration ≥1) cannot reach this, so it needs an unclamped handler.
