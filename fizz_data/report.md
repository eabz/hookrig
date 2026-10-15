# Fuzzing Suite Report

## Suite Overview
- **Project**: HookRig. It is a single Uniswap v4 hook (`HookRigOrchestrator`) that composes up to 22 per-pool blocks, plus a token launchpad whose bonding curves graduate into orchestrator pools. The pre-audit context is in `x-ray/x-ray.md` (verdict FRAGILE) and `x-ray/invariants.md`.
- **Suite location**: `test/fizz/`
- **Contracts targeted**: HookRigOrchestrator (with HookRigBase, AfterSwapDeltaAggregator, FeeAggregator and all block libraries reached through it), VirtualXYKLaunch, SteppedTrancheLaunch, LaunchpadFactory, HookRigToken. NativeTickLaunch is deployed through the factory. Swaps, liquidity and donations go through the real Uniswap v4 `PoolManager` (`PoolManagerHandler`).
- **Scope**: only `src/` was audited. Uniswap v4 and OpenZeppelin run as real dependencies, and no findings are attributed to them.
- **Total handlers**: 61 public entry points across 7 handler files:
  - 42 primary (clamped, composite or round-trip)
  - 17 secondary (15 raw unclamped wrappers plus 2 dispatchers, `hookRigOrchestrator_secondary` and `launchpadFactory_secondary`)
  - 2 utilities (`setCurrentActor`, `fizz_probeAccumulatorGrief`)
- **Properties**: 56 spec IDs (26 global `GL-*`, 30 function-specific `SP-*`). They are implemented as 26 `property_GL*` public functions and 37 `property_SP*` internal checks. All 56 are `[x]` in `PROPERTIES.md`.

## Coverage Results
These figures come from cycle 2 (117 s, plateau at 9,242 branches), taken before properties were added. Source: `fizz_data/coverage-targets.md`.

| Contract | Target | Achieved | Status |
|----------|--------|----------|--------|
| HookRigOrchestrator | 80% | 94% | OK |
| HookRigBase | 80% | 82% | OK |
| AfterSwapDeltaAggregator | 80% | 99% | OK |
| FeeAggregator | 80% | 100% | OK |
| VirtualXYKLaunch | 80% | 86% | OK |
| SteppedTrancheLaunch | 80% | 88% | OK |
| NativeTickLaunch | 80% | 81% | OK |
| LaunchpadFactory | 80% | 80% | OK |
| Block libraries (King, LimitOrders, TWAMM, AutoBuyback, ArbRecapture, AntiSnipe, DynamicFee, CircuitBreaker, MEV, JIT, Vesting, WalletCap, AutoBurn, FeeSharing, Referral, SwapRewards, Oracle, MarketHours, LPRewards) | 80% | 80–100% | OK |
| AccessControlBlock / ManagedFeeBlock | 60% | 92% / 94% | OK |
| BuySellTaxBlock | adjusted (update path dead) | 40% | OK (intentional: the init and apply paths are covered, and the rest is unreachable) |
| HookPermissionMasks | 50% | 79% | OK (was 38% in cycle 1, before presetId fuzzing) |
| HookRigToken / TransientContext / PoolTokenDir | 50% | 83% / 85% / 100% | OK |
| HookRigPresets | skip | 0% | OK (intentional skip) |

Status legend: OK means achieved ≥ target, or an intentional skip. WARN means within 10 points below target. FAIL means more than 10 points below target. No contract is at WARN or FAIL.

## Skipped Paths
| Contract | Function / Path | Reason |
|----------|----------------|--------|
| HookRigPresets | All 12 compiled preset hooks | Each preset needs its own mined hook address, so none are deployed. The orchestrator's `presetId` path covers their bitmaps. |
| BuySellTaxBlock | `_updateBuySellTax` / `BuySellTaxLogic.update` | Nothing external calls it (dead code, x-ray I-30), so it cannot be reached. |
| Uniswap v4 core / periphery, OpenZeppelin | All | These are real dependencies and outside scope. They are exercised but not audited. |

