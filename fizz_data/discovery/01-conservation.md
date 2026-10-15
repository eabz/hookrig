PROPERTY_ID: [CON-01]
TYPE: GLOBAL
ENGLISH: Global hook ERC-6909 solvency, checked with state the harness can already read. For every tracked currency c, the hook's ERC-6909 balance in PoolManager is at least the sum of all poolClaims ledger entries in c across every known pool and every claimant.
SOLIDITY_SKETCH:
for c in trackedCurrencies:
  uint256 owed;
  for p in poolKeys: for a in claimants: owed += orchestrator.poolClaims(p.toId(), c, a);
  gte(poolManager.balanceOf(address(orchestrator), c.toId()), owed, "CON-01: hook 6909 < sum(poolClaims)");
(claimants = actors + admin + TREASURY. That covers every beneficiary the harness can create: tax recipient actors[1], fee-share actors[2] or a fuzzed actor plus TREASURY, referrers, which are always actors, and poolAdmin, which is admin or actor.)
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/04 §5 #2, "sum(claims) <= actual_reserves" across any swap/modifyLiquidity/donate/claim sequence. x-ray E-1.
RATIONALE: All pools share one ERC-6909 balance per currency (x-ray I-1, E-1). If any path pays out more than it minted, the shortfall comes out of other pools' claim backing. Known ways this could happen: claimKingPot after King pot currency mixing (I-3/X-5), and seedKingPotFromLaunchCurve with no paired mint (I-2/X-1).

PROPERTY_ID: [CON-02]
TYPE: GLOBAL
ENGLISH: Full hook ERC-6909 solvency, as an exact equality. For every currency c, the hook's PoolManager ERC-6909 balance equals the sum of: all poolClaims in c, open King pots whose potCurrency is c, settled-but-unclaimed King rounds whose currency is c, and every pool's AutoBuyback reserveByCurrency[c]. The harness never transfers 6909 to the hook directly, so there are no other legitimate sources.
SOLIDITY_SKETCH:
for c in trackedCurrencies:
  uint256 owed = sumClaims(c);
  for p in poolKeys:
    (Currency potC, uint256 pot) = h.kingPot(p);                  // _kingStates[p].potCurrency / currentPotAmount
    if (potC == c) owed += pot;
    (uint64 rid,,,) = orchestrator.getCurrentKing(p);
    for r in 1..rid-1: (,Currency rc,uint256 amt,bool claimed) = h.settledRound(p,r); if(!claimed && rc==c) owed += amt;
    owed += h.buybackReserve(p, c);                               // _autoBuybackStates[p].reserveByCurrency[c]
  eq(poolManager.balanceOf(address(orchestrator), c.toId()), owed, "CON-02");
(Treat >= as the solvency failure and > as stranded value; report them separately.)
GHOST_NEEDS: none if harness getters exist. Otherwise vm.load of the storage slots.
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD for the `>=` direction. EXPLORATORY for strict equality.
EVIDENCE: docs/04 §5 #2 (solvency) and x-ray E-1 for `>=`. Equality is inferred from I-1, I-4 and I-5 (every credit is paired with a mint, every debit with a burn).
RATIONALE: This is the full form of E-1. It catches stranded reserves (FF-02 class), pot amounts recorded under the wrong currency (I-3), and unbacked seeds (X-1). NEEDS HARNESS GETTERS: _kingStates[p].potCurrency, _settledKingRounds[p][r] (winner, currency, amount, claimed), and _autoBuybackStates[p].reserveByCurrency[c]. Expose them via a HookRigOrchestrator test subclass deployed with the same CREATE2 mining, or via vm.load.

