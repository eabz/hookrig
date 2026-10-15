# Invariant Map

> HookRig | 40 guards | 33 inferred | 13 not enforced on-chain

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`if (_poolMeta[poolId].configured) revert PoolAlreadyConfigured(poolId)` · `HookRigOrchestrator.sol:81` · Makes the block bitmap a one-shot, first-come registration so a live stack cannot be reconfigured.

#### G-2
`if (isLaunchpad && msg.sender != launchpadFactory) revert OnlyLaunchpadFactory` · `HookRigOrchestrator.sol:83-84` · Only the factory may bind an `authorizedCurve`, which later gates pool initialization and pot seeding.

#### G-3
`if (msg.sender != meta.authorizedCurve && msg.sender != launchpadFactory) revert OnlyAuthorizedCurve` · `HookRigOrchestrator.sol:92-93` · Restricts graduation marking and the Anti-snipe clock reset to the curve/factory trust boundary.

#### G-4
`if (bitmap == 0) revert InvalidBlockBitmap(bitmap)` · `HookRigOrchestrator.sol:112` · Prevents a "configured" latch with no behaviour, which would permanently burn the PoolId's registration slot.

#### G-5
`if ((bitmap & FEE_BLOCKS_MASK) != 0 && !key.fee.isDynamicFee()) revert DynamicFeeFlagRequired()` · `HookRigOrchestrator.sol:114-115` · Fee blocks return an override fee; PoolManager only honours it on dynamic-fee pools.

#### G-6
`if (maxDeltaBps > MAX_AGGREGATE_AFTER_SWAP_BPS) revert AggregateReturnDeltaBpsExceeded` · `HookRigOrchestrator.sol:119-120` · Registration-time ceiling on summed configured cut bps (ArbRecapture excluded from the sum).

#### G-7
`if (meta.isLaunchpadPool && sender != meta.authorizedCurve && sender != launchpadFactory) revert UnauthorizedPoolInitializer` · `HookRigOrchestrator.sol:210-211` · Blocks pre-graduation front-running of the launchpad pool's initial price.

#### G-8
`if (msg.sender != meta.authorizedCurve && msg.sender != launchpadFactory) revert OnlyAuthorizedCurve` · `HookRigOrchestrator.sol:426-427` · Only trusted launch contracts may credit King pot / admin claims (credits carry no token transfer).

#### G-9
`if (amount == 0 || amount > available) revert InsufficientClaimBalance` · `HookRigBase.sol:95-96` · Caps every withdrawal at the caller's own per-pool claim ledger entry.

#### G-10
`onlyPoolManager` on `unlockCallback` · `HookRigBase.sol:110` · Only PoolManager can drive the burn-and-take payout path.

#### G-11
`onlyOwner` on `setLaunchpadFactory` / `setTrustedRouter` · `HookRigBase.sol:57,61` · Owner controls the launchpad trust root and router identity oracle.

#### G-12
`if (params.baseFee > params.maxFee || params.maxFee > MAX_DYNAMIC_FEE) revert` · `DynamicFeeBlock.sol:27-28` · Keeps the volatility fee band inside 5%.

#### G-13
`if (params.startingFee > cap) revert ManagedFeeExceedsCap` · `ManagedFeeBlock.sol:29-30` · Starting managed fee must respect the (≤5%) cap.

#### G-14
`if (caller != state.manager) revert UnauthorizedFeeManager` · `ManagedFeeBlock.sol:39` · Only the pool's fee manager may move the managed fee.

#### G-15
`if (newFee > state.feeCap) revert ManagedFeeExceedsCap` · `ManagedFeeBlock.sol:40` · Bounds manager discretion by the immutable cap.

#### G-16
`if (openHourUtc >= 24 || closeHourUtc >= 24 || openFee > MAX || closedFee > MAX) revert` · `MarketHoursFeeBlock.sol:17-21` · Valid schedule and ≤5% fees.

#### G-17
`if (params.launchFee < params.normalFee || params.launchFee > MAX_ANTI_SNIPE_LAUNCH_FEE) revert` · `AntiSnipeBlock.sol:25-26` · Decay must be downward and launch fee ≤ 80%.

#### G-18
`if (params.recaptureShareBps > MAX_ARB_RECAPTURE_SHARE_BPS) revert` · `ArbRecaptureBlock.sol:26-27` · Recapture share ≤ 80% of excess spread.