## Campaign Results
- **Fuzzer used**: Medusa. Echidna 2.3.3 is installed but was not run.
- **Build**: `FOUNDRY_PROFILE=fuzz`. A `[profile.fuzz]` with `bytecode_hash = "ipfs"` was added to `foundry.toml` so Medusa can attribute coverage to contracts the harness deploys.
- **Duration**: two campaigns of 600 s each.
  - Pass 1: default settings.
  - Pass 2: shrinkLimit 100, warm corpus, and the two handlers for already-known bugs excluded.
- **Total calls**: 20,007 in pass 1 and 25,930 in pass 2.
- **Branches hit**: 13,423 in pass 1 and 13,600 in pass 2.
- **Corpus size**: 375 sequences after pass 1 and 397 after pass 2. There are 2,130 files in `corpus_medusa/call_sequences/`.
- **Failed / total sequences (Medusa counter)**: 30 / 1,466 in pass 1 and 32 / 1,998 in pass 2.
- **Violations found**: 82 shrunk failure files in `fizz_data/corpus_medusa/test_results/`. All were replayed deterministically in Foundry and map to **16 distinct violated properties**, which come from **14 root causes**.
  - 9 SHOULD-HOLD properties were violated, from 7 confirmed-bug root causes.
  - 7 EXPLORATORY properties were violated (leads for human review).
  - Triage found no harness bugs. The authoritative triage is `fizz_data/triage.md`.
- **Not surfaced by either campaign**: SP-02, SP-16, SP-17, SP-18, SP-25. SP-16 is reproduced by a targeted Foundry sequence (see below). The other four were neither surfaced nor reproduced.
- **Foundry repros**: 17 `test_repro_*` functions in `test/fizz/FoundryTester.sol`. All pass with `FOUNDRY_PROFILE=fuzz forge test --match-contract FoundryTester -vvv`. Each one asserts that the final call fails with `Panic(0x01)`.

### Violation Details

#### 1. GL-19 / SP-21: oracle int24 truncation freezes swaps and LP exits after about 23.3 h idle (highest severity)
- **Property violated**: `property_GL19_oracleBounds` (GL-19) and `property_SP21_lpExitLiveness` (SP-21). 10 failure files end in `property_GL19_oracleBounds`, and the rest surface inside `pool_removeLiquidity_full` / `pool_addLiquidity_clamped`.
- **Guarantee**: `SHOULD-HOLD` (both)
- **Assertion**:
  - GL-19: `gte(a.oLast, TickMath.MIN_TICK)`, "GL-19: oracle lastTick below MIN_TICK".
  - SP-21: `t(ok, "SP-21: full LP exit after the hold reverted")`.
- **Root cause**: `OracleLogic.updateCheckpoint` computes `int24 maxChange = int24(int256(uint256(elapsed)) * 100)` at `src/blocks/trading/OracleBlock.sol:32`. This truncates once `elapsed > 83,886 s`. The clamped tick then either falls below `MIN_TICK` (-8.28M), or `lastTick + maxChange` overflows and panics with 0x11. The function runs in `beforeSwap`, `beforeAddLiquidity` and `beforeRemoveLiquidity`. As a result, any oracle pool left idle for about 23.3 h reverts on every swap and LP exit, which freezes funds.
- **Severity assessment**: `protocol bug`
- **Reproducing sequence**: `vm.warp(≥ 84,000 s)` → `pool_addLiquidity_clamped` or `pool_removeLiquidity_full` on an oracle pool.
- **Foundry repro**: `test_repro_GL19_oracleBounds`, `test_repro_SP21_lpExitAfterHold`: PASS