PROPERTY_ID: [CON-03]
TYPE: SPECIFIC
ENGLISH: Per-swap ERC-6909 delta identity. During any swap on pool p, the change in the hook's 6909 balance of the unspecified currency u equals the change in Σ poolClaims[p][u][*], plus the King pot contribution added in u, plus the change in reserveByCurrency[u] for p (negative when a buyback triggers and the prior reserve is burned). The hook's 6909 balance of the other currency does not change.
SOLIDITY_SKETCH:
// in pool_swap, before/after
int256 d6909 = after.hook6909[u] - before.hook6909[u];
int256 dClaims = after.sumClaims[p][u] - before.sumClaims[p][u];
int256 dPot = (after.roundId == before.roundId) ? after.pot - before.pot : after.pot;   // roll settles old pot first, then contribution
int256 dRes = after.reserve[p][u] - before.reserve[p][u];
eq(d6909, dClaims + (kingContribInU ? dPot : 0) + dRes, "CON-03");
eq(after.hook6909[other], before.hook6909[other], "CON-03b");
GHOST_NEEDS: none
SNAPSHOT_NEEDS: hook6909[c] for both pool currencies, sumClaims[p][c], King (roundId, pot) for p, and reserveByCurrency[p][c] (the last needs a harness getter)
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred (x-ray I-1, I-4, I-5, I-28 Δ-pairs)
RATIONALE: This localises any solvency drift to the specific swap that caused it, and catches mint/credit mismatches in the 8-block waterfall. Cases it covers: buyback trigger burns priorReserve = deployed - bbCut; pot mint versus pot credit; fee-share split credits; and the zero-liquidity fallback, which must not mint.

PROPERTY_ID: [CON-04]
TYPE: SPECIFIC
ENGLISH: withdrawClaim conservation and per-pool isolation. After withdrawClaim(p, c, amt, to) by a claimant: poolClaims[p][c][claimant] falls by exactly amt; the hook's 6909 balance in c falls by exactly amt; the ERC-20 (or ETH) balance of `to` rises by exactly amt; every other (pool, currency, account) ledger entry is unchanged.
SOLIDITY_SKETCH:
eq(before.claim[p][c][claimant] - after.claim[p][c][claimant], amt);
eq(before.hook6909[c] - after.hook6909[c], amt);
eq(after.bal[c][to] - before.bal[c][to], amt);          // to != poolManager
for (q,d,a) != (p,c,claimant): eq(after.claim[q][d][a], before.claim[q][d][a]);
GHOST_NEEDS: none
SNAPSHOT_NEEDS: full poolClaims matrix (poolKeys × trackedCurrencies × claimants), hook6909[c], and the ERC-20 balance of `to`
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/02 4.2 and docs/06 AV-01, "claims double-keyed per pool" / "No block in hookrig ever uses global state". The amount identity is the I-1 Δ-pair (poolClaims -= amount ↔ burn amount ↔ take amount).
RATIONALE: This is the pull-claim path all fee income flows through, and the per-pool isolation guarantee that AV-01 depends on.

PROPERTY_ID: [CON-05]
TYPE: SPECIFIC
ENGLISH: claimKingPot pays exactly the settled amount, in the currency that funded the round. After a successful claimKingPot(p, r, to): the total decrease of the hook's 6909 balance equals the round's settled pot. The whole decrease is in a single currency, and that currency is the only one recorded as having funded round r. The recipient receives exactly that amount.
SOLIDITY_SKETCH:
uint256 settled = ghost.kingSettled[p][r];
Currency fc = ghost.kingFundingCurrency[p][r];          // see CON-06
eq(before.hook6909[fc] - after.hook6909[fc], settled, "CON-05 wrong amount/currency");
for c != fc: eq(after.hook6909[c], before.hook6909[c]);
eq(after.bal[fc][to] - before.bal[fc][to], settled);
GHOST_NEEDS: kingSettled[pool][round], set whenever getCurrentKing(p).roundId increments in any handler, to the pre-call pot (processBuy rolls before adding the new contribution). kingFundingCurrency[pool][round] (see CON-06).
SNAPSHOT_NEEDS: getCurrentKing(p) for every pool before and after every handler; hook6909 for all trackedCurrencies
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 FF-03: pot contributions are restricted to projectCurrency, and mismatched seeds are routed to poolClaims[admin] "rather than corrupting potCurrency", so a claim burns from a single, correctly-funded currency. x-ray X-5.
RATIONALE: This is the direct check for lead #1. A SteppedTranche seed in currency0 lands in the empty pot, then a buy contribution in currency1 overwrites potCurrency and adds to the same amount. The claim then burns currency1 for the combined amount, consuming other pools' currency1 backing or reverting.

PROPERTY_ID: [CON-06]
TYPE: GLOBAL
ENGLISH: King pot currency purity. Within any single King round on any pool, all value added to the pot (graduation seed plus buy contributions) is in one currency.
SOLIDITY_SKETCH:
// ghost update: at SteppedTranche graduation, if getCurrentKing(p).pot increased by s -> ghost.kingAdded[p][rid][currency0] += s
//               after any swap on p with same rid and pot increased by d -> ghost.kingAdded[p][rid][projectCurrency(p)] += d
for p, rid(current and settled):
  uint n; for c in {key.currency0, key.currency1}: if (ghost.kingAdded[p][rid][c] > 0) n++;
  lte(n, 1, "CON-06 King pot mixes currencies");