#### G-19
`if (msg.sender != _accessConfigs[poolId].manager) revert UnauthorizedAccessControlManager` · `AccessControlBlock.sol:59,65` · Only the access manager edits allowlist / merkle root.

#### G-20
`revert AccountNotAllowlisted(poolId, user)` · `AccessControlBlock.sol:37` · Gate for swaps / adds on private pools — evaluated against the *resolved* user.

#### G-21
`if (dev > cb.maxWindowTickDeviation) revert CircuitBreakerTriggered` · `CircuitBreakerBlock.sol:32-33` · Caps cumulative tick drift per rolling window.

#### G-22
`if (addedBlock > 0 && block.number < addedBlock + minHold) revert JITLiquidityCooldownActive` · `JITGuardBlock.sol:38-39` · Minimum LP hold, keyed by resolved owner + range + salt.

#### G-23
`if (delta > maxDelta) revert SwapPriceImpactExceeded` · `MEVProtectionBlock.sol:27-28` · Per-swap tick-impact ceiling.

#### G-24
`if (params.buyTaxBps > MAX_TAX_BPS || params.sellTaxBps > MAX_TAX_BPS) revert TaxExceedsHardCap` · `BuySellTaxBlock.sol:21-22` · 10% anti-rug ceiling at init.

#### G-25
`if (cfg.decayOnly && (newBuyTaxBps > cfg.buyTaxBps || newSellTaxBps > cfg.sellTaxBps)) revert` · `BuySellTaxBlock.sol:41-42` · Anti-honeypot decay-only mode (path has no external caller).

#### G-26
`if (params.burnOnBuyBps > MAX_AUTO_BURN_BPS) revert AutoBurnExceedsCap` · `AutoBurnBlock.sol:23-24` · Burn ≤ 5%.

#### G-27
`if (params.feeShareBps > MAX_FEE_SHARE_BPS || params.secondaryShareBps > 10_000) revert` · `FeeSharingBlock.sol:18-19` · Share ≤ 5% and split ≤ 100%.

#### G-28
`if (params.extraBuyFeeBps > MAX_LP_REWARD_BPS) revert LPRewardExceedsCap` · `LPRewardsBlock.sol:22-23` · LP reward ≤ 5%.

#### G-29
`if (params.potFeeOnBuyBps > MAX_KING_POT_BPS) revert KingPotBpsExceedsCap` · `KingOfThePoolBlock.sol:52-53` · Pot fee ≤ 5%.

#### G-30
`if (round.amount == 0 || round.claimed) revert RoundNotClaimable` · `KingOfThePoolBlock.sol:119` · Single-claim per settled round.

#### G-31
`if (msg.sender != round.winner) revert NotRoundWinner` · `KingOfThePoolBlock.sol:120` · Only the recorded winner may pull the pot.

#### G-32
`if (referrer == address(0) || referrer == trader) revert InvalidSelfReferral` · `ReferralSplitBlock.sol:32` · Blocks self-referral at registration.

#### G-33
`if (params.buybackFeeBps > MAX_AUTO_BUYBACK_BPS) revert AutoBuybackFeeExceedsCap` · `AutoBuybackBlock.sol:31-32` · Buyback ≤ 5%.

#### G-34
`if (newSoldTotal > maxAllowed) revert DailyVestingSellCapExceeded` · `VestingSellCapBlock.sol:59-60` · Per-identity daily sell cap.

#### G-35
`if (postBalance > maxAllowed) revert WalletCapExceeded` · `WalletCapBlock.sol:59-60` · Max-wallet on buys for the resolved recipient.

#### G-36
`if (order.maker != msg.sender) / claimedOrCancelled / poolId mismatch / bucket.filled` · `LimitOrdersBlock.sol:88-93, 111-116` · Maker-only, single settlement, correct-currency payout.

#### G-37
`if (durationSeconds == 0 || totalAmount < durationSeconds) revert InvalidTWAMMInterval` · `TWAMMBlock.sol:51` · Non-zero streaming rate.

#### G-38
`if (launchState != LaunchState.Uninitialized || msg.sender != factory) revert` · `VirtualXYKLaunch.sol:65`, `SteppedTrancheLaunch.sol:64`, `NativeTickLaunch.sol:46-47` · One-shot factory-only curve initialization.