#### 2. GL-03 / GL-02: King pot currency mixing leaves ERC-6909 claims under-backed across pools
- **Property violated**: `property_GL03_kingPotCurrencyPurity` (GL-03) and `property_GL02_fullBacking` (GL-02). Found in pass 2, with 2 files each ending in the global property. More surfaced inside `pool_swap_*` handlers.
- **Guarantee**: `SHOULD-HOLD` (both)
- **Assertion**:
  - GL-03: `eq(ghosts.kingMixedRounds, 0)`, "a King round received a second pot currency".
  - GL-02: `gte(_hook6909(c), fullSum[c])`, "hook ERC-6909 balance < total 6909 liabilities".
- **Root cause**:
  1. `HookRigOrchestrator.seedKingPotFromLaunchCurve` (`src/HookRigOrchestrator.sol:431-436`) seeds `currency0` into an empty pot.
  2. On the next buy, `KingOfThePoolBlock.processBuy` (`src/blocks/rewards/KingOfThePoolBlock.sol:87-88`) overwrites `potCurrency` with the project token and adds to the same `pot` amount.
  3. The round now mixes currencies, so the hook's shared ERC-6909 balance in the project currency no longer covers claims plus pots plus reserves.
  4. Because that balance is shared, the shortfall exposes other pools.
- **Severity assessment**: `protocol bug`
- **Reproducing sequence**: `steppedTrancheLaunch_buy_toGraduation` → `pool_swap_fullBalance` (exact-in buy). One 3-call GL-02 sequence did not reproduce outside Medusa. GL-02 does reproduce deterministically in a 22-call sequence with the same root cause.
- **Foundry repro**: `test_repro_GL03_kingPotCurrencyPurity`, `test_repro_GL02_fullBacking`: PASS

#### 3. SP-03: native limit orders are recorded without escrow
- **Property violated**: `property_SP03_limitOrderPlaceEscrow`. It fails in `hookRigOrchestrator_placeLimitOrder_clamped` (3 files), `hookRigOrchestrator_placeLimitOrder` (1) and `hookRigOrchestrator_limitOrderRoundTrip` (5).
- **Guarantee**: `SHOULD-HOLD`
- **Assertion**: `eq(hookDelta, inputAmount)`, "SP-03: hook input-currency balance did not rise by inputAmount".
- **Root cause**: `LimitOrdersLogic.placeOrder` (`src/blocks/trading/LimitOrdersBlock.sol:63`) skips the transfer when the input is native, and the entry point is non-payable, yet it still records `inputAmount`. Cancel and claim then pay out ETH from the hook's own balance, which drains ETH held for other purposes.
- **Severity assessment**: `protocol bug`
- **Reproducing sequence**: 1 call, `placeLimitOrder_clamped(nativeKey)` (or `limitOrderRoundTrip`).
- **Foundry repro**: `test_repro_SP03_nativeLimitOrderEscrow`: PASS

#### 4. SP-15: AccessControl bypass through spoofed hookData
- **Property violated**: `property_SP15_accessControlNoSpoof`. It fails inside `pool_swap_*` handlers.
- **Guarantee**: `SHOULD-HOLD`
- **Assertion**: `t(orchestrator.isAccountAllowlisted(pid, actor))`, "SP-15: non-allowlisted actor passed AccessControl".
- **Root cause**: `HookRigBase._resolveUser` (`src/base/HookRigBase.sol:67`) trusts `hookData[0:32]` from untrusted routers. AccessControl therefore checks the spoofed address, not the economic payer.
- **Severity assessment**: `protocol bug`
- **Reproducing sequence**: `setCurrentActor` → `pool_swap_*` (routeMode 2) on POOL_PRIVATE.
- **Foundry repro**: `test_repro_SP15_accessControlSpoof`: PASS

