## Round-trip and rounding properties for HookRig (fizz Step 9b, agent #2)

**Pairs analyzed:** curve buy/sell (VirtualXYK, SteppedTranche), pool swap A→B→A (exact-in and exact-out), LP add/remove, limit order place/cancel and place/claim, credit claim/withdrawClaim.

**Conversions analyzed:** XYK Ceil reserves with Floor outputs; Stepped Floor tokensOut, Ceil surcharge, Floor sell; `_boundedCut` Floor; FeeSharing split Floor; TWAMM rate Floor; graduation sqrt Floor.

**Pattern E2 check:** no ERC-4626-style shared-conversion bug. XYK buy and sell each Ceil the opposite reserve, which is correct.

### Code facts these properties rest on

1. **Spec/code mismatch on exact-output swaps (RD-10).** docs/04 line 68 says exact-output cuts round **Ceil** ("using `Math.Rounding.Ceil` on added input cost"). The code uses `_boundedCut` → `Math.Rounding.Floor` for every swap direction, so traders on exact-output swaps are under-charged by up to 1 wei per active block.
2. **Native limit orders are free (I-21).** `placeLimitOrder` is non-payable and skips the transfer when the input currency is native. `cancelLimitOrder` then pays ETH out of the hook's balance, which the `hookRigOrchestrator_donateETH` handler funds. RT-08 catches this directly.
3. **Limit-order "claim" never converts anything.** `claimOrder` returns `inputAmount` in the input currency. RT-09 records this behavior.
4. **XYK reserve gaps.** After a sell, `virtualTokenReserve` can sit above `ceilDiv(k, virtualQuoteReserve)`. The gap is at most about `Y/X` token-wei, roughly 1 quote-wei of value. It is a free token gap for the next buyer, which affects RT-02.
5. **Hook-withheld total can be measured exactly per swap.** `withheld = Δ poolManager.balanceOf(hook, unspecifiedId) + Δ totalAutoBurnedByPool[pool] + Δ totalLPRewardsDonated[pool]`. When a buyback triggers, the burned prior reserve shows up in donated, so it cancels out.
6. **LP round-trip false positive.** v4 auto-collects accrued fees on `modifyLiquidity`. The round-trip handler must use a fresh position salt, not `_positionSalt(actor)`.

---