GHOST_NEEDS: kingAdded[pool][round][currency] (uint256). kingFundingCurrency[pool][round] = the first currency added.
SNAPSHOT_NEEDS: getCurrentKing(p) (roundId, pot) before and after swaps and tranche buys; launchState of the curve before and after
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 FF-03, which says the fix prevents heterogeneous currency accumulation into the pot. x-ray I-3.
RATIONALE: Readable with no harness getters. It fires on the exact mixing sequence (seed currency0 into empty pot → exact-input buy contributes currency1) that the current code permits at HookRigOrchestrator.sol:435 + KingOfThePoolBlock processBuy.

PROPERTY_ID: [CON-07]
TYPE: SPECIFIC
ENGLISH: SteppedTranche graduation seed conservation. When a tranche buy flips launchState to Graduated, kingPotSeed = floor(totalSurchargeCollected * surchargeToKingPotBps / 10_000). The hook's 6909 balance of currency0 rises by exactly kingPotSeed. Exactly the same amount appears either in the pool's open King pot or in poolClaims[pool][currency0][poolAdmin].
SOLIDITY_SKETCH:
uint256 seed = mulDivDown(curve.totalSurchargeCollected(), cfg.surchargeToKingPotBps, 10_000);
eq(after.hook6909[c0] - before.hook6909[c0], seed);
eq((after.pot - before.pot) + (after.claim[p][c0][admin] - before.claim[p][c0][admin]), seed);
GHOST_NEEDS: none
SNAPSHOT_NEEDS: hook6909[currency0], getCurrentKing(p).pot, poolClaims(p, currency0, admin), curve.launchState
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 FF-03, "routes mismatched currency seeds to poolClaims[poolId][currency][admin]". Contract NatSpec on seedKingPotFromLaunchCurve and SteppedTrancheLaunch ("surcharges seed ... Round #1 KingOfThePool jackpot"). Mint and credit should pair (x-ray X-1).
RATIONALE: This checks the mint ↔ credit pair that spans two contracts (curve unlockCallback mint, then orchestrator seed credit). If the pot or the admin claim is credited without the matching mint, the seed is phantom.

PROPERTY_ID: [CON-08]
TYPE: GLOBAL
ENGLISH: ERC-20 limit-order escrow backing. For every ERC-20 currency, the hook's ERC-20 balance is at least the sum of inputAmount over all open, non-native limit orders whose input is that currency.
SOLIDITY_SKETCH:
for c in trackedCurrencies (non-native):
  uint256 esc; for o in trackedOrders: if(!o.closed && inputCurrency(o)==c) esc += o.inputAmount;
  gte(IERC20(c).balanceOf(address(orchestrator)), esc, "CON-08");
GHOST_NEEDS: extend TrackedOrder with inputAmount, zeroForOne and targetTick, set in hookRigOrchestrator_placeLimitOrder
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 FF-01 and the LimitOrdersBlock NatSpec, "makers can always cancel unfilled orders or claim filled orders" and recover their escrow. That requires the escrow to be held. docs/04 §5 #4 (withdrawal liveness).
RATIONALE: Escrow sits as raw ERC-20 in the hook, alongside AutoBurn's take-then-burn path and arbitrary donations. Any path that moves hook ERC-20 out (wrong currency in cancel/claim, burn without take) breaks maker liveness.

PROPERTY_ID: [CON-09]
TYPE: GLOBAL
ENGLISH: Native limit-order escrow backing. The hook's ETH balance is at least the sum of inputAmount over open native-input limit orders (nativeOrderKey, zeroForOne == true).
SOLIDITY_SKETCH:
uint256 esc; for o in trackedOrders: if(!o.closed && o.key.currency0.isAddressZero() && o.zeroForOne) esc += o.inputAmount;
gte(address(orchestrator).balance, esc, "CON-09");
// stricter variant, unmasked by donateETH:
gte(address(orchestrator).balance, esc + ghost.ethDonatedToHook - ghost.ethPaidFromDonations, ...) // or use CON-10
GHOST_NEEDS: TrackedOrder.inputAmount/zeroForOne (as in CON-08). Optional ethDonatedToHook (incremented in hookRigOrchestrator_donateETH).
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 FF-01 / LimitOrders NatSpec (escrow returned on cancel/claim). docs/04 §5 #2 solvency.
RATIONALE: This is lead #4 (x-ray I-21). placeOrder skips the transfer for a native input and is not payable, yet records inputAmount. Cancel then pays ETH out of whatever the hook holds, including donations. The property fails the moment a native order is placed while the hook holds less ETH than the order amount.