#### 5. GL-11: graduation price is not continuous with the curve
- **Property violated**: `property_GL11_graduationPriceContinuity` (5 files).
- **Guarantee**: `SHOULD-HOLD` (docs/04 §5 #5 states that continuity is exact)
- **Assertion**: `lte(diff * 100, curveSide)`, "graduation price differs from final curve price by more than 1%".
- **Root cause**: curves graduate at `lpTokenReserve / quoteToSeed`, not at the curve's final marginal price (`src/launchpad/curves/VirtualXYKLaunch.sol:184-195`, `src/launchpad/curves/SteppedTrancheLaunch.sol:221`). This creates an immediate price gap that can be arbitraged at graduation.
- **Severity assessment**: `protocol bug`
- **Reproducing sequence**: 1 call, `*_buy_toGraduation`.
- **Foundry repro**: `test_repro_GL11_graduationPriceContinuity`: PASS

#### 6. GL-17: TWAMM sell rates never expire
- **Property violated**: `property_GL17_twammBounded` (6 files).
- **Guarantee**: `SHOULD-HOLD`
- **Assertion**: `eq(st.sellRate0For1, rate0[i])`, "sellRate0For1 != sum of unexpired order rates" (the same check runs for `1For0`).
- **Root cause**: in `TWAMMLogic`, sell rates only ever increase with `+=` (`src/blocks/trading/TWAMMBlock.sol:59-61`), and `expirationTimestamp` is never read. Orders therefore stream forever, past their submitted volume.
- **Severity assessment**: `protocol bug`
- **Reproducing sequence**: `hookRigOrchestrator_secondary` (submit a TWAMM order) → time passes beyond the expiry.
- **Foundry repro**: `test_repro_GL17_twammBounded`: PASS

#### 7. SP-11: exact-output cut rounds down instead of the documented Ceil (low)
- **Property violated**: `property_SP11_exactOutputCeil`. It fails inside `pool_swap_dust` (6 files).
- **Guarantee**: `SHOULD-HOLD`
- **Assertion**: `eq(withheld, ceilDiv(grossIn * 100, 1e4))`, "exact-output sell tax not rounded up (Ceil)".
- **Root cause**: `_boundedCut` (`src/base/AfterSwapDeltaAggregator.sol:234`) uses `Math.Rounding.Floor` for exact-output swaps too. docs/04 and AV-02 specify Ceil on added input cost. The result is a 1-wei under-charge per exact-output swap.
- **Severity assessment**: `protocol bug` (low impact)
- **Reproducing sequence**: `virtualXYKLaunch_buy_toGraduation` → `pool_swap_dust` (exact-output sell).
- **Foundry repro**: `test_repro_SP11_exactOutputCutCeil`: PASS

#### 8. SP-19: stack registration allowed on a live pool (lead, strong)
- **Property violated**: `property_SP19_noRetroRegistration`. It fails inside `hookRigOrchestrator_secondary`.
- **Guarantee**: `EXPLORATORY`
- **Assertion**: `eq(sqrtPriceBefore, 0)`, "stack registered on an already-initialized pool".
- **Root cause**: `registerPoolStack` (`src/HookRigOrchestrator.sol:79`) is permissionless and is allowed after the pool is initialized. The first third party to call it configures, and permanently locks, the block stack of a live pool.
- **Severity assessment**: `needs human review`
- **Reproducing sequence**: 1 call, `hookRigOrchestrator_secondary` (register on POOL_UNREGISTERED after init).
- **Foundry repro**: `test_repro_SP19_registerOnLivePool`: PASS

#### 9. SP-30: a free uint128-max TWAMM order bricks submissions (lead, strong)
- **Property violated**: `property_SP30_accumulatorGrief`. It fails in `hookRigOrchestrator_accumulatorGrief` (6 files).
- **Guarantee**: `EXPLORATORY`
- **Assertion**: `t(status != PROBE_HONEST_FAILED)`, "honest small order blocked".
- **Root cause**: `submitTWAMMOrder` (`src/blocks/trading/TWAMMBlock.sol:119`) escrows nothing. A single free order of `totalAmount = type(uint128).max` with `duration = 1` overflows `sellRate`, and every later submission in that direction reverts.
- **Severity assessment**: `needs human review` (this looks like a real DoS, and the escrow gap compounds GL-17)
- **Reproducing sequence**: 1 call, `hookRigOrchestrator_accumulatorGrief`.
- **Foundry repro**: `test_repro_SP30_accumulatorGrief`: PASS

#### 10. GL-23: factory lacks an allocation + LP ≤ supply − vesting check (lead)
- **Property violated**: `property_GL23_curveTokenAccounting` (4 files).
- **Guarantee**: `EXPLORATORY`
- **Assertion**: `gte(bal, (alloc - sold) + lp)`, "curve cannot cover unsold allocation + LP reserve".
- **Root cause**: `LaunchpadFactory` never checks `curveTokenAllocation + lpTokenReserve ≤ totalSupply − vesting`. With creator vesting, the curve is under-funded for its own allocation plus LP reserve, so graduation or late buys can fail.
- **Severity assessment**: `needs human review`
- **Reproducing sequence**: `launchpadFactory_secondary` (launch with vesting).
- **Foundry repro**: `test_repro_GL23_curveTokenAccounting`: PASS

#### 11. SP-27: tranche buyer charged for tokens not delivered (lead)
- **Property violated**: `property_SP27_noUndeliveredChargeTranche`. It fails in `steppedTrancheLaunch_buy` (2 files) and `steppedTrancheLaunch_buySellRoundTrip` (1). That round-trip failure is SP-27 inside its buy leg, not SP-05. No curve round-trip profit was found.
- **Guarantee**: `EXPLORATORY`
- **Assertion**: `lte(net << 96, (out + 1) * priceBefore)`, "tranche buyer charged for undelivered tokens".
- **Root cause**: the SteppedTranche buy caps `tokensOut` at the remaining allocation, priced at the entry tranche, and does not refund the quote it did not use.
- **Severity assessment**: `needs human review` (a buyer can lose value at the graduation boundary)
- **Reproducing sequence**: `launchpadFactory_secondary` → `steppedTrancheLaunch_buy`.
- **Foundry repro**: `test_repro_SP27_trancheChargedUndelivered`: PASS

#### 12. GL-15: one buy can skip tranches (lead)
- **Property violated**: `property_GL15_trancheScheduleFloor`. Found in pass 2 (2 files).
- **Guarantee**: `EXPLORATORY`
- **Assertion**: `gte((rqr + buys) << 96, _trancheCost(curve, sold))`, "tranche buys paid below the price schedule".
- **Root cause**: `SteppedTrancheLaunch.buy` (`src/launchpad/curves/SteppedTrancheLaunch.sol:128-129`) prices the whole order at the entry tranche. One large buy therefore pays the base price across every tranche it crosses.
- **Severity assessment**: `needs human review`
- **Reproducing sequence**: `launchpadFactory_secondary` → `hookRigOrchestrator_claimLimitOrder_clamped` → `steppedTrancheLaunch_buy_toGraduation` → `property_GL15_trancheScheduleFloor`.
- **Foundry repro**: `test_repro_GL15_trancheScheduleFloor`: PASS

#### 13. SP-28: filled limit orders never execute (lead, design)
- **Property violated**: `property_SP28_filledOrderPaysOutput`. It fails in `hookRigOrchestrator_claimLimitOrder_clamped` (2 files).
- **Guarantee**: `EXPLORATORY`
- **Assertion**: `gt(outAfter, outBefore)`, "filled limit order claim paid no output currency".
- **Root cause**: `claimOrder` (`src/blocks/trading/LimitOrdersBlock.sol:123`) returns `inputAmount` in the input token. A filled order is never converted to the output currency, so the feature does not do what its name says.
- **Severity assessment**: `needs human review`
- **Reproducing sequence**: a long sequence that places, crosses and fills an order, then `claimLimitOrder_clamped`.
- **Foundry repro**: `test_repro_SP28_filledOrderPaysOutput`: PASS

#### 14. GL-26: unsold allocation locked forever (lead, design)
- **Property violated**: `property_GL26_noStrandedCurveValue` (15 files).
- **Guarantee**: `EXPLORATORY`
- **Assertion**: `lte(balance(project, curve), lp / 10_000 + 1)`, "project tokens stranded in graduated curve".
- **Root cause**: unsold curve allocation (about 300M tokens on XYK and about 600M on tranche curves) and any donations stay in graduated curves. No function can move them out.
- **Severity assessment**: `needs human review`
- **Reproducing sequence**: 1 call, `*_buy_toGraduation`.
- **Foundry repro**: `test_repro_GL26_noStrandedCurveValue`: PASS

#### Targeted repro, not a campaign finding: SP-16, JIT hold bypass through an identity switch
- **Property violated**: `property_SP16_jitHoldNoBypass`. Neither campaign surfaced it.
- **Guarantee**: `SHOULD-HOLD`
- **Assertion**: `gte(block.number, added + minHold)`, "liquidity removed before the JIT hold expired".
- **Root cause**: the liquidity is added through the plain router with honest hookData. The same position is then removed in the same block with empty hookData. The JIT key switches from the actor to the router, so the hold never applies.
- **Severity assessment**: `protocol bug`. This comes from a targeted repro and still needs confirmation by a campaign or human review.
- **Reproducing sequence**: `pool_addLiquidity_clamped(POOL_MULTI, …, routeMode 1)` → `pool_removeLiquidity_full(POOL_MULTI, …, routeMode 3)` in the same block.
- **Foundry repro**: `test_repro_SP16_jitHoldIdentitySwitch`: PASS

## Properties Implemented
| # | Property | Type | Guarantee | Confidence |
|---|----------|------|-----------|------------|
| GL-01 | property_GL01_claimSolvency | Global | SHOULD-HOLD | HIGH |
| GL-02 | property_GL02_fullBacking | Global | SHOULD-HOLD | MEDIUM (scans only the 256 most recent settled King rounds per pool) |
| GL-03 | property_GL03_kingPotCurrencyPurity | Global | SHOULD-HOLD | HIGH |
| GL-04 | property_GL04_limitOrderEscrow | Global | SHOULD-HOLD | HIGH |
| GL-05 | property_GL05_curveQuoteBacking | Global | SHOULD-HOLD | HIGH |
| GL-06 | property_GL06_claimsPullOnly | Global | SHOULD-HOLD | MEDIUM (skips the whole check after any withdraw call, and covers snapshotted claimants only) |
| GL-07 | property_GL07_bitmapLocked | Global | SHOULD-HOLD | HIGH |
| GL-08 | property_GL08_kingRoundTransitions | Global | SHOULD-HOLD | HIGH |
| GL-09 | property_GL09_launchLifecycle | Global | SHOULD-HOLD | HIGH |
| GL-10 | property_GL10_atomicGraduation | Global | SHOULD-HOLD | HIGH |
| GL-11 | property_GL11_graduationPriceContinuity | Global | SHOULD-HOLD | MEDIUM (1% tolerance is looser than the documented exact continuity) |
| GL-12 | property_GL12_xykProductNonDecreasing | Global | SHOULD-HOLD | HIGH |
| GL-13 | property_GL13_xykTokenIdentity | Global | EXPLORATORY | HIGH |
| GL-14 | property_GL14_xykQuoteIdentity | Global | SHOULD-HOLD | HIGH |
| GL-15 | property_GL15_trancheScheduleFloor | Global | EXPLORATORY | MEDIUM (1 wei of slack per buy) |
| GL-16 | property_GL16_crossedOrdersFilled | Global | EXPLORATORY | MEDIUM (tracked orders only; crossing is inferred from ghost tick extrema) |
| GL-17 | property_GL17_twammBounded | Global | SHOULD-HOLD | HIGH |
| GL-18 | property_GL18_antiSnipeNotRearmed | Global | SHOULD-HOLD | HIGH |
| GL-19 | property_GL19_oracleBounds | Global | SHOULD-HOLD | MEDIUM (the rate bound uses a lower-bound window start, so it is loose by design) |
| GL-20 | property_GL20_limitBucketSum | Global | SHOULD-HOLD | HIGH |
| GL-21 | property_GL21_bitmapGatedState | Global | SHOULD-HOLD | HIGH |
| GL-22 | property_GL22_permissionedChanges | Global | SHOULD-HOLD | HIGH |
| GL-23 | property_GL23_curveTokenAccounting | Global | EXPLORATORY | HIGH |
| GL-24 | property_GL24_autoBurnLedger | Global | EXPLORATORY | MEDIUM (assumes the project currency is `currency1` for every pool) |
| GL-25 | property_GL25_reasonableBuyNonZero | Global | EXPLORATORY | MEDIUM (closed-form model, not a live call; skips gaps under 1 gwei) |
| GL-26 | property_GL26_noStrandedCurveValue | Global | EXPLORATORY | MEDIUM (dust tolerance of lp/10,000 + 1) |
| SP-01 | property_SP01_withdrawClaimExact, property_SP01_fullWithdrawLive | Specific | SHOULD-HOLD | HIGH |
| SP-02 | property_SP02_kingPayoutExact, property_SP02_winnerClaimLive | Specific | SHOULD-HOLD | HIGH |
| SP-03 | property_SP03_limitOrderPlaceEscrow, _limitOrderRefundBounded, _honestSettleRevert | Specific | SHOULD-HOLD | HIGH |
| SP-04 | property_SP04_swapRoundTrip | Specific | SHOULD-HOLD | HIGH |
| SP-05 | property_SP05_curveRoundTrip | Specific | SHOULD-HOLD | HIGH |
| SP-06 | property_SP06_curveDustCycle | Specific | SHOULD-HOLD | HIGH |
| SP-07 | property_SP07_graduationLiveness | Specific | SHOULD-HOLD | HIGH |
| SP-08 | property_SP08_graduationPostconditions | Specific | SHOULD-HOLD | HIGH |
| SP-09 | property_SP09_swapDeltaIdentity | Specific | EXPLORATORY | HIGH |
| SP-10 | property_SP10_aggregateCutCap | Specific | SHOULD-HOLD | HIGH |
| SP-11 | property_SP11_exactOutputCeil | Specific | SHOULD-HOLD | MEDIUM (POOL_XYK and the tax claimant only; returns early when the delta does not fit the model) |
| SP-12 | property_SP12_xykBuyModel, property_SP12_xykSellModel | Specific | SHOULD-HOLD | HIGH |
| SP-13 | property_SP13_trancheBuyModel, property_SP13_trancheSellModel | Specific | SHOULD-HOLD | HIGH |
| SP-14 | property_SP14_swapIsolation | Specific | SHOULD-HOLD | HIGH |
| SP-15 | property_SP15_accessControlNoSpoof | Specific | SHOULD-HOLD | MEDIUM (skipped once a merkle root is set) |
| SP-16 | property_SP16_jitHoldNoBypass | Specific | SHOULD-HOLD | MEDIUM (depends on the ghost `lpAddBlock` key; the campaign did not reach the bypass) |
| SP-17 | property_SP17_vestingCapNoBypass | Specific | SHOULD-HOLD | MEDIUM (relies on ghost epoch balances; never violated) |
| SP-18 | property_SP18_vestingCapNoGrief | Specific | SHOULD-HOLD | MEDIUM (checks a single revert selector) |
| SP-19 | property_SP19_noRetroRegistration | Specific | EXPLORATORY | HIGH |
| SP-20 | property_SP20_oracleCheckpointLiveness | Specific | EXPLORATORY | MEDIUM (skipped whenever the clamp could bind) |
| SP-21 | property_SP21_lpExitLiveness | Specific | SHOULD-HOLD | HIGH |
| SP-22 | property_SP22_curveExitLiveness | Specific | SHOULD-HOLD | HIGH |
| SP-23 | property_SP23_noPrivilegeEscalation | Specific | SHOULD-HOLD | HIGH |
| SP-24 | property_SP24_noJitDonationCapture | Specific | EXPLORATORY | MEDIUM (1e12 quote-unit dust tolerance) |
| SP-25 | property_SP25_walletCapNoBypass | Specific | SHOULD-HOLD | MEDIUM (skipped after sunset or when the cap is 0 or ≥ 100%) |
| SP-26 | property_SP26_claimSlicesFloored | Specific | SHOULD-HOLD | HIGH |
| SP-27 | property_SP27_noUndeliveredChargeXYK, _noUndeliveredChargeTranche | Specific | EXPLORATORY | HIGH |
| SP-28 | property_SP28_filledOrderPaysOutput | Specific | EXPLORATORY | HIGH |
| SP-29 | property_SP29_lpRoundTrip | Specific | SHOULD-HOLD | HIGH |
| SP-30 | property_SP30_accumulatorGrief | Specific | EXPLORATORY | HIGH |

`PROPERTIES.md` status: 56 `[x]`, 0 `[-]`, 0 `[ ]`. No property is LOW confidence.

## Open TODOs
None. A scan of `test/fizz/` (Base.sol, Snapshots.sol, Properties.sol, handlers/, harness/, utils/, FoundryTester.sol) found no `TODO` comments.

## Next Steps
1. **Fix the confirmed bugs, highest severity first.**
   - **GL-19 / SP-21**: widen `maxChange` and the tick math in `OracleBlock.sol:31-36` to `int256`, then clamp to `[MIN_TICK, MAX_TICK]`.
   - **GL-03 / GL-02**: keep one funding currency per King round, or convert the seed. Do not overwrite `potCurrency` while the pot is non-zero.
   - **SP-03**: make the native path payable and check `msg.value == inputAmount`, or reject native input.
   - **SP-15**: only read `hookData` identity from trusted routers.
   - **GL-11**: seed graduation at the curve's final marginal price, or correct docs/04 §5 #5.
   - **GL-17**: retire expired sell rates.
   - **SP-11**: use Ceil on exact-output cuts.
   - **SP-16**: key the JIT hold on a stable identity, such as the position owner and salt.
2. **Triage the EXPLORATORY leads with the protocol owner.**
   - SP-19: gate `registerPoolStack` to before initialization, or to the pool creator.
   - SP-30: escrow TWAMM input.
   - GL-23: add the supply check to the factory.
   - SP-27 / GL-15: price buys across tranches and refund unused quote.
   - SP-28 / GL-26: decide whether these are intended design, and document or fix them.
3. **Harness false positives**: none were found, so no harness fix is needed.
4. **LOW-confidence properties**: none. Optionally tighten GL-11 from the 1% tolerance to an exact check once the graduation price is fixed. Lift the 256-round cap in GL-02 for longer campaigns.
5. **Coverage**: every contract met its target. To check behaviour beyond what this run reached, add a handler for the preset hooks only if their addresses can be mined in setup.
6. **Production validation**: each campaign ran 600 s, and branch growth was still rising slightly between passes (13,423 to 13,600).
   - Re-run after the fixes with the known-bug handlers re-enabled, for at least 24 h on Medusa.
   - Run a parallel Echidna campaign, which was not run here, to try to surface SP-02, SP-16, SP-17, SP-18 and SP-25.
   - Turn each confirmed repro into a regression test.

### Running the campaigns manually
From the project root:

```bash
FOUNDRY_PROFILE=fuzz medusa fuzz
FOUNDRY_PROFILE=fuzz echidna . --contract FuzzTester --config echidna.yaml
FOUNDRY_PROFILE=fuzz forge test --match-contract FoundryTester -vvv   # replay the 17 repros
```
