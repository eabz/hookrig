Protocol type: this is several types at once.
- **AMM/DEX**: two bonding curves (VirtualXYK, SteppedTranche) that graduate into a v4 pool, plus the pool itself running through the hook.
- **Queue/Order**: LimitOrdersBlock buckets.
- **Staking/Rewards**: swap points and King pot rounds.
- **Token**: HookRigToken, a fixed-supply OpenZeppelin ERC-20.
- **Vault**: not applicable. There is no share-based vault. V-06 is mapped onto curve buys in SPEC-12.

Claim solvency, King currency mixing, hookData spoofing, TWAMM and anti-snipe are left to the other agents.

Harness prerequisites:
- (a) Move `TrackedOrder` and `trackedOrders` from HookRigOrchestratorHandler into Base so Properties can read them. Extend the struct with `targetTick`, `zeroForOne`, `inputAmount` and `inputCurrency`.
- (b) Add a getter for `_limitOrderBuckets`: a test subclass of HookRigOrchestrator that exposes it, or `vm.load` of the mapping slot.

Strongest leads I found while adapting templates, all checked by hand against the harness defaults:
- **SPEC-08, graduation price jump.** At graduation the v4 pool price is about 6.7% off the XYK curve's marginal price, and about 17–20% off for Tranche. This contradicts docs/04 §5 #5 ("exact marginal curve price").
- **SPEC-10, tranche skipping.** One large Tranche buy pays the entry tranche price for every tranche it crosses.
- **SPEC-17, limit orders never execute.** `claimLimitOrder` hands back the input currency, and `filledOutputAmount` is never written.
- **SPEC-16, fills can be skipped for good.** The 16-step traversal cap, together with `lastTick` jumping straight to the post-swap tick, can leave crossed buckets never filled.
- **SPEC-03 / SPEC-11, vesting tokens drain the curve.** Creator vesting tokens can be sold into a curve before graduation; the clamp `curveTokensSold → 0` lets that pull out buyers' quote.
- **SPEC-21, unsold tokens are stranded.** With default config the XYK curve keeps about 300M unsold tokens after graduation, and no function can ever move them.

---