PROPERTY_ID: [CON-10]
TYPE: SPECIFIC
ENGLISH: Escrow receipt on placeLimitOrder. After placeLimitOrder, the hook's balance of the input currency (ERC-20, or ETH for native) has risen by exactly inputAmount, and the maker's balance has fallen by exactly inputAmount. After cancel or claim, the hook's balance falls by exactly the order's inputAmount and the maker receives it, in the same currency.
SOLIDITY_SKETCH:
// place
eq(after.hookBal[in] - before.hookBal[in], inputAmount, "CON-10 escrow not received");
eq(before.makerBal[in] - after.makerBal[in], inputAmount);
// cancel/claim
eq(before.hookBal[in] - after.hookBal[in], o.inputAmount); eq(after.makerBal[in] - before.makerBal[in], o.inputAmount);
GHOST_NEEDS: TrackedOrder.inputAmount/zeroForOne
SNAPSHOT_NEEDS: hook and maker balances (ERC-20 or ETH) of the order's input currency
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred (I-20/I-21 Δ-pairs)
RATIONALE: This catches the native-order gap without any masking from ETH donations. It also catches cancel/claim paying out the wrong currency for the key.

PROPERTY_ID: [CON-11]
TYPE: GLOBAL
ENGLISH: Limit-order bucket sum. For every (pool, targetTick, zeroForOne), bucket.totalInputAmount equals the sum of inputAmount over open (not claimed or cancelled) orders in that bucket.
SOLIDITY_SKETCH:
for each distinct (poolId, tick, dir) in trackedOrders:
  uint256 s; for o in trackedOrders matching: if(!o.closed) s += o.inputAmount;
  eq(h.limitBucket(poolId, tick, dir).totalInputAmount, s, "CON-11");
GHOST_NEEDS: TrackedOrder.targetTick/zeroForOne/inputAmount (orders placed with nativeOrderKey are keyed by that pool id)
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: Exact accounting identity. placeOrder +=, cancelOrder -= and claimOrder -= the same order.inputAmount (x-ray I-20, all write sites). No other writer of totalInputAmount exists.
RATIONALE: If the bucket drifts, a later maker's cancel or claim underflows and reverts (frozen funds), or filled-state marking is wrong. NEEDS HARNESS GETTER for _limitOrderBuckets[p][tick][dir].

PROPERTY_ID: [CON-12]
TYPE: GLOBAL
ENGLISH: Swap-points total. For every pool, totalPoolSwapPoints equals the sum of swapRewardPoints over every address that can be the resolved trader.
SOLIDITY_SKETCH:
for p in poolKeys:
  uint256 s; for t in traders: s += orchestrator.swapRewardPoints(p.toId(), t);
  eq(orchestrator.totalPoolSwapPoints(p.toId()), s, "CON-12");
// traders = actors ∪ {admin, address(plainRouter), address(trustedRouter)}  (routeMode 3 resolves to plainRouter)
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: LOW
GUARANTEE: SHOULD-HOLD
EVIDENCE: Exact identity. SwapRewardsLogic.accrue adds the same `points` to swapRewardPoints[p][trader] and totalPoolSwapPoints[p], and neither is ever decremented.
RATIONALE: This is a classic Σ parts = whole check. It also flags any resolved-trader identity outside the expected set (for example, the trusted router resolving to an unexpected address), because Σ < total would show up.

PROPERTY_ID: [CON-13]
TYPE: GLOBAL
ENGLISH: AutoBurn total matches what was actually destroyed. For each project currency c, the sum of totalAutoBurnedByPool over pools whose project currency is c equals c's initial totalSupply minus its current totalSupply, plus balanceOf(0xdEaD).
SOLIDITY_SKETCH:
for c in trackedCurrencies:
  uint256 s; for p in poolKeys: if (projectCurrency(p)==c) s += orchestrator.totalAutoBurnedByPool(p.toId());
  eq(s, ghost.initialSupply[c] - IERC20(c).totalSupply() + IERC20(c).balanceOf(DEAD), "CON-13");