#### G-39
`if (launchState != LaunchState.ActiveBonding) revert CurveNotActive` · `VirtualXYKLaunch.sol:86,152`, `SteppedTrancheLaunch.sol:105,175` · Curve trading only during bonding.

#### G-40
`if (uint160(token) <= uint160(quoteAddr)) revert SaltDoesNotSortTokenAsCurrency1` · `LaunchpadFactory.sol:186-187` · Guarantees project token is `currency1` so `zeroForOne == Buy`.

---

## 2. Inferred Invariants (Single-Contract)

Inferred invariants are derived from structural analysis of the source code. Each block below cites one of five extraction methods in its `Derivation` field:

- **Δ-pair (delta-pair) analysis** — two or more storage variables in the same function body that change by equal-and-opposite amounts, implying a conservation law.
- **Guard lift** — a `require` / `if-revert` on a storage variable, promoted to a global property after checking *every* write site.
- **State-machine edge** — a storage variable that transitions through discrete values with no reverse path.
- **Temporal predicate** — a check tied to `block.timestamp`, `block.number`, or a stored duration.
- **NatSpec-stated global property** — a developer-asserted invariant in NatSpec or docs.

Each block is classified into one of five **categories** by shape: `Conservation` · `Bound` · `Ratio` · `StateMachine` · `Temporal`.

---

#### I-1

`Conservation` · On-chain: **Yes**

> For credit/withdraw paths, every unit added to `poolClaims[pool][c][acct]` is matched by an equal ERC-6909 mint to the hook, and every unit removed is matched by an equal burn.

**Derivation** — Δ-pair: `HookRigBase.sol:83` (`currency.take(..., true)` mints claims) ↔ `HookRigBase.sol:84` (`poolClaims += amount`); `HookRigBase.sol:98` (`poolClaims -= amount`) ↔ `HookRigBase.sol:112` (`poolManager.burn`).

**If violated** — Ledger drifts from the hook's PoolManager claim balance.

---

#### I-2

`Conservation` · On-chain: **No**

> `seedKingPotFromLaunchCurve` increases `currentPotAmount` or `poolClaims[admin]` with no matching ERC-6909 mint in the same body.

**Derivation** — Δ-pair gap: `HookRigOrchestrator.sol:436` (`currentPotAmount += amount`) and `:439` (`poolClaims[...][admin] += amount`) have no paired mint; backing relies on the caller (see X-1).

**If violated** — Phantom pot/claim balances paid out of the hook's *global* per-currency ERC-6909 balance (shared by every pool).

---

#### I-3

`Conservation` · On-chain: **No**

> A King round's `currentPotAmount` is denominated entirely in `potCurrency`.

**Derivation** — Δ-pair: `KingOfThePoolBlock.sol:87` overwrites `potCurrency = cutCurrency` while `:88` adds to the existing `currentPotAmount`; `HookRigOrchestrator.sol:435` sets `potCurrency = currency` only when the pot is empty. Seed in quote (`SteppedTrancheLaunch.sol:227`, `currency0`) followed by a buy contribution in project token (`AfterSwapDeltaAggregator.sol:161`, `unspecified == project`) mixes units.

**If violated** — Settled round records `amount` in the wrong currency; claim burns more of one currency than was ever minted for that pot.

---

#### I-4

`Conservation` · On-chain: **Yes**

> On buys, every King pot contribution is backed by an equal ERC-6909 mint to the hook.

**Derivation** — Δ-pair: `AfterSwapDeltaAggregator.sol:168` (`manager.mint(address(this), id, potCut)`) ↔ `KingOfThePoolBlock.sol:88` (`currentPotAmount += potContribution`).

**If violated** — Pot claims unbacked.

---

#### I-5

`Conservation` · On-chain: **Yes**

> `reserveByCurrency[c]` equals the ERC-6909 minted for Auto-buyback in currency `c` minus amounts deployed.

**Derivation** — Δ-pair: `AfterSwapDeltaAggregator.sol:205` (`mint bbCut`) ↔ `AutoBuybackBlock.sol:52` (`reserve = newReserve`); trigger: `AutoBuybackBlock.sol:61` (`reserve = 0`) ↔ `AfterSwapDeltaAggregator.sol:201` (`burn priorReserve`) + `:216` donate `deployed`.