PROPERTY_ID: SPEC-01
TYPE: GLOBAL
ENGLISH: For every VirtualXYK curve, the virtual constant product never drops below `invariantK`. Buys and sells round the reserve they recompute with Ceil, so k can only grow.
SOLIDITY_SKETCH:
```solidity
function property_xykConstantProductNonDecreasing() public {
    for (uint256 i; i < xykCurves.length; i++) {
        VirtualXYKLaunch c = xykCurves[i];
        if (c.launchState() == ITokenLaunchpad.LaunchState.Uninitialized) continue;
        gte(c.virtualQuoteReserve() * c.virtualTokenReserve(), c.invariantK(), "XYK: vQ*vT < k");
    }
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: VirtualXYKLaunch NatSpec: "virtual constant-product bonding curve `(X_0 + x_real) * Y_virtual = k`" and "Enforces directional Floor/Ceil rounding". Identity: newY = ceil(k/newX) gives newX*newY >= k on buy, and the same holds symmetrically on sell.
RATIONALE: AMM A-01/A-08 (k non-decreasing after swaps), applied to the virtual XYK curve.

PROPERTY_ID: SPEC-02
TYPE: GLOBAL
ENGLISH: For every XYK curve, `virtualQuoteReserve - realQuoteRaised` always equals the configured `curveConfig.virtualQuoteReserve` (X_0). Each buy and sell moves both values by exactly the same amount.
SOLIDITY_SKETCH:
```solidity
function property_xykQuoteReserveIdentity() public {
    for (uint256 i; i < xykCurves.length; i++) {
        VirtualXYKLaunch c = xykCurves[i];
        if (c.launchState() == ITokenLaunchpad.LaunchState.Uninitialized) continue;
        (uint128 x0,,,,,) = c.curveConfig();
        eq(c.virtualQuoteReserve(), uint256(x0) + c.realQuoteRaised(), "XYK: vQ != X0 + realQuoteRaised");
    }
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: NatSpec defines X_virtual = `X_0 + x_real`. Closed-form identity of `buy` (vQ += quoteUsed, real += quoteUsed) and `sell` (vQ -= quoteOut, real -= quoteOut).
RATIONALE: AMM reserve-consistency template (A-02 style), mapping virtual reserves to real reserves.

PROPERTY_ID: SPEC-03
TYPE: GLOBAL
ENGLISH: For every XYK curve, `virtualTokenReserve + curveTokensSold == curveConfig.virtualTokenReserve`. This assumes no project tokens circulate that were not bought from the curve. A break means the sell-side clamp `curveTokensSold > tokenAmountIn ? ... : 0` fired, which lets outside supply (creator vesting) sell into the curve and pull out buyers' quote.
SOLIDITY_SKETCH:
```solidity
function property_xykTokenReserveIdentity() public {
    for (uint256 i; i < xykCurves.length; i++) {
        VirtualXYKLaunch c = xykCurves[i];
        if (c.launchState() == ITokenLaunchpad.LaunchState.Uninitialized) continue;
        (, uint128 y0,,,,) = c.curveConfig();
        eq(c.virtualTokenReserve() + c.curveTokensSold(), uint256(y0), "XYK: vT + sold != Y0");
    }
}
```
GHOST_NEEDS: none. To reach the vesting path, the harness launch metadata needs `creatorVestingBps > 0`, plus a handler that calls `VestingWallet.release(token)` (via `launchpadFactory.tokenToCreatorVesting(token)`) and sells as the creator (admin).
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred
RATIONALE: AMM A-02/A-05 reserve consistency. Selling tokens that did not come from the curve is the curve-side form of "removing more than your share".

PROPERTY_ID: SPEC-04
TYPE: GLOBAL
ENGLISH: While a curve is in ActiveBonding, its real quote balance covers what it owes. XYK: `quoteBalance(curve) >= realQuoteRaised`. Tranche: `quoteBalance(curve) >= realQuoteRaised + totalSurchargeCollected`.
SOLIDITY_SKETCH:
```solidity
function _quoteBal(Currency q, address who) internal view returns (uint256) {
    return q.isAddressZero() ? who.balance : IERC20(Currency.unwrap(q)).balanceOf(who);
}
function property_curveQuoteBacking() public {
    for (uint256 i; i < xykCurves.length; i++) {
        VirtualXYKLaunch c = xykCurves[i];
        if (c.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) continue;
        gte(_quoteBal(c.quoteCurrency(), address(c)), c.realQuoteRaised(), "XYK: quote under-backed");
    }
    for (uint256 i; i < trancheCurves.length; i++) {
        SteppedTrancheLaunch c = trancheCurves[i];
        if (c.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) continue;
        gte(_quoteBal(c.quoteCurrency(), address(c)), c.realQuoteRaised() + c.totalSurchargeCollected(),
            "Tranche: quote under-backed");
    }
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 FF-04: "buyers can always exit against `realQuoteRaised`". The surcharge is spent at graduation (`kingPotSeed` plus `extraLpQuote`), so it must also be held.
RATIONALE: AMM A-06 (output ≤ reserve) and vault solvency, applied to curve escrow.

PROPERTY_ID: SPEC-05
TYPE: GLOBAL
ENGLISH: While a curve is in ActiveBonding, it holds enough project token for the rest of its allocation plus the LP reserve that graduation will seed: `balanceOf(curve) >= (curveTokenAllocation - curveTokensSold) + lpTokenReserve`. LaunchpadFactory never checks `curveTokenAllocation + lpTokenReserve <= totalSupply - vesting`. A fuzzed config can therefore sell tokens until graduation becomes impossible.
SOLIDITY_SKETCH:
```solidity
function property_curveTokenBacking() public {
    for (uint256 i; i < xykCurves.length; i++) {
        VirtualXYKLaunch c = xykCurves[i];
        if (c.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) continue;
        (,,, uint128 alloc, uint128 lp,) = c.curveConfig();
        gte(IERC20(c.projectToken()).balanceOf(address(c)), uint256(alloc) - c.curveTokensSold() + lp,
            "XYK: token under-backed");
    }
    // same for trancheCurves using trancheConfig().curveTokenAllocation / lpTokenReserve
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred
RATIONALE: AMM A-06 reserve sufficiency on the token side, needed for SPEC-07 graduation liveness.

PROPERTY_ID: SPEC-06
TYPE: GLOBAL
ENGLISH: Graduation is atomic.
- An ActiveBonding curve always has `realQuoteRaised < graduationQuoteTarget` and `curveTokensSold < curveTokenAllocation`.
- A Graduated curve's v4 pool is initialized (slot0 sqrtPrice != 0).
- `launchState` only moves forward: Uninitialized → ActiveBonding → Graduated.
SOLIDITY_SKETCH:
```solidity
function property_atomicGraduation() public {
    for (uint256 i; i < xykCurves.length; i++) {
        VirtualXYKLaunch c = xykCurves[i];
        (,, uint128 target, uint128 alloc,,) = c.curveConfig();
        if (c.launchState() == ITokenLaunchpad.LaunchState.ActiveBonding) {
            lt(c.realQuoteRaised(), target, "XYK: target reached but not graduated");
            lt(c.curveTokensSold(), alloc, "XYK: allocation sold but not graduated");
        } else if (c.launchState() == ITokenLaunchpad.LaunchState.Graduated) {
            (uint160 sp,,,) = StateLibrary.getSlot0(poolManager, c.poolId());
            gt(sp, 0, "XYK: graduated but pool uninitialized");
        }
    }
    // same for trancheCurves
    // monotonic: for each curve idx, uint8(stateAfter.launchState[idx]) >= uint8(stateBefore.launchState[idx])
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: `launchState[]` per entry in `poolCurves` (uint8, via `_launchState(curve)`)
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: VirtualXYKLaunch NatSpec: "atomically graduates into a Uniswap v4 pool". docs/06 AV-14 (cap-and-refund at the target). Code in both `buy` paths: `if (realQuoteRaised >= target || curveTokensSold >= allocation) _graduateToV4()`.
RATIONALE: Queue/state-machine template (G-03 valid transitions), applied to the launch lifecycle.

PROPERTY_ID: SPEC-07
TYPE: SPECIFIC
ENGLISH: Graduation never reverts. When an ActiveBonding curve gets a buy large enough to hit its target, from a funded actor who has approved the curve, the buy succeeds and the curve ends Graduated. The only allowed reverts are the curve's wallet-cap errors (`WalletCapExceededOnCurve` / `WalletCapExceededOnTranche`).
SOLIDITY_SKETCH:
```solidity
// inside virtualXYKLaunch_buy_toGraduation / steppedTrancheLaunch_buy_toGraduation, replacing the direct call:
vm.prank(actor);
try curve.buy(amount, 0, actor) {
    t(curve.launchState() == ITokenLaunchpad.LaunchState.Graduated, "graduation buy did not graduate");
} catch (bytes memory err) {
    bytes4 sel = bytes4(err);
    t(sel == VirtualXYKLaunch.WalletCapExceededOnCurve.selector, "graduation reverted"); // Tranche: WalletCapExceededOnTranche
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §5 #5: "Fuzz tests ... proving that graduation never reverts, refunds excess final buy amounts accurately".
RATIONALE: AMM add-liquidity liveness (A-04), applied to the graduation LP seed. Edge cases: `ratioX192` clamping, the `0.9999 * sqrt(q*t)` liquidity estimate vs held balances, and token-cap-triggered graduation with a tiny `realQuoteRaised`.

PROPERTY_ID: SPEC-08
TYPE: GLOBAL
ENGLISH: Graduation price continuity. Read the graduated pool's initial price (or, equivalently, the curve's frozen graduation formula). It must equal the curve's final marginal price within 1%.
- XYK: marginal = `vT/vQ` (token per quote); pool = `lpTokenReserve / realQuoteRaised`.
- Tranche: marginal = `2^96 / currentMarginalPriceQ96()`; pool = `lpTokenReserve / (realQuoteRaised + totalSurcharge - kingPotSeed)`.

Expected to fail with the default configs: XYK gives 3.75M vs 4.0M tokens per quote (about 6.7% off); Tranche gives about 8.3M vs about 10M (about 17–20% off). Last curve buyers overpay, and an arbitrage opens instantly.
SOLIDITY_SKETCH:
```solidity
function property_graduationPriceContinuity() public {
    for (uint256 i; i < xykCurves.length; i++) {
        VirtualXYKLaunch c = xykCurves[i];
        if (c.launchState() != ITokenLaunchpad.LaunchState.Graduated) continue;
        (,,,, uint128 lp,) = c.curveConfig();
        // compare lp/real vs vT/vQ via cross-multiplication: lp*vQ vs vT*real
        uint256 a = uint256(lp) * c.virtualQuoteReserve();
        uint256 b = c.virtualTokenReserve() * c.realQuoteRaised();
        uint256 diff = a > b ? a - b : b - a;
        lte(diff * 100, b, "XYK: graduation price discontinuity > 1%");
    }
    for (uint256 i; i < trancheCurves.length; i++) {
        SteppedTrancheLaunch c = trancheCurves[i];
        if (c.launchState() != ITokenLaunchpad.LaunchState.Graduated) continue;
        (,,,,, uint128 lp,,,, uint16 kingBps) = c.trancheConfig();
        uint256 seed = c.totalSurchargeCollected() * kingBps / 10_000;
        uint256 quoteToSeed = c.realQuoteRaised() + c.totalSurchargeCollected() - seed;
        // pool token/quote = lp/quoteToSeed ; curve token/quote = 2^96/priceQ96
        uint256 a = uint256(lp) * c.currentMarginalPriceQ96();
        uint256 b = quoteToSeed << 96;
        uint256 diff = a > b ? a - b : b - a;
        lte(diff * 100, b, "Tranche: graduation price discontinuity > 1%");
    }
}
```
Optional cross-check: a ghost records `slot0.sqrtPriceX96` in the buy handler on the transition into Graduated.
GHOST_NEEDS: optional `ghost_graduationSqrtPrice[curve]`
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §5 #5: graduation "initializes the v4 pool at the exact marginal curve price". docs/06 AV-14: "continuous `sqrtPriceX96`". VirtualXYKLaunch NatSpec: "spot-price continuity".
RATIONALE: AMM price-consistency template (A-07 execution or price integrity) at the curve-to-AMM migration boundary.

PROPERTY_ID: SPEC-09
TYPE: SPECIFIC
ENGLISH: No round-trip extraction on curves. An atomic buy-then-sell by one actor on an ActiveBonding curve returns no more quote than the buy spent: `quoteOut <= quoteUsed`.
SOLIDITY_SKETCH:
```solidity
// new handler: virtualXYKLaunch_roundTrip(curveSeed, q) / steppedTrancheLaunch_roundTrip(curveSeed, q)
uint256 q0 = token0.balanceOf(actor);
uint256 t0 = IERC20(curve.projectToken()).balanceOf(actor);
vm.prank(actor); curve.buy(q, 0, actor);
if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return; // graduated, sell disabled
uint256 got = IERC20(curve.projectToken()).balanceOf(actor) - t0;
if (got == 0) return;
vm.prank(actor); curve.sell(got, 0, actor);
lte(token0.balanceOf(actor), q0, "curve round-trip extracted value");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §5 #3: "no sequence of ... bonding curve buy/sell cycles ... can extract net positive value (`valueOut <= valueIn`)".
RATIONALE: AMM A-08 / no-free-lunch round trip.

PROPERTY_ID: SPEC-10
TYPE: GLOBAL
ENGLISH: Tranche schedule floor. The quote a SteppedTranche curve has raised is never less than the integral of the tranche price schedule over `curveTokensSold`. `buy` reads `currentMarginalPriceQ96()` once and prices the whole order at the entry tranche, so one large buy (`steppedTrancheLaunch_buy_toGraduation`) gets later tranches at the base price. Sells only remove quote at or below the base price, so they cannot break this bound.
SOLIDITY_SKETCH:
```solidity
function _trancheCost(SteppedTrancheLaunch c, uint256 sold) internal view returns (uint256 costQ96) {
    (uint8 n, uint128 base, uint128 step,, uint128 alloc,,,,,) = c.trancheConfig();
    if (n <= 1 || alloc == 0) return sold * base;
    uint256 per = uint256(alloc) / n;
    for (uint256 i; i < n && sold > 0; i++) {
        uint256 chunk = (i == n - 1 || sold < per) ? sold : per;
        costQ96 += chunk * (uint256(base) + i * step);
        sold -= chunk;
    }
}
function property_trancheScheduleFloor() public {
    for (uint256 i; i < trancheCurves.length; i++) {
        SteppedTrancheLaunch c = trancheCurves[i];
        if (c.launchState() == ITokenLaunchpad.LaunchState.Uninitialized) continue;
        // allow 1 wei rounding per buy (ghost_trancheBuys[c])
        gte((c.realQuoteRaised() + ghost_trancheBuys[address(c)]) << 96, _trancheCost(c, c.curveTokensSold()),
            "Tranche: tokens sold below tranche schedule");
    }
}
```
GHOST_NEEDS: `mapping(address => uint256) ghost_trancheBuys` (count of successful buys per curve)
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred (the "Anti-bundle stepped tranche curve" NatSpec implies step pricing but does not state the integral)
RATIONALE: AMM A-07 ("larger swaps get worse execution"), applied to a step-price curve.

PROPERTY_ID: SPEC-11
TYPE: SPECIFIC
ENGLISH: A buyer is never charged for tokens that were not delivered.
- XYK: after any buy, `vQ*vT < k + vQ`, so only Ceil rounding remains. A larger product means `tokensOut` was clamped to `remainingCurveTokens` while `quoteUsed` was charged in full.
- Tranche: `netQuote * 2^96 <= (tokensOut + 1) * priceQ96_before`.
- XYK sell: `vQ*vT < k + vT` unless `quoteOut` was capped by `realQuoteRaised`. That cap should only fire with outside supply (see SPEC-03).
SOLIDITY_SKETCH:
```solidity
// XYK buy handler post-call:
uint256 vQ = c.virtualQuoteReserve(); uint256 vT = c.virtualTokenReserve();
lt(vQ * vT, c.invariantK() + vQ, "XYK: buyer overcharged (allocation cap without refund)");
// XYK sell handler post-call:
lt(vQ * vT, c.invariantK() + vT, "XYK: sell quote capped by realQuoteRaised");
// Tranche buy handler: snapshot priceQ96 = c.currentMarginalPriceQ96(), surchargeBps, actor quote, recipient token bal
uint256 spent = qBefore - token0.balanceOf(actor);
uint256 got = tokAfter - tokBefore;
uint256 net = spent - Math.mulDiv(spent, surchargeBps, 10_000, Math.Rounding.Ceil);
lte(net << 96, (got + 1) * priceQ96, "Tranche: buyer charged for undelivered tokens");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: per-call `priceQ96`, `surchargeBps`, actor quote balance, recipient project-token balance
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred (the NatSpec "cap-and-refund at graduation" covers only the quote target, not the token-allocation cap)
RATIONALE: AMM A-05 proportionality (input matches output) at the edge where a cap clamps the output.

PROPERTY_ID: SPEC-12
TYPE: GLOBAL
ENGLISH: [Adapted from the mandatory V-06, since there is no share vault.] After any sequence of buys, sells and project-token donations to the curve, a reasonable buy on an ActiveBonding curve with unsold allocation must yield more than 0 tokens. The reasonable size is min(1e18, remaining to target). For XYK: `vT - ceil(k/(vQ+q)) > 0`. For Tranche: `(q - surcharge) * 2^96 / priceQ96 > 0`. Direct donations must not distort pricing state.
SOLIDITY_SKETCH:
```solidity
function property_curveNoZeroOutputForReasonableBuy() public {
    for (uint256 i; i < xykCurves.length; i++) {
        VirtualXYKLaunch c = xykCurves[i];
        if (c.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) continue;
        (,, uint128 target, uint128 alloc,,) = c.curveConfig();
        if (c.curveTokensSold() >= alloc) continue;
        uint256 q = min(1e18, uint256(target) - c.realQuoteRaised());
        uint256 newVT = Math.mulDiv(c.invariantK(), 1, c.virtualQuoteReserve() + q, Math.Rounding.Ceil);
        gt(c.virtualTokenReserve() > newVT ? c.virtualTokenReserve() - newVT : 0, 0, "XYK: 1e18 buy yields 0 tokens");
    }
    for (uint256 i; i < trancheCurves.length; i++) {
        SteppedTrancheLaunch c = trancheCurves[i];
        if (c.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) continue;
        uint256 q = 1e18;
        uint256 net = q - Math.mulDiv(q, c.currentAntiSnipeSurchargeBps(), 10_000, Math.Rounding.Ceil);
        gt((net << 96) / c.currentMarginalPriceQ96(), 0, "Tranche: 1e18 buy yields 0 tokens");
    }
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred (V-06 applied by analogy; there are no ERC-4626 shares)
RATIONALE: Vault V-06 inflation and grief template, restated for the conversion function (the bonding curve). Donation stress comes from `hookRigToken_donateToCurve`.

PROPERTY_ID: SPEC-13
TYPE: GLOBAL
ENGLISH: Launch-token supply conservation. Each HookRigToken's `totalSupply()` never exceeds its launch supply (1e9 ether), and the sum over every tracked holder equals `totalSupply()`. Tracked holders: actors, admin, TREASURY, the curve, poolManager, orchestrator, both routers, the creator vesting wallet and 0xdEaD. For token1 (the POOL_MULTI project token), burns match the hook's burn ledger: `ghost_token1Minted - token1.totalSupply() == Σ_pools totalAutoBurnedByPool[pool]`, summed over pools whose project currency is token1 with `useTokenBurnCall`.
SOLIDITY_SKETCH:
```solidity
function property_launchTokenSupplyConservation() public {
    for (uint256 i; i < launchTokens.length; i++) {
        IERC20 tk = IERC20(launchTokens[i]);
        lte(tk.totalSupply(), 1_000_000_000 ether, "HookRigToken supply increased");
        uint256 s = sumActorsERC20Balances(address(tk)) + tk.balanceOf(admin) + tk.balanceOf(TREASURY)
            + tk.balanceOf(launchpadFactory.tokenToCurve(address(tk))) + tk.balanceOf(address(poolManager))
            + tk.balanceOf(address(orchestrator)) + tk.balanceOf(address(trustedRouter)) + tk.balanceOf(address(plainRouter))
            + tk.balanceOf(launchpadFactory.tokenToCreatorVesting(address(tk))) + tk.balanceOf(address(0xdEaD));
        eq(s, tk.totalSupply(), "HookRigToken: untracked holder / supply mismatch");
    }
    eq(ghost_token1Minted - token1.totalSupply(), orchestrator.totalAutoBurnedByPool(poolKeys[POOL_MULTI].toId()) /* + other token1 burn pools */,
       "token1 burn != AutoBurn ledger");
}
```
GHOST_NEEDS: `ghost_token1Minted` (every mint of token1 in setup and handlers)
SNAPSHOT_NEEDS: none
PRIORITY: LOW
GUARANTEE: SHOULD-HOLD (supply upper bound); EXPLORATORY (tracked-holder sum and burn ledger)
EVIDENCE: HookRigToken NatSpec: "Fixed-supply, non-rebasing ERC-20".
RATIONALE: Token T-01 (totalSupply == Σ balances) plus AutoBurn reconciliation.

PROPERTY_ID: SPEC-14
TYPE: GLOBAL
ENGLISH: Limit-order escrow solvency. For each input currency, the orchestrator holds at least the sum of all open tracked orders' `inputAmount` in that currency. Native orders are checked against `address(orchestrator).balance`. This catches the I-21 path: native orders are recorded without any ETH being received.
SOLIDITY_SKETCH:
```solidity
function property_limitOrderEscrowSolvency() public {
    for (uint256 c; c < trackedCurrencies.length + 1; c++) {
        Currency cur = c < trackedCurrencies.length ? trackedCurrencies[c] : Currency.wrap(address(0));
        uint256 owed;
        for (uint256 i; i < trackedOrders.length; i++) {
            if (!trackedOrders[i].closed && trackedOrders[i].inputCurrency == cur) owed += trackedOrders[i].inputAmount;
        }
        uint256 held = cur.isAddressZero() ? address(orchestrator).balance : IERC20(Currency.unwrap(cur)).balanceOf(address(orchestrator));
        gte(held, owed, "limit-order escrow under-collateralized");
    }
}
```
GHOST_NEEDS: none. `TrackedOrder` needs `inputCurrency` and `inputAmount` and must move to Base.
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: LimitOrdersBlock NatSpec: "makers can always cancel unfilled orders and recover escrowed tokens". docs/04 §5 #4: limit-order makers can always withdraw or cancel.
RATIONALE: Queue Q-03 (queue size and escrow consistent), together with vault solvency.

PROPERTY_ID: SPEC-15
TYPE: GLOBAL
ENGLISH: Bucket accounting. For each (poolId, targetTick, zeroForOne) bucket used by tracked orders, `bucket.totalInputAmount` equals the sum of `inputAmount` over open tracked orders in that bucket. `placeOrder` adds; `cancelOrder` and `claimOrder` subtract.
SOLIDITY_SKETCH:
```solidity
function property_limitBucketAccounting() public {
    for (uint256 i; i < trackedOrders.length; i++) {
        TrackedOrder storage o = trackedOrders[i];
        uint256 sum;
        for (uint256 j; j < trackedOrders.length; j++) {
            TrackedOrder storage p = trackedOrders[j];
            if (!p.closed && PoolId.unwrap(p.key.toId()) == PoolId.unwrap(o.key.toId())
                && p.targetTick == o.targetTick && p.zeroForOne == o.zeroForOne) sum += p.inputAmount;
        }
        (uint128 total,,) = harnessOrchestrator.getLimitOrderBucket(o.key.toId(), o.targetTick, o.zeroForOne);
        eq(total, sum, "bucket.totalInputAmount != sum(open orders)");
    }
}
```
GHOST_NEEDS: none. Needs a harness getter for internal `_limitOrderBuckets[poolId][tick][zeroForOne]`, plus `targetTick`, `zeroForOne` and `inputAmount` on TrackedOrder.
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: closed-form accounting identity: `placeOrder` does `totalInputAmount += inputAmount`; `cancelOrder` and `claimOrder` do `-= order.inputAmount`.
RATIONALE: Queue Q-03 (enqueue +1, dequeue -1, size consistent).

PROPERTY_ID: SPEC-16
TYPE: GLOBAL
ENGLISH: Fill completeness. Take an open tracked order on a pool with `BIT_LIMIT_ORDERS`. If, since placement, a hook-processed swap moved the pool tick across `targetTick` in the filling direction, its bucket must be `filled`. Filling directions: `zeroForOne=false` fills on upward moves, `zeroForOne=true` on downward moves. Expected to fail in three cases:
- `MAX_TICK_FILLS_PER_SWAP = 16` truncation, combined with `lastTick` jumping straight to `postSwapTick`, skips buckets for good.
- `(prevTick/step)*step` truncates toward zero for negative ticks.
- A retro-registered pool (POOL_UNREGISTERED) never runs `_initLimitOrders`, so `lastTick` stays 0.
SOLIDITY_SKETCH:
```solidity
// in every pool_swap* handler: (,int24 pre,,) = getSlot0 before; (,int24 post,,) after;
// for each open trackedOrder o on that pool: ghost_minTick[o] = min(ghost_minTick[o], min(pre,post)); ghost_maxTick[o] = max(...)
function property_limitOrderCrossedImpliesFilled() public {
    for (uint256 i; i < trackedOrders.length; i++) {
        TrackedOrder storage o = trackedOrders[i];
        if (o.closed) continue;
        if ((orchestrator.getPoolEnabledBlocks(o.key.toId()) & HookPermissionMasks.BIT_LIMIT_ORDERS) == 0) continue;
        bool crossed = o.zeroForOne
            ? (ghost_placeTick[i] > o.targetTick && ghost_minTick[i] <= o.targetTick)
            : (ghost_placeTick[i] < o.targetTick && ghost_maxTick[i] >= o.targetTick);
        if (!crossed) continue;
        (,, bool filled) = harnessOrchestrator.getLimitOrderBucket(o.key.toId(), o.targetTick, o.zeroForOne);
        t(filled, "limit order tick crossed but bucket not filled");
    }
}
```
GHOST_NEEDS: `ghost_placeTick[orderIdx]`, `ghost_minTick[orderIdx]`, `ghost_maxTick[orderIdx]`
SNAPSHOT_NEEDS: pre/post tick per swap call
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred (NatSpec "claim/withdraw orders once their target tick has been crossed" implies crossing ⇒ fill, but not as a guarantee)
RATIONALE: Queue Q-02 (entries are processed when their trigger is reached, none skipped).

PROPERTY_ID: SPEC-17
TYPE: SPECIFIC
ENGLISH: Limit-order execution semantics. When a maker claims a filled order, they should receive the output currency: currency1 for `zeroForOne=true`, currency0 otherwise. Today `claimOrder` sends back `order.inputAmount` in the input currency and `filledOutputAmount` is never written. Filled orders are effectively no-ops, while LPs and makers see "filled" status.
SOLIDITY_SKETCH:
```solidity
// in hookRigOrchestrator_claimLimitOrder_clamped, around the call:
Currency outCur = o.zeroForOne ? o.key.currency1 : o.key.currency0;
uint256 outBefore = _bal(outCur, o.maker);
hookRigOrchestrator_claimLimitOrder(o.key, o.id); // success path only
gt(_bal(outCur, o.maker), outBefore, "filled limit order paid no output currency");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: maker balances of both currencies before and after the claim
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred (docs/06 FF-01 only says makers can "claim filled order"; the code comment says it intentionally returns escrow)
RATIONALE: Order-book template: a filled order must deliver the counter-asset.

PROPERTY_ID: SPEC-18
TYPE: GLOBAL
ENGLISH: Swap-points ledger. For every pool, `totalPoolSwapPoints[pool]` equals the sum of `swapRewardPoints[pool][a]` over every address the hook can resolve as trader: actors, admin, TREASURY, trustedRouter and plainRouter (plainRouter is the fallback for empty hookData). Both values never decrease.
SOLIDITY_SKETCH:
```solidity
function property_swapPointsLedger() public {
    for (uint256 p; p < poolKeys.length; p++) {
        PoolId id = poolKeys[p].toId();
        uint256 s = orchestrator.swapRewardPoints(id, address(trustedRouter)) + orchestrator.swapRewardPoints(id, address(plainRouter));
        for (uint256 i; i < claimants.length; i++) s += orchestrator.swapRewardPoints(id, claimants[i]);
        eq(orchestrator.totalPoolSwapPoints(id), s, "totalPoolSwapPoints != sum(trader points)");
        gte(stateAfter.totalPoints[p], stateBefore.totalPoints[p], "swap points decreased");
    }
}
```
GHOST_NEEDS: none. The set of resolvable traders must be closed; route mode 2 spoofs only actors.
SNAPSHOT_NEEDS: `totalPoints[]` per pool
PRIORITY: LOW
GUARANTEE: SHOULD-HOLD
EVIDENCE: closed-form identity in `SwapRewardsLogic.accrue`: `swapRewardPoints[pool][trader] += points; totalPoolSwapPoints[pool] += points`. docs/04: "Non-custodial accounting points".
RATIONALE: Staking S-01 (Σ user stakes == total) and S-04 (reward index monotonic).

PROPERTY_ID: SPEC-19
TYPE: SPECIFIC
ENGLISH: King jackpot payout. Rewards paid never exceed rewards allocated, and each settled round pays out exactly once, only to its winner, exactly the pot amount at the roll. Whenever `getCurrentKing(pool).roundId` increments during a handler call, a ghost records the pre-call `(king, pot)` as `settled[pool][oldRound]`. A successful `claimKingPot(pool, r, to)` must then:
- increase `to`'s balance by exactly `settled[pool][r].pot` in the pot currency;
- come from `msg.sender == settled[pool][r].king`;
- fail on every later attempt for the same round.

Within one round, `potAmount` never decreases.
SOLIDITY_SKETCH:
```solidity
// generic pre/post hook around every handler: for each pool p with BIT_KING_OF_THE_POOL
(uint64 r0, address k0, uint256 pot0,) = orchestrator.getCurrentKing(id);  // before
(uint64 r1,, uint256 pot1,) = orchestrator.getCurrentKing(id);              // after
if (r1 == r0) gte(pot1, pot0, "King pot decreased within a round");
else { eq(r1, r0 + 1, "King round skipped"); ghost_settled[id][r0] = Settled(k0, pot0 /* + this-call contribution bound */); }
// claimKingPot handler success path:
eq(balAfter - balBefore, ghost_settled[id][r].pot, "King payout != settled pot");
eq(actor, ghost_settled[id][r].king, "non-winner claimed King pot");
t(!ghost_kingClaimed[id][r], "King round claimed twice"); ghost_kingClaimed[id][r] = true;
```
GHOST_NEEDS: `mapping(PoolId => mapping(uint64 => Settled{address king; uint256 pot})) ghost_settled`, `ghost_kingClaimed`. A roll inside `processBuy` happens before that buy's contribution is added, so the pre-call pot is the settled amount.
SNAPSHOT_NEEDS: `getCurrentKing` tuple per King pool, before and after
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred (docs/06 AV-10 and AV-12 describe pull-based jackpot payouts and anti-dust resets, not the exact payout identity)
RATIONALE: Staking S-05/S-06 (total distributed ≤ allocated; no residual claim after payout).

PROPERTY_ID: SPEC-20
TYPE: GLOBAL
ENGLISH: Little value stays stranded in a graduated curve. After graduation an XYK or Tranche curve should hold at most dust of the project token (≤ 0.01% of `lpTokenReserve` plus rounding) and of quote. No function can ever move tokens out of a graduated curve. With default XYK config about 300M unsold tokens (`curveTokenAllocation - curveTokensSold`) stay locked forever, along with any tokens donated via `hookRigToken_donateToCurve`.
SOLIDITY_SKETCH:
```solidity
function property_noStrandedCurveBalances() public {
    for (uint256 i; i < xykCurves.length; i++) {
        VirtualXYKLaunch c = xykCurves[i];
        if (c.launchState() != ITokenLaunchpad.LaunchState.Graduated) continue;
        (,,,, uint128 lp,) = c.curveConfig();
        lte(IERC20(c.projectToken()).balanceOf(address(c)), uint256(lp) / 10_000 + 1, "XYK: project tokens stranded post-graduation");
        lte(token0.balanceOf(address(c)), c.realQuoteRaised() / 10_000 + 1, "XYK: quote stranded post-graduation");
    }
    // same for trancheCurves
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred
RATIONALE: AMM A-05 removal completeness, applied to the curve-to-pool migration. Unsold allocation is neither burned nor added to LP.

PROPERTY_ID: SPEC-21
TYPE: SPECIFIC
ENGLISH: No value extraction from a pool round trip. On any live pool, an atomic exact-input swap X token0 → token1 followed by swapping all received token1 back to token0 leaves the actor with at most X token0 net. All fees and cuts apply, including arb-recapture donation and the King, tax and referral cuts with the actor as trader.
SOLIDITY_SKETCH:
```solidity
// new handler pool_roundTrip(poolSeed, amount, routeMode):
uint256 idx = _poolIdx(poolSeed); if (!_isPoolLive(idx)) return;
uint256 a0 = token0Of(idx).balanceOf(actor); uint256 a1 = token1Of(idx).balanceOf(actor);
pool_swap(idx, true, -int256(amount), useTrusted, hookData);
uint256 got = token1Of(idx).balanceOf(actor) - a1;
if (got == 0) return;
pool_swap(idx, false, -int256(got), useTrusted, hookData);
lte(token0Of(idx).balanceOf(actor), a0, "pool round-trip extracted value");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §5 #3: "no sequence of dust swaps ... can extract net positive value (`valueOut <= valueIn`)".
RATIONALE: AMM A-01/A-08 through the hook's afterSwap waterfall. Self-referral, rebates and the trader-as-recipient tax and fee-share routing (actors[1] and actors[2] are recipients on POOL_MULTI) could make a round trip net-positive for that actor. The check should count the actor's own `poolClaims` gained during the trip as received value.