// projectCurrency(p) = currency1 for every harness pool (isToken0ProjectToken=false everywhere)
GHOST_NEEDS: initialSupply[currency], recorded when the currency is pushed to trackedCurrencies. Valid because token0/token1 are minted only in setup and launch tokens are fixed-supply.
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred
RATIONALE: This checks the counter against what actually happened. It catches a take to the hook with no burn (tokens stranded in the hook), a counter increment without a take, and burns taken from the wrong currency. Note: AutoBurn on a pool with useTokenBurnCall where currency1 is token1 (a MockBurnableERC20) is included.

PROPERTY_ID: [CON-14]
TYPE: GLOBAL
ENGLISH: VirtualXYK quote-reserve identity. For every XYK curve, virtualQuoteReserve == curveConfig.virtualQuoteReserve + realQuoteRaised.
SOLIDITY_SKETCH:
for c in xykCurves: (uint128 vq,,,,,) = c.curveConfig(); eq(c.virtualQuoteReserve(), vq + c.realQuoteRaised(), "CON-14");
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: Exact identity (x-ray I-14). buy adds quoteUsed to both values, sell subtracts quoteOut from both, initialization sets realQuoteRaised = 0, and there are no other writers.
RATIONALE: If these two drift apart, the curve's pricing reserve and its real quote no longer match, which opens a buy/sell cycle that drains value (x-ray E-2).

PROPERTY_ID: [CON-15]
TYPE: GLOBAL
ENGLISH: VirtualXYK token-reserve identity. For every XYK curve, virtualTokenReserve + curveTokensSold == curveConfig.virtualTokenReserve.
SOLIDITY_SKETCH:
for c in xykCurves: (,uint128 vt,,,,) = c.curveConfig(); eq(c.virtualTokenReserve() + c.curveTokensSold(), vt, "CON-15");
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. The identity breaks if sell's `curveTokensSold > tokenAmountIn ? ... : 0` clamp ever triggers, i.e. someone sells more tokens than the curve has net sold.
RATIONALE: The saturating clamp in sell() is an untracked path. If it is reachable, virtualTokenReserve grows while curveTokensSold stops at 0, so the curve over-credits sellers on later sells and miscounts toward graduation.

PROPERTY_ID: [CON-16]
TYPE: GLOBAL
ENGLISH: Curve project-token balance matches its accounting before graduation. For every XYK or Tranche curve in ActiveBonding, the curve's project-token balance equals the supply sent to the curve at launch, minus curveTokensSold, plus tokens donated directly to the curve.
SOLIDITY_SKETCH:
for curve in xykCurves ∪ trancheCurves where launchState == ActiveBonding:
  eq(IERC20(token).balanceOf(curve), ghost.initialCurveSupply[curve] - curve.curveTokensSold() + ghost.tokensDonatedToCurve[curve], "CON-16");
// initialCurveSupply = totalSupply - vestingAmount (=1e27 in harness, vesting 0)
GHOST_NEEDS: initialCurveSupply[curve] (set in _registerLaunch). tokensDonatedToCurve[curve] (incremented in hookRigToken_donateToCurve, and in hookRigToken_transfer when `to` is the curve).
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred
RATIONALE: This is an internal-accounting = external-balance check on the token side. It catches the curveTokensSold saturation in sell() on both curves, and any mismatch between tokens transferred and tokens counted (for example, the tokensOut cap at remainingTokens).

PROPERTY_ID: [CON-17]
TYPE: GLOBAL
ENGLISH: Curve quote backing before graduation. For every XYK curve in ActiveBonding, the curve's quote balance is at least realQuoteRaised. For every Tranche curve in ActiveBonding, it is at least realQuoteRaised + totalSurchargeCollected. With no quote donations in the harness, both should hold with equality.
SOLIDITY_SKETCH:
for c in xykCurves (ActiveBonding): gte(token0.balanceOf(c), c.realQuoteRaised(), "CON-17a");
for c in trancheCurves (ActiveBonding): gte(token0.balanceOf(c), c.realQuoteRaised() + c.totalSurchargeCollected(), "CON-17b");
// strict variant: eq(...)
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD for `>=`. EXPLORATORY for `==`.
EVIDENCE: docs/06 FF-04, "buyers can always exit against realQuoteRaised" (the anti-freeze guarantee). x-ray I-17.
RATIONALE: This protects sell() liveness and graduation funding (quoteToSeed = realQuoteRaised + extraLpQuote, plus the kingPotSeed settle). Cap-and-refund, the ETH refund branch, and surcharge Ceil versus net accounting all touch these balances.