**If violated** — Buyback reserve unbacked or stranded.

---

#### I-6

`Bound` · On-chain: **Yes**

> Total hook cut per swap ≤ `floor(grossUnspecified * 2500 / 10_000)`, including ArbRecapture.

**Derivation** — guard-lift: `_boundedCut` (`AfterSwapDeltaAggregator.sol:233-237`) clamps against `maxAllowedTotalCut` (`:89`); all 8 cut write sites (`:96, :108, :123, :135, :150, :165, :178, :192`) route through it; `:221` only decreases.

**If violated** — Swapper loses more than the documented 25% ceiling.

---

#### I-7

`Bound` · On-chain: **No**

> The registration-time aggregate check covers every return-delta block.

**Derivation** — guard-lift: `_validateAggregateReturnDeltaBudget` (`AfterSwapDeltaAggregator.sol:45-74`) sums 7 blocks; ArbRecapture (effective cut up to 1000 bps, `ArbRecaptureBlock.sol:10`) is not included. Runtime cap (I-6) still bounds totals.

**If violated** — Configs at 25% configured budget plus Arb can saturate the runtime cap, starving later blocks in waterfall order (Referral/Buyback).

---

#### I-8

`Bound` · On-chain: **Yes**

> `lpFeeOverride ≤ LPFeeLibrary.MAX_LP_FEE` and ≤ max(enabled fee-block outputs); Anti-snipe may reach 800_000 (80%).

**Derivation** — guard-lift: `FeeAggregator.sol:47-49`; Anti-snipe cap `AntiSnipeBlock.sol:25`; dynamic/managed/market-hours ≤ 50_000 (`DynamicFeeBlock.sol:27`, `ManagedFeeBlock.sol:28`, `MarketHoursFeeBlock.sol:18`).

**If violated** — LP fee exceeds documented caps.

---

#### I-9

`Bound` · On-chain: **Yes**

> `_managedFeeStates[p].currentFee ≤ feeCap ≤ 50_000`.

**Derivation** — guard-lift: write sites `ManagedFeeBlock.sol:32` (stage, guarded `:29`) and `:43` (update, guarded `:40`).

**If violated** — Manager raises fee beyond cap.

---

#### I-10

`Bound` · On-chain: **Yes**

> `buyTaxBps, sellTaxBps ≤ 1000` for every pool.

**Derivation** — guard-lift: write sites `BuySellTaxBlock.sol:27` (init, guarded `:21`) and `:46-47` (update, guarded `:37`); update path `_updateBuySellTax` (`:66`) has no caller.

**If violated** — Tax above 10%.

---

#### I-11

`StateMachine` · On-chain: **Yes**

> `_poolMeta[p].configured`: `false → true`, never reversed.

**Derivation** — edge: `false@HookRigOrchestrator.sol:81 → true@:128`; no other writer.

**If violated** — Stack could be swapped mid-life.

---

#### I-12

`StateMachine` · On-chain: **Yes**

> `launchpadGraduated`: `false → true` for launchpad pools; no reverse path.

**Derivation** — edge: `!isLaunchpad@HookRigOrchestrator.sol:130 → true@:95`.

**If violated** — Graduation-dependent logic re-enabled.

---

#### I-13

`StateMachine` · On-chain: **Yes**

> Curve `launchState`: `Uninitialized → ActiveBonding → Graduated`.

**Derivation** — edge: `Uninitialized@VirtualXYKLaunch.sol:65 → ActiveBonding@:76 → Graduated@:179`; `SteppedTrancheLaunch.sol:64 → :72 → :204`; NativeTick `:46 → Graduated@:53`.

**If violated** — Buy/sell after graduation or double graduation.

---

#### I-14

`Conservation` · On-chain: **Yes**

> `VirtualXYKLaunch.virtualQuoteReserve == curveConfig.virtualQuoteReserve + realQuoteRaised`.

**Derivation** — Δ-pair: `VirtualXYKLaunch.sol:114` ↔ `:116` (`+quoteUsed`), `:169` ↔ `:170` (`-quoteOut`).

**If violated** — Price curve detaches from real raised quote.

---

#### I-15

`Ratio` · On-chain: **Yes**