PROPERTY_ID: [RT-01]
TYPE: SPECIFIC
ENGLISH: On an active VirtualXYK curve, if an actor buys with `q` quote and immediately sells every token received, they never end up with more quote than they started with. The curve's `realQuoteRaised` never ends lower than before the round trip.
SOLIDITY_SKETCH:
```solidity
function virtualXYKLaunch_buySellRoundTrip(uint256 curveSeed, uint256 q) public asActor {
    VirtualXYKLaunch curve = xykCurves[curveSeed % xykCurves.length];
    if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return;
    (,, uint128 target,,,) = curve.curveConfig();
    uint256 remaining = uint256(target) - curve.realQuoteRaised();
    if (remaining <= 1) return;
    q = clampBetween(q, 1, min(remaining - 1, token0.balanceOf(actor))); // stay below graduation
    IERC20 proj = IERC20(curve.projectToken());
    snapshotBefore(); // actorQuoteBal, actorProjBal, curveRealQuoteRaised
    (uint256 tokensOut,) = curve.buy(q, 0, actor);
    if (tokensOut == 0) { snapshotAfter(); property_RT01(); return; }
    curve.sell(tokensOut, 0, actor);
    snapshotAfter();
    property_RT01();
}
function property_RT01() internal {
    lte(stateAfter.actorQuoteBal, stateBefore.actorQuoteBal, "RT-01: XYK buy->sell created quote");
    eq(stateAfter.actorProjBal, stateBefore.actorProjBal, "RT-01: project balance drift");
    gte(stateAfter.curveRealQuoteRaised, stateBefore.curveRealQuoteRaised, "RT-01: curve lost quote");
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: actorQuoteBal (token0.balanceOf(actor)), actorProjBal (projectToken.balanceOf(actor)), curveRealQuoteRaised
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §5 #3: "no sequence of dust swaps, bonding curve buy/sell cycles, or LP deposit/withdraw cycles can extract net positive value (`valueOut <= valueIn`)". x-ray E-2: "No value extraction via VirtualXYK buy→sell round-trip".
RATIONALE: This is the main check that the Ceil/Floor directions in `buy` and `sell` hold up. A gap of X − ceil(k/Y) > 0 left by an earlier buy would show up here as profit.

---

PROPERTY_ID: [RT-02]
TYPE: SPECIFIC
ENGLISH: On an active VirtualXYK curve, if an actor sells `t` tokens and immediately buys back with exactly the quote received, they never end up with more project tokens than before. A tolerance of `ceilDiv(virtualTokenReserve, virtualQuoteReserve)` token-wei separates dust from real extraction.
SOLIDITY_SKETCH:
```solidity
function virtualXYKLaunch_sellBuyRoundTrip(uint256 curveSeed, uint256 t) public asActor {
    VirtualXYKLaunch curve = xykCurves[curveSeed % xykCurves.length];
    if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return;
    IERC20 proj = IERC20(curve.projectToken());
    uint256 bal = proj.balanceOf(actor); if (bal == 0) return;
    t = clampBetween(t, 1, bal);
    uint256 dustTol = ceilDiv(curve.virtualTokenReserve(), curve.virtualQuoteReserve()); // pre-state
    snapshotBefore();
    uint256 qOut = curve.sell(t, 0, actor);
    if (qOut == 0) { snapshotAfter(); /* tokens lost, fine */ return; }
    curve.buy(qOut, 0, actor); // may graduate: then skip assertion
    snapshotAfter();
    eq(stateAfter.actorQuoteBal, stateBefore.actorQuoteBal, "RT-02: quote drift");
    lte(stateAfter.actorProjBal, stateBefore.actorProjBal, "RT-02 strict: sell->buy minted free tokens");
    // fallback if strict proves to be dust-only:
    // lte(stateAfter.actorProjBal, stateBefore.actorProjBal + dustTol, "RT-02: sell->buy extraction beyond dust");
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: actorQuoteBal, actorProjBal
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. The strict form can fail by about `Y/X` token-wei when the previous action was another actor's sell.
RATIONALE: Pattern B. It surfaces the token-side reserve gap a sell leaves behind, and tells apart a dust gap from a real rounding inversion.

---

PROPERTY_ID: [RT-03]
TYPE: SPECIFIC
ENGLISH: Repeating N cycles of a dust buy followed by selling everything bought on a VirtualXYK curve never increases the actor's quote balance. The curve's `realQuoteRaised` never decreases across the cycles.
SOLIDITY_SKETCH:
```solidity
function virtualXYKLaunch_dustCycle(uint256 curveSeed, uint256 q, uint8 n) public asActor {
    VirtualXYKLaunch curve = xykCurves[curveSeed % xykCurves.length];
    if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return;
    q = clampBetween(q, 1, 1e12); n = uint8(clampBetween(n, 1, 20));
    snapshotBefore();
    for (uint256 i; i < n; i++) {
        if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) break;
        (uint256 out,) = curve.buy(q, 0, actor);
        if (out > 0) curve.sell(out, 0, actor);
    }
    snapshotAfter();
    lte(stateAfter.actorQuoteBal, stateBefore.actorQuoteBal, "RT-03: XYK dust cycle extracted quote");
    gte(stateAfter.curveRealQuoteRaised, stateBefore.curveRealQuoteRaised, "RT-03: curve drained by cycling");
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: actorQuoteBal, curveRealQuoteRaised
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §5 #3 (`valueOut <= valueIn` for "bonding curve buy/sell cycles").
RATIONALE: Pattern C2 (mandatory). Cycling small amounts adds up per-cycle rounding gaps, which is the empirical rounding-bug detector.

---

PROPERTY_ID: [RT-04]
TYPE: SPECIFIC
ENGLISH: On an active SteppedTranche curve, a buy of `q` followed by selling every token received never returns more quote than `q`, including inside the anti-snipe surcharge window. `realQuoteRaised + totalSurchargeCollected` never ends lower.
SOLIDITY_SKETCH:
```solidity
function steppedTrancheLaunch_buySellRoundTrip(uint256 curveSeed, uint256 q) public asActor {
    SteppedTrancheLaunch curve = trancheCurves[curveSeed % trancheCurves.length];
    if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return;
    q = clampBetween(q, 1, min(token0.balanceOf(actor), 1_000 ether));
    snapshotBefore(); // actorQuoteBal, actorProjBal, curveRealQuoteRaised, curveSurcharge
    (uint256 out,) = curve.buy(q, 0, actor);
    if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return; // graduated
    if (out > 0) curve.sell(out, 0, actor);
    snapshotAfter();
    lte(stateAfter.actorQuoteBal, stateBefore.actorQuoteBal, "RT-04: tranche buy->sell created quote");
    eq(stateAfter.actorProjBal, stateBefore.actorProjBal, "RT-04: project balance drift");
    gte(stateAfter.curveRealQuoteRaised + stateAfter.curveSurcharge,
        stateBefore.curveRealQuoteRaised + stateBefore.curveSurcharge, "RT-04: curve lost quote");
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: actorQuoteBal, actorProjBal, curveRealQuoteRaised, curveSurcharge (totalSurchargeCollected)
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §5 #3 (`valueOut <= valueIn` for bonding-curve buy/sell cycles).
RATIONALE: Buys price at the current tranche (≥ base). Sells pay `min(base, pro-rata)` Floor. Either a pricing or a pro-rata rounding regression would show up as profit.

---

PROPERTY_ID: [RT-05]
TYPE: SPECIFIC
ENGLISH: N cycles of a dust buy plus selling everything bought on a SteppedTranche curve never increase the actor's quote balance.
SOLIDITY_SKETCH:
```solidity
function steppedTrancheLaunch_dustCycle(uint256 curveSeed, uint256 q, uint8 n) public asActor {
    SteppedTrancheLaunch curve = trancheCurves[curveSeed % trancheCurves.length];
    q = clampBetween(q, 1, 1e12); n = uint8(clampBetween(n, 1, 20));
    snapshotBefore();
    for (uint256 i; i < n; i++) {
        if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) break;
        (uint256 out,) = curve.buy(q, 0, actor);
        if (out > 0) curve.sell(out, 0, actor);
    }
    snapshotAfter();
    lte(stateAfter.actorQuoteBal, stateBefore.actorQuoteBal, "RT-05: tranche dust cycle extracted quote");
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: actorQuoteBal
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §5 #3.
RATIONALE: Pattern C2 for the second curve. Dust is where the Ceil surcharge and Floor tokensOut/quoteOut meet.

---

PROPERTY_ID: [RT-06]
TYPE: SPECIFIC
ENGLISH: On any live hooked pool, an exact-input swap A→B followed by an exact-input swap of the entire B received back to A leaves the actor's wallet with no more A than before and exactly the same B. The check is wallet-only; claims credited to the actor are ignored. An exact-output variant (buy exactly `b` B, then sell exactly `b` B) gives the same bound.
SOLIDITY_SKETCH:
```solidity
function pool_swapRoundTrip(uint256 poolSeed, bool zeroForOne, uint256 amt, uint8 routeMode, bool dust) public {
    uint256 idx = _poolIdx(poolSeed); if (!_isPoolLive(idx)) return;
    amt = dust ? clampBetween(amt, 1, 1e6) : clampBetween(amt, 1e6, MAX_SWAP_AMOUNT);
    (bool trusted, bytes memory hd) = _route(routeMode, address(0));
    PoolKey memory key = poolKeys[idx];
    address a = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
    address b = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);
    snapshotBefore(); // actorBalA, actorBalB
    vm.startPrank(actor);
    BalanceDelta d1 = _router(trusted).swap(key, SwapParams(zeroForOne, -int256(amt), zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT), hd);
    int128 outB = zeroForOne ? d1.amount1() : d1.amount0();
    if (outB > 0) _router(trusted).swap(key, SwapParams(!zeroForOne, -int256(int128(outB)), !zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT), hd);
    vm.stopPrank();
    snapshotAfter();
    lte(stateAfter.actorBalA, stateBefore.actorBalA, "RT-06: swap round-trip profit in A");
    eq(stateAfter.actorBalB, stateBefore.actorBalB, "RT-06: B balance drift");
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: actorBalA, actorBalB (wallet ERC-20 balances of the two pool currencies)
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §5 #3: "no sequence of dust swaps ... can extract net positive value (`valueOut <= valueIn`)".
RATIONALE: This covers the whole waterfall (Floor cuts, the zero-liquidity fallback, buyback burn/donate, King mint) through a v4 round trip. A sign or rounding error in `afterSwapReturnDelta` would hand value back to the trader. MEV, circuit-breaker and vesting-cap reverts simply abort the cycle.

---

PROPERTY_ID: [RT-07]
TYPE: SPECIFIC
ENGLISH: Adding liquidity L to a fresh position and then removing the same L, with no swap in between, never returns more of either token than was deposited. Blocks are skipped past the JIT hold so the removal can succeed.
SOLIDITY_SKETCH:
```solidity
function pool_liquidityRoundTrip(uint256 poolSeed, uint8 rangeSeed, uint256 L, uint8 routeMode) public {
    uint256 idx = _poolIdx(poolSeed); if (!_isPoolLive(idx)) return;
    (int24 lo, int24 hi) = _range(rangeSeed);
    L = clampBetween(L, 1e15, MAX_LIQUIDITY);
    (bool trusted, bytes memory hd) = _route(routeMode % 2, address(0)); // honest identity only
    bytes32 salt = keccak256(abi.encode(actor, ++rtNonce)); // FRESH salt: avoid v4 fee auto-collect
    PoolKey memory key = poolKeys[idx];
    snapshotBefore(); // actorBal0, actorBal1
    vm.startPrank(actor);
    _router(trusted).modifyLiquidity(key, ModifyLiquidityParams(lo, hi, int256(L), salt), hd);
    vm.stopPrank();
    skipBlocks(7201); // > max JIT hold (7200)
    vm.startPrank(actor);
    _router(trusted).modifyLiquidity(key, ModifyLiquidityParams(lo, hi, -int256(L), salt), hd);
    vm.stopPrank();
    snapshotAfter();
    lte(stateAfter.actorBal0, stateBefore.actorBal0, "RT-07: LP round-trip profit token0");
    lte(stateAfter.actorBal1, stateBefore.actorBal1, "RT-07: LP round-trip profit token1");
}
```
GHOST_NEEDS: `uint256 rtNonce` (handler-local counter)
SNAPSHOT_NEEDS: actorBal0, actorBal1
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §5 #3: "LP deposit/withdraw cycles can [not] extract net positive value"
RATIONALE: This confirms the hook adds no positive delta on add/remove. If the hook ever gains add/remove return-delta flags, this catches it, together with v4's round-up-on-add / round-down-on-remove.

---

PROPERTY_ID: [RT-08]
TYPE: SPECIFIC
ENGLISH: For an unfilled limit order, place(x) followed by cancel returns exactly what the maker escrowed and never more. For native-input orders (`nativeOrderKey`, zeroForOne), the maker's ETH balance after cancel must be ≤ before place, and the hook's ETH balance must not fall.
SOLIDITY_SKETCH:
```solidity
function hookRigOrchestrator_limitOrderRoundTrip(uint256 poolSeed, int24 off, bool zeroForOne, uint128 x, bool nativeKey) public asActor {
    PoolKey memory key = nativeKey ? nativeOrderKey : poolKeys[_poolIdx(poolSeed)];
    if (nativeKey) zeroForOne = true;
    int24 sp = key.tickSpacing;
    int24 tick = (_currentTick(key) / sp + int24(clampBetween(int256(off), -20, 20))) * sp;
    x = uint128(clampBetween(x, 1, MAX_ORDER_AMOUNT));
    address input = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
    snapshotBefore(); // actorInputBal (ETH if input==0 else ERC20), hookInputBal
    uint256 id = orchestrator.placeLimitOrder(key, tick, zeroForOne, x);
    orchestrator.cancelLimitOrder(key, id);
    snapshotAfter();
    lte(stateAfter.actorInputBal, stateBefore.actorInputBal, "RT-08: place->cancel returned more than escrowed");
    gte(stateAfter.hookInputBal, stateBefore.hookInputBal, "RT-08: hook paid out unescrowed funds");
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: actorInputBal (actor.balance for native, else IERC20(input).balanceOf(actor)), hookInputBal (same for address(orchestrator))
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: Accounting identity: refunded escrow == deposited escrow for an order that never executed. docs/04 §5 #4 (makers can always cancel and recover escrowed tokens) promises a refund of the escrow, not more.
RATIONALE: This directly detects the native-order bug (x-ray I-21). `placeLimitOrder` is non-payable and skips the native transfer, so cancel pays ETH out of the hook's donated balance. The actor gains ETH and the hook loses it.

---

PROPERTY_ID: [RT-09]
TYPE: SPECIFIC
ENGLISH: When a tracked order's bucket has been filled and the maker claims, the maker receives exactly `inputAmount` of the input currency and nothing of the output currency. The claim is never worth more than the escrow.
SOLIDITY_SKETCH:
```solidity
// wrap hookRigOrchestrator_claimLimitOrder_clamped
uint256 inBefore = IERC20(input).balanceOf(order.maker);
uint256 outBefore = IERC20(output).balanceOf(order.maker);
orchestrator.claimLimitOrder(order.key, order.id);
eq(IERC20(input).balanceOf(order.maker) - inBefore, trackedInputAmount[order.id], "RT-09: claim != escrow");
eq(IERC20(output).balanceOf(order.maker), outBefore, "RT-09: claim paid output currency");
```
GHOST_NEEDS: `mapping(uint256 => uint128) trackedInputAmount` (record x at place; `_limitOrders` has no getter)
SNAPSHOT_NEEDS: none (inline)
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. It documents current behavior, where "filled" orders are never converted. If the code is later changed to pay output, flip this into a "≤ fair conversion" bound.
RATIONALE: A filled-bucket claim is the reverse operation of place. No conversion is performed, so any value above the escrow is free money.

---

PROPERTY_ID: [RT-10]
TYPE: SPECIFIC
ENGLISH: `withdrawClaim(pool, c, amount, to)` converts ledger claims to underlying exactly 1:1. The recipient's wallet rises by `amount`, `poolClaims[pool][c][claimant]` falls by `amount`, and the hook's ERC-6909 balance for `c` falls by `amount`. The same holds for `claimKingPot` with `round.amount`.
SOLIDITY_SKETCH:
```solidity
// inside _withdrawClaimAs
uint256 rBefore = c.balanceOf(to); uint256 lBefore = orchestrator.poolClaims(pid, c, claimant);
uint256 hBefore = poolManager.balanceOf(address(orchestrator), c.toId());
vm.prank(claimant); orchestrator.withdrawClaim(pid, c, amount, to);
eq(c.balanceOf(to) - rBefore, amount, "RT-10: payout != amount");
eq(lBefore - orchestrator.poolClaims(pid, c, claimant), amount, "RT-10: ledger debit != amount");
eq(hBefore - poolManager.balanceOf(address(orchestrator), c.toId()), amount, "RT-10: 6909 burn != amount");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none (inline; for native `c` use `to.balance`)
PRIORITY: LOW
GUARANTEE: SHOULD-HOLD
EVIDENCE: Identity in `HookRigBase.unlockCallback`: `burn(amount)` then `take(amount)`. The claim credit is 1:1 (`_creditPoolClaim` takes `amount` as 6909 and credits `amount`).
RATIONALE: This closes the credit↔withdraw pair. Any future fee or rounding added to payout would break it.

---

PROPERTY_ID: [RD-01]
TYPE: SPECIFIC
ENGLISH: A VirtualXYK buy matches the reference model built from pre-state: `quoteUsed = min(quoteIn, target − realQuoteRaised)`, `tokensOut = min(Y − ceilDiv(k, X + quoteUsed), allocation − curveTokensSold)`. The actor's quote debit equals `quoteUsed` exactly, so the ERC-20 path never over-pulls past the target.
SOLIDITY_SKETCH:
```solidity
// in virtualXYKLaunch_buy, before the call:
uint256 X = curve.virtualQuoteReserve(); uint256 Y = curve.virtualTokenReserve(); uint256 k = curve.invariantK();
uint256 used = min(qIn, target - curve.realQuoteRaised());
uint256 expOut = Y > ceilDiv(k, X + used) ? Y - ceilDiv(k, X + used) : 0;
expOut = min(expOut, alloc - curve.curveTokensSold());
uint256 qb = token0.balanceOf(actor); uint256 pb = proj.balanceOf(recipient);
(uint256 out, uint256 usedRet) = curve.buy(qIn, 0, recipient);
eq(usedRet, used, "RD-01: quoteUsed");
eq(qb - token0.balanceOf(actor), used, "RD-01: pulled more than quoteUsed");
eq(out, expOut, "RD-01: tokensOut != floor model");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none (inline pre-reads)
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 1B Anti-Bunni Rounding Law: "Credits leaving the pool/hook to a user: Always round DOWN". The NatSpec gives the formula: "newY = ceil(k / (X_virtual + quoteUsed)), tokensOut = floor(Y_virtual - newY)".
RATIONALE: Pattern D, preview against actual. It pins the rounding direction exactly, not just as a bound.

---

PROPERTY_ID: [RD-02]
TYPE: SPECIFIC
ENGLISH: A VirtualXYK sell matches the reference model: `quoteOut = min(X − ceilDiv(k, Y + t), realQuoteRaised)` (0 if negative), and the recipient receives exactly `quoteOut`.
SOLIDITY_SKETCH:
```solidity
uint256 X = curve.virtualQuoteReserve(); uint256 Y = curve.virtualTokenReserve(); uint256 k = curve.invariantK();
uint256 nx = ceilDiv(k, Y + t);
uint256 exp = X > nx ? X - nx : 0; exp = min(exp, curve.realQuoteRaised());
uint256 rb = token0.balanceOf(recipient);
uint256 out = curve.sell(t, 0, recipient);
eq(out, exp, "RD-02: quoteOut != floor model");
eq(token0.balanceOf(recipient) - rb, out, "RD-02: paid != quoteOut");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 1B: credits leaving round DOWN, which here means the new reserve is computed with Ceil.
RATIONALE: Pattern D for the reverse direction.

---

PROPERTY_ID: [RD-03]
TYPE: GLOBAL
ENGLISH: For every active VirtualXYK curve, `virtualQuoteReserve * virtualTokenReserve ≥ invariantK`. Also `virtualQuoteReserve ≤ ceilDiv(invariantK, virtualTokenReserve)`, meaning there is no quote-side gap the next seller could take for free.
SOLIDITY_SKETCH:
```solidity
function property_RD03_xykReserveRounding() public {
    for (uint256 i; i < xykCurves.length; i++) {
        VirtualXYKLaunch c = xykCurves[i];
        if (c.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) continue;
        uint256 X = c.virtualQuoteReserve(); uint256 Y = c.virtualTokenReserve(); uint256 k = c.invariantK();
        gte(X * Y, k, "RD-03a: X*Y < k");
        lte(X, ceilDiv(k, Y), "RD-03b: free quote gap for next seller");
    }
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD for (a) / EXPLORATORY for (b)
EVIDENCE: (a) x-ray I-15 plus docs/04 1B rounding law (reserves rounded Ceil). (b) none — inferred.
RATIONALE: (a) is the closed-form backstop for RT-01. (b) catches states where the price per token-wei approaches or exceeds 1 quote-wei (small `virtualTokenReserve` configs), which is when RT-01 profit appears.

---

PROPERTY_ID: [RD-04]
TYPE: SPECIFIC
ENGLISH: A SteppedTranche buy matches the model built from pre-state: `surcharge = ceil(quoteUsed * surchargeBps / 1e4)`, with `surchargeBps = currentAntiSnipeSurchargeBps()` read before the call. The surcharge is a fee coming in, so it rounds UP. `tokensOut = min(floor((quoteUsed − surcharge) * 2^96 / currentMarginalPriceQ96()), allocation − curveTokensSold)`. `realQuoteRaised` rises by exactly `quoteUsed − surcharge`.
SOLIDITY_SKETCH:
```solidity
uint16 bps = curve.currentAntiSnipeSurchargeBps(); uint256 P = curve.currentMarginalPriceQ96();
uint256 raised0 = curve.realQuoteRaised(); uint256 sold0 = curve.curveTokensSold(); uint256 sur0 = curve.totalSurchargeCollected();
uint256 qb = token0.balanceOf(actor);
(uint256 out, uint256 sur) = curve.buy(qIn, 0, recipient);
uint256 used = qb - token0.balanceOf(actor);
eq(sur, mulDivUp(used, bps, 10_000), "RD-04: surcharge not Ceil");
eq(curve.totalSurchargeCollected() - sur0, sur, "RD-04: surcharge accounting");
uint256 exp = min(mulDiv(used - sur, 1 << 96, P), alloc - sold0);
eq(out, exp, "RD-04: tokensOut not Floor at pre-buy tranche price");
// if not graduated by this buy:
eq(curve.realQuoteRaised() - raised0, used - sur, "RD-04: raised != net");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 1B: "Debts/fees entering ... Always round UP (Ceil)"; "Credits leaving ... Always round DOWN (Floor)".
RATIONALE: Pins both rounding directions on the tranche curve, including the `maxGrossInput` Ceil cap path near graduation.

---

PROPERTY_ID: [RD-05]
TYPE: SPECIFIC
ENGLISH: A SteppedTranche sell pays exactly `min(floor(t * basePriceQ96 / 2^96), floor(realQuoteRaised * t / curveTokensSold), realQuoteRaised)` from pre-state, and never more than the base-price redemption.
SOLIDITY_SKETCH:
```solidity
uint256 R = curve.realQuoteRaised(); uint256 S = curve.curveTokensSold();
(uint128 baseQ96,,,,,,,,,) = /* trancheConfig */;
uint256 base = mulDiv(t, baseQ96, 1 << 96);
uint256 pr = S > 0 ? mulDiv(R, t, S) : 0;
uint256 exp = min(min(base, pr), R);
uint256 out = curve.sell(t, 0, recipient);
eq(out, exp, "RD-05: tranche sell != floor(min(base, pro-rata))");
lte(out, base, "RD-05: paid above base redemption");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 1B: credits leaving round DOWN.
RATIONALE: The pro-rata leg depends on `curveTokensSold`, which uses saturating subtraction. This checks that it never rounds in the seller's favor.

---

PROPERTY_ID: [RD-06]
TYPE: GLOBAL
ENGLISH: For each SteppedTranche curve, `currentAntiSnipeSurchargeBps()` never increases between observations, never exceeds the configured `antiSnipeSurchargeBps`, and is 0 once `block.number ≥ launchCreationBlock + antiSnipeBlocks`. `currentMarginalPriceQ96() ≥ basePriceQ96`.
SOLIDITY_SKETCH:
```solidity
function property_RD06_trancheMonotone() public {
    for (uint256 i; i < trancheCurves.length; i++) {
        SteppedTrancheLaunch c = trancheCurves[i];
        uint16 s = c.currentAntiSnipeSurchargeBps();
        lte(s, cfgSurchargeBps(c), "RD-06: surcharge above config");
        if (ghosts.lastSurchargeSeen[address(c)] != 0 || ghosts.surchargeObserved[address(c)])
            lte(s, ghosts.lastSurchargeSeen[address(c)], "RD-06: surcharge increased");
        ghosts.lastSurchargeSeen[address(c)] = s; ghosts.surchargeObserved[address(c)] = true;
        gte(c.currentMarginalPriceQ96(), cfgBasePrice(c), "RD-06: price below base");
    }
}
```
GHOST_NEEDS: `mapping(address => uint16) lastSurchargeSeen; mapping(address => bool) surchargeObserved` (non-view property, or update in handlers)
SNAPSHOT_NEEDS: none
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred (Ceil-rounded linear decay).
RATIONALE: Pattern G monotonicity. Ceil rounding of the decay must not let the surcharge tick back up.

---

PROPERTY_ID: [RD-07]
TYPE: SPECIFIC
ENGLISH: For any exact-input swap on a live pool, the total withheld by the hook is at most `floor(gross * 2500 / 1e4)`, where `gross = traderNetOutput + withheld`. Withheld is measured as Δ hook ERC-6909 balance of the unspecified currency + Δ `totalAutoBurnedByPool[pool]` + Δ `totalLPRewardsDonated[pool]`.
SOLIDITY_SKETCH:
```solidity
// wrap pool_swap when amountSpecified < 0
Currency u = zeroForOne ? key.currency1 : key.currency0; // unspecified = output
uint256 h0 = poolManager.balanceOf(address(orchestrator), u.toId());
uint256 b0 = orchestrator.totalAutoBurnedByPool(pid); uint256 l0 = orchestrator.totalLPRewardsDonated(pid);
uint256 o0 = IERC20(Currency.unwrap(u)).balanceOf(actor);
/* swap */
uint256 withheld = (poolManager.balanceOf(address(orchestrator), u.toId()) - h0)
                 + (orchestrator.totalAutoBurnedByPool(pid) - b0) + (orchestrator.totalLPRewardsDonated(pid) - l0);
uint256 net = IERC20(Currency.unwrap(u)).balanceOf(actor) - o0;
lte(withheld, mulDiv(net + withheld, 2500, 10_000), "RD-07: aggregate cut exceeds floor(25%)");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: hook6909Unspecified, autoBurned[pool], lpDonated[pool], actorOutputBal (before/after)
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/03: "Δ_total ... ≤ ⌊Y_out × MAX_AGGREGATE_CUT_BPS / 10000⌋". docs/04 1B: "Hook cuts ... Always round DOWN so the sum of parts never exceeds total swap output".
RATIONALE: Floor and the bounded-cut clamp must keep the sum of slices within the floored cap, including the buyback burn+donate path and arb recapture (which `_validateAggregateReturnDeltaBudget` does not count).

---

PROPERTY_ID: [RD-08]
TYPE: SPECIFIC
ENGLISH: On a POOL_MULTI swap, the fee-sharing split rounds the secondary share DOWN. Δ`poolClaims[POOL_MULTI][u][TREASURY]` ≤ `floor(floor(gross*200/1e4) * 2500 / 1e4)`, and Δ`poolClaims[POOL_MULTI][u][actors[2]]` ≥ 3 × Δ`poolClaims[...][TREASURY]`. For fuzz-registered pools (secondaryShareBps 5000), Δprimary ≥ ΔTREASURY.
SOLIDITY_SKETCH:
```solidity
uint256 t0 = orchestrator.poolClaims(pidMulti, u, TREASURY); uint256 p0 = orchestrator.poolClaims(pidMulti, u, actors[2]);
/* exact-input swap on POOL_MULTI; gross computed as in RD-07 */
uint256 dT = orchestrator.poolClaims(pidMulti, u, TREASURY) - t0;
uint256 dP = orchestrator.poolClaims(pidMulti, u, actors[2]) - p0;
lte(dT, mulDiv(mulDiv(gross, 200, 10_000), 2500, 10_000), "RD-08: secondary share not floored");
gte(dP, 3 * dT, "RD-08: primary < 3x secondary (split rounding favors secondary)");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: claims of TREASURY and actors[2] on the swapped pool for the unspecified currency
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 1B: cuts round DOWN. Code: `secondaryAmount = mulDiv(..., Floor); primaryAmount = total - secondary`.
RATIONALE: Checks the second-level split. Using ≥ for actors[2] stays robust when actors[2] is also the trader's referrer.

---

PROPERTY_ID: [RD-09]
TYPE: SPECIFIC
ENGLISH: On an exact-input swap, the claims credited across all claimants on that pool in the unspecified currency are at most `floor(gross*taxBps/1e4) + floor(gross*feeShareBps/1e4) + floor(gross*referralBps/1e4)`. No claim slice rounds up.
SOLIDITY_SKETCH:
```solidity
uint256 sumBefore = Σ_{a in claimants ∪ actors} orchestrator.poolClaims(pid, u, a);
/* exact-input swap, gross as in RD-07 */
uint256 dClaims = Σ_after - sumBefore;
uint256 cap = mulDiv(gross, taxBps(pid, isBuy), 1e4) + mulDiv(gross, shareBps(pid), 1e4) + mulDiv(gross, refBps(pid), 1e4);
lte(dClaims, cap, "RD-09: claim slices exceed sum of floored cuts");
```
GHOST_NEEDS: per-pool configured bps for setup pools (constants from `_multiBlockConfig` / XYK stack; fuzz-registered pools need a `mapping(PoolId => uint16[3]) cfgBps` recorded at registration)
SNAPSHOT_NEEDS: Σ claims on pool/currency
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/03 cut table ("Cut Formula (Floor Rounded)") and docs/04 1B.
RATIONALE: Pattern D-style upper bound per slice family.

---

PROPERTY_ID: [RD-10]
TYPE: SPECIFIC
ENGLISH: On exact-output swaps, the docs say percentage cuts on the gross input round UP. On a POOL_XYK exact-output sell (only the 100 bps tax applies), Δ`poolClaims[POOL_XYK][projectToken][actors[1]]` must equal `ceilDiv(grossIn * 100, 1e4)`, where `grossIn = actorProjectPaid − withheld`.
SOLIDITY_SKETCH:
```solidity
// pool_swap on POOL_XYK, zeroForOne = false (sell project=currency1), amountSpecified > 0 (exact-output quote)
uint256 c0 = orchestrator.poolClaims(pidXyk, projCur, actors[1]); uint256 pb = proj.balanceOf(actor);
/* swap */
uint256 withheld = orchestrator.poolClaims(pidXyk, projCur, actors[1]) - c0;
uint256 paid = pb - proj.balanceOf(actor);
uint256 grossIn = paid - withheld;
eq(withheld, mulDivUp(grossIn, 100, 10_000), "RD-10: exact-output cut not Ceil (docs/04 2.x)");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: tax recipient claim, actor project balance
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 line 68: "On `exactOutput` swaps, percentage cuts are computed against the gross input amount ... (using `Math.Rounding.Ceil` on added input cost)". docs/04 1B: "Debts/fees entering ... from a user: Always round UP".
RATIONALE: `_boundedCut` uses Floor for both directions, so this should fail whenever `grossIn*100 % 1e4 != 0`. That is a doc/code rounding mismatch in the trader's favor. Generalizes to any static-bps pool via Σ ceil(...) over active slices.

---

PROPERTY_ID: [RD-11]
TYPE: SPECIFIC
ENGLISH: `submitTWAMMOrder(total, duration)` adds a sell rate that rounds DOWN: Δ`sellRate` × duration ≤ totalAmount, and Δ`sellRate` == floor(total/duration).
SOLIDITY_SKETCH:
```solidity
(, uint128 r0For1Before, uint128 r1For0Before,,) = orchestratorHarness.twammState(pid);
orchestrator.submitTWAMMOrder(key, zeroForOne, total, dur);
(, uint128 r0For1After, uint128 r1For0After,,) = orchestratorHarness.twammState(pid);
uint256 dRate = zeroForOne ? r0For1After - r0For1Before : r1For0After - r1For0Before;
eq(dRate, total / dur, "RD-11: rate not floored");
lte(dRate * dur, total, "RD-11: streamed > submitted");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none. **Needs a harness getter** for internal `_twammStates[poolId]` (sellRate0For1 / sellRate1For0), e.g. an orchestrator test subclass exposing `twammState(PoolId)`.
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. No tokens currently move for TWAMM; this only guards the conversion direction.
RATIONALE: If TWAMM ever escrows `total`, a rate that rounds up would stream more than deposited.

---

PROPERTY_ID: [RD-12]
TYPE: SPECIFIC
ENGLISH: At graduation (checked in the same handler call that triggers it), the pool's initial price rounds DOWN against the seed ratio: `sqrtP² ≤ floor(tokensToSeed * 2^192 / quoteToSeed) < (sqrtP+1)²`, unless clamped to the MIN/MAX sqrt price. Here `quoteToSeed = realQuoteRaised` for XYK, and `realQuoteRaised + totalSurcharge − floor(totalSurcharge*kingBps/1e4)` for Stepped. The King seed must equal that floor.
SOLIDITY_SKETCH:
```solidity
// after virtualXYKLaunch_buy_toGraduation / steppedTrancheLaunch_buy_toGraduation, if state flipped to Graduated
(uint160 sp,,,) = StateLibrary.getSlot0(poolManager, curve.poolId());
uint256 ratio = mulDiv(lpTokenReserve, 1 << 192, quoteToSeed);
if (sp > TickMath.MIN_SQRT_PRICE + 1 && sp < TickMath.MAX_SQRT_PRICE - 1) {
    lte(uint256(sp) * sp, ratio, "RD-12: graduation price rounded up");
    gt((uint256(sp) + 1) * (sp + 1), ratio, "RD-12: graduation price not floor-sqrt");
}
// Stepped: (, , uint256 pot, ) = orchestrator.getCurrentKing(pid) delta == mulDiv(surcharge, kingBps, 1e4) when pot was empty/same currency
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: totalSurchargeCollected, King pot before graduation (Stepped)
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. The NatSpec states "spot-price continuity" but no rounding direction.
RATIONALE: Confirms the documented Floor and the King-seed split (Floor seed, remainder to LP), so seeding never overspends the curve's balances.