PROPERTY_ID: [CON-18]
TYPE: GLOBAL
ENGLISH: TWAMM streamed volume never exceeds submitted volume. For every pool and direction, accruedVirtualVolume (0→1 or 1→0) is at most the sum of totalAmount over TWAMM orders submitted in that direction. Equivalently, sellRate0For1 / sellRate1For0 equal the sum of rates of orders not yet expired.
SOLIDITY_SKETCH:
for p in poolKeys:
  (,uint128 r01,uint128 r10,uint256 v0,uint256 v1) = h.twammState(p);
  lte(v0, ghost.twammSubmitted[p][true],  "CON-18a");
  lte(v1, ghost.twammSubmitted[p][false], "CON-18b");
  // rate form: eq(r01, Σ ghost orders(p,true) with expiry > block.timestamp of rate)
GHOST_NEEDS: twammSubmitted[pool][dir] (Σ totalAmount). Per-order (rate, expiry), recorded in _hookRigOrchestrator_submitTWAMMOrder (rate = floor(totalAmount / duration)).
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: docs/06 FF-06 says streaming is checkpointed "up to min(block.timestamp, expiration)" and only the "unstreamed remainder" is refunded. That implies streamed ≤ submitted.
RATIONALE: This is lead #5 (x-ray I-22). expirationTimestamp is never read and rates are never decremented, so accrued volume grows without bound after expiry. NEEDS HARNESS GETTER for _twammStates[p].

PROPERTY_ID: [CON-19]
TYPE: GLOBAL
ENGLISH: PoolManager ERC-20 backs the hook's ERC-6909. For every non-native tracked currency, PoolManager's ERC-20 balance is at least the hook's 6909 balance in that currency. For native, PoolManager's ETH balance is at least the hook's native 6909.
SOLIDITY_SKETCH:
for c in trackedCurrencies: gte(IERC20(c).balanceOf(address(poolManager)), poolManager.balanceOf(address(orchestrator), c.toId()), "CON-19");
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred (v4 6909 claims are backed by PoolManager-held reserves)
RATIONALE: This is a cheap external-reality check that a donate, take or burn sequence in the waterfall has not left the hook's claims backed by LP principal.

PROPERTY_ID: [CON-20]
TYPE: GLOBAL
ENGLISH: Launch count consistency. launchpadFactory.totalLaunches() equals the number of launches the harness tracks, and tokenToCurve maps each launch token to its recorded curve.
SOLIDITY_SKETCH:
eq(launchpadFactory.totalLaunches(), launchTokens.length, "CON-20");
for i: eq(launchpadFactory.tokenToCurve(launchTokens[i]), poolCurves[launchPoolIdx(i)]);
GHOST_NEEDS: mapping from launch index to poolKeys index (or store curve per launch token)
SNAPSHOT_NEEDS: none
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred
RATIONALE: This is cosmetic accounting. It confirms every launch path increments the counter exactly once and records its curve.

Harness additions needed across this list:
- Getters, via a HookRigOrchestrator test subclass deployed with the same CREATE2 mining, or via vm.load:
  - `_kingStates[p].potCurrency`
  - `_settledKingRounds[p][r]`
  - `_autoBuybackStates[p].reserveByCurrency[c]`
  - `_limitOrderBuckets[p][tick][dir]`
  - `_twammStates[p]`
- Extend `TrackedOrder` with `inputAmount`, `zeroForOne` and `targetTick`.
- Ghosts:
  - King: `kingSettled`, `kingAdded` / `kingFundingCurrency`
  - Supply and curves: `initialSupply[c]`, `initialCurveSupply` / `tokensDonatedToCurve`
  - TWAMM: `twammSubmitted` and per-order (rate, expiry)
  - Optional: `ethDonatedToHook`
- Snapshots: hook 6909 per tracked currency, the poolClaims matrix, getCurrentKing for each pool, and the ERC-20/ETH balances of the hook, the maker and `to`.

CON-01, CON-06, CON-07, CON-09, CON-12, CON-13, CON-14, CON-15, CON-16, CON-17, CON-19 and CON-20 need no new getters. CON-09 and CON-16 still need ghost fields. CON-06 and CON-07 need only snapshots.