> `virtualQuoteReserve * virtualTokenReserve ≥ invariantK` after every buy/sell.

**Derivation** — guard-lift: `Math.Rounding.Ceil` at `VirtualXYKLaunch.sol:103` and `:159`; reserve writes `:114-115`, `:168-169`; token cap `:107-109` and quote cap `:161-163` only reduce what leaves.

**If violated** — Round-trip value extraction from the curve.

---

#### I-16

`Bound` · On-chain: **Yes**

> `curveTokensSold ≤ curveTokenAllocation` (both curves).

**Derivation** — guard-lift: buy caps `VirtualXYKLaunch.sol:107-109`, `SteppedTrancheLaunch.sol:132-134`; sell writes saturate at 0 (`VirtualXYKLaunch.sol:171`, `SteppedTrancheLaunch.sol:196`).

**If violated** — Curve sells LP reserve tokens.

---

#### I-17

`Conservation` · On-chain: **Yes**

> Pre-graduation, the curve's quote balance ≥ `realQuoteRaised` (+ `totalSurchargeCollected` for Stepped).

**Derivation** — Δ-pair: `VirtualXYKLaunch.sol:98` (transferFrom `quoteUsed`) ↔ `:116`; `:170` ↔ `:173`. Stepped: `SteppedTrancheLaunch.sol:122` ↔ `:139-140`; `:195` ↔ `:198`.

**If violated** — Sells or graduation seeding revert / underpay.

---

#### I-18

`Bound` · On-chain: **Yes**

> Stepped `sell` pays ≤ base-price redemption and ≤ pro-rata share of `realQuoteRaised`.

**Derivation** — guard-lift: `SteppedTrancheLaunch.sol:182-190`; single write site `:195`.

**If violated** — Early sellers drain later buyers.

---

#### I-19

`StateMachine` · On-chain: **Yes**

> King `currentRoundId` strictly increases by 1 per roll; each `SettledKingRound.claimed` goes `false → true` once.

**Derivation** — edge: `_rollKingRound` `KingOfThePoolBlock.sol:129-` (`currentRoundId = finishedRound + 1`); `claimed=false@settle → true@:122`.

**If violated** — Double pot claim.

---

#### I-20

`Conservation` · On-chain: **Yes**

> `bucket.totalInputAmount == Σ inputAmount` of open orders in `(pool, tick, dir)`.

**Derivation** — Δ-pair: `LimitOrdersBlock.sol:67` (order write) ↔ `:76` (`+= inputAmount`); `:95` ↔ `:96`; `:118` ↔ `:119`.

**If violated** — Bucket fill state inconsistent with orders.

---

#### I-21

`Conservation` · On-chain: **No**

> Hook's token balance ≥ Σ open limit-order escrow per input currency.

**Derivation** — Δ-pair gap: `LimitOrdersBlock.sol:63-65` skips the transfer when `inputCurrency.isAddressZero()` (function not `payable`, `:185`) yet `:67-76` record `inputAmount`; payout `:99`/`:123` transfers native ETH from the hook.

**If violated** — Unbacked native orders paid from any ETH held by the hook.

---

#### I-22

`Temporal` · On-chain: **No**

> TWAMM sell rates stop streaming at `expirationTimestamp`.

**Derivation** — temporal: `expirationTimestamp` written `TWAMMBlock.sol:70` but never read; rates only `+=` (`:59`, `:61`), never decremented; `executePending` accrues `rate * elapsed` indefinitely (`:89-94`). No tokens are escrowed by `submitTWAMMOrder` (`:119-127`).

**If violated** — Virtual volume accounting diverges from submitted orders (accounting-only; no funds move).

---

#### I-23

`Temporal` · On-chain: **No**

> Anti-snipe fee is monotonically non-increasing after launch.

**Derivation** — temporal: `computeFee` decays from `startBlock` (`AntiSnipeBlock.sol:48-55`); `_resetAntiSnipeGraduationClock` (`:70-74`) rewrites `startBlock` on every `notifyPoolGraduated` call (`HookRigOrchestrator.sol:96-97`), which has no once-only latch.

**If violated** — Launch fee (≤80%) re-armed after trading began.

---

#### I-24

`Temporal` · On-chain: **Yes**

> Circuit-breaker window ≤ 86_400 s, so any trip auto-expires within 24 h.

**Derivation** — guard-lift: `CircuitBreakerBlock.sol:47-48` is the only `windowSeconds` writer; reset predicate `:26`.

**If violated** — Pool frozen indefinitely.

---

#### I-25

`Bound` · On-chain: **Yes**

> JIT `minLPHoldBlocks ≤ 7200`.

**Derivation** — guard-lift: single writer `JITGuardBlock.sol:55-57`.

**If violated** — LPs locked > ~24 h.

---

#### I-26

`StateMachine` · On-chain: **Yes**

> `traderReferrer[p][t]`: `address(0) → referrer` once (first-touch), never ≠ trader.

**Derivation** — edge: `0@ReferralSplitBlock.sol:33 → referrer@:34`; self check `:32`, resolve-time filter `:50-52`.

**If violated** — Referral hijack / self-rebate.

---

#### I-27

`Bound` · On-chain: **Yes**

> For a given resolved seller identity, `soldInEpoch ≤ floor(startOfEpochBalance * maxDailySellBps / 10_000)`.

**Derivation** — guard-lift: single writer `VestingSellCapBlock.sol:61` guarded by `:59`; epoch reset `:50-54`.

**If violated** — Daily cap exceeded for that identity (identity itself is spoofable — X-3).

---

#### I-28

`Conservation` · On-chain: **Yes**

> Per swap, `Σ(take + mint + donate − burn)` executed by the hook in the unspecified currency equals `totalHookDeltaUnspecified`.

**Derivation** — Δ-pair: each `totalCutAmount +=` site in `AfterSwapDeltaAggregator.sol:98-194` is paired with its settlement (`_creditClaimInternal`, `_executeAutoBurn`, `mint`, donate at `:216`); zero-liquidity fallback removes the donation share from both (`:221`).

**If violated** — PoolManager `CurrencyNotSettled` revert (swap DoS).

---

#### I-29

`Temporal` · On-chain: **No**

> Oracle is checkpointed for every pool with `BIT_ORACLE`.

**Derivation** — temporal: `updateCheckpoint` returns early if `!obs.initialized` (`OracleBlock.sol:25`); `initialized` is only set in `_initOracle` via `afterInitialize` (`HookRigOrchestrator.sol:230-231`), so stacks registered after initialization never checkpoint (same skip for TWAMM/LimitOrders/DynamicFee anchors `:233-247`).

**If violated** — Silent no-op oracle / stale anchors.

---

#### I-30

`Bound` · On-chain: **No**

> Pool manager can lower tax / rotate recipient (per spec).

**Derivation** — NatSpec: `BuySellTaxBlock.sol` — "supports decay-only anti-honeypot mode"; structural: `_updateBuySellTax` (`BuySellTaxBlock.sol:66`) has no external entry point.

**If violated** — Taxes immutable after registration (spec/code mismatch).

---

#### I-31

`Bound` · On-chain: **No**

> JIT exit penalty bps is applied on early LP exits.

**Derivation** — guard-lift: `jitExitPenaltyBps` written `JITGuardBlock.sol:57`, never read; `enforceOnRemove` (`:26-41`) only reverts.

**If violated** — Configured penalty silently ignored.

---

#### I-32

`Ratio` · On-chain: **Yes**

> Fee-sharing split: `primaryAmount + secondaryAmount == shareCut`, `secondaryAmount = floor(shareCut * secBps / 10_000)`.

**Derivation** — guard-lift: `FeeSharingBlock.sol:39-41`; single caller `AfterSwapDeltaAggregator.sol:138-141`.

**If violated** — Split leaks or over-credits.

---

#### I-33

`Temporal` · On-chain: **Yes**

> King round settles only when `block.timestamp ≥ roundDeadline` and a king and non-zero pot exist.

**Derivation** — temporal: `KingOfThePoolBlock.sol:82-83` and `:106-107`.

**If violated** — Premature pot finalization.

---

## 3. Inferred Invariants (Cross-Contract)

---

#### X-1

On-chain: **No**

> `seedKingPotFromLaunchCurve` assumes the caller already minted `amount` of ERC-6909 to the hook.

**Caller side** — `HookRigOrchestrator.sol:424-441` — credits pot / admin claims from the `amount` argument alone.

**Callee side** — `SteppedTrancheLaunch.sol:257-259` mints before calling `:226-228` (honours it); `launchpadFactory` (owner-settable instantly, `HookRigBase.sol:57-59`) can call with no mint.

**If violated** — Phantom claims withdrawn against the hook's global ERC-6909 balance.

---

#### X-2

On-chain: **No**

> The curve notifies the same orchestrator the factory registered the pool on.

**Caller side** — `VirtualXYKLaunch.sol:196`, `SteppedTrancheLaunch.sol:222,227`, `NativeTickLaunch.sol:56` call the implementation-immutable `hookOrchestrator`.

**Callee side** — `LaunchpadFactory.sol:72,91,109` accept a caller-supplied `hookContract` and register on it (`:166`); `notifyPoolGraduated` on any other orchestrator reverts `OnlyAuthorizedCurve` (`HookRigOrchestrator.sol:92-93`).

**If violated** — Graduating buy reverts; launch can never graduate.

---

#### X-3

On-chain: **No**

> `_resolveUser` returns the economic actor of the swap / liquidity action.

**Caller side** — Access control (`HookRigOrchestrator.sol:262-263, 320-321`), JIT guard (`:276-277, 298-299`), wallet cap (`:393`), vesting cap (`:400`), King/Referral/SwapRewards (`:379, :404`).

**Callee side** — `HookRigBase.sol:73-75` decodes any non-zero address from the first 32 bytes of caller-controlled `hookData`.

**If violated** — Allowlist, JIT hold, wallet cap and daily sell cap evaluated against an arbitrary address.

---

#### X-4

On-chain: **No**

> The registrant of a PoolKey's stack is the party that controls/initializes that pool, and registration precedes initialization.

**Caller side** — `registerPoolStack` (`HookRigOrchestrator.sol:79-87`) is permissionless for non-launchpad keys and does not check initialization state; `poolAdmin` defaults to `msg.sender` (`:123`).

**Callee side** — `_beforeInitialize` (`:201-219`) allows initialization of unconfigured pools; `_afterInitialize` anchors only if already configured (`:228-247`).

**If violated** — Third party front-runs or retro-registers a stack (taxes/fee-share/access control/circuit breaker) on someone else's pool.

---

#### X-5

On-chain: **No**

> `claimKingPot` pays `round.amount` in `round.currency` that the hook actually holds for that pot.

**Caller side** — `HookRigOrchestrator.sol:417-420` burns `reward` of `currency` from the hook's global ERC-6909 balance.

**Callee side** — `KingOfThePoolBlock.sol:87-88` and `HookRigOrchestrator.sol:435-436` (I-3 mixing).

**If violated** — Claim reverts (stuck pot) or consumes another pool's claims in that currency.

---

## 4. Economic Invariants

---

#### E-1

On-chain: **No**

> Global solvency: for every currency `c`, `PoolManager.balanceOf(hook, c) ≥ Σ poolClaims[*][c][*] + Σ King pots (open + settled-unclaimed) in c + Σ reserveByCurrency[c]`.

**Follows from** — `I-1` + `I-4` + `I-5` + `I-2` + `I-3` + `X-1` + `X-5`

**If violated** — Last claimants cannot withdraw; cross-pool contagion through the shared ERC-6909 balance.

---

#### E-2

On-chain: **Yes**

> No value extraction via VirtualXYK buy→sell round-trip.

**Follows from** — `I-14` + `I-15` + `I-17`

**If violated** — Curve quote drained by cycling.

---

#### E-3

On-chain: **Yes**

> Hook never withholds more than 25% of a swap's unspecified amount and always settles exactly what it withholds.

**Follows from** — `I-6` + `I-28`

**If violated** — Swapper over-charged or swap DoS.

---

#### E-4

On-chain: **No**

> Protection blocks (AccessControl, JIT, WalletCap, VestingSellCap) bind the actual trader/LP.

**Follows from** — `I-27` + `X-3`

**If violated** — Private pools, anti-whale and anti-dump rules are advisory only.

---

#### E-5

On-chain: **No**

> A pool's economics (taxes, fee recipients, access rules) reflect the pool creator's intent.

**Follows from** — `I-11` + `X-4`

**If violated** — Value redirection or swap DoS on pools the attacker does not own.
