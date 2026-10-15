# X-Ray Report

> HookRig | 3094 nSLOC | 8477cac (`main`) | Foundry | 14/10/26

---

## 1. Protocol Overview

**What it does:** A single Uniswap v4 hook ("orchestrator") that composes up to 22 per-pool "blocks" (dynamic fees, taxes, burns, rewards, MEV/JIT guards, limit orders, TWAMM, oracle), plus a token launchpad whose bonding curves graduate into orchestrator pools.

- **Users**: Traders and LPs (through PoolManager routers), token creators (launchpad), claimants (tax/fee/referral recipients, King-of-the-Pool winners), limit-order makers.
- **Core flow**: `PoolManager.swap` → `beforeSwap` resolves an override LP fee → `afterSwap` withholds ≤25% of the unspecified amount and settles it as ERC-6909 claims, burns, or LP donations.
- **Key mechanism**: Per-PoolId `uint32` block bitmap, fixed at registration; single-pass `afterSwapReturnDelta` waterfall; pull-based per-pool claim ledger backed by the hook's *global* ERC-6909 balance in PoolManager.
- **Token model**: `HookRigToken` (fixed supply, burnable, permit) is always `currency1` of launchpad pools; quote is `currency0` (ETH or ERC-20).
- **Admin model**: `Ownable2Step` owner sets `launchpadFactory` and trusted routers instantly; per-pool managers (fee, access) and `poolAdmin` are chosen by whoever registers the stack.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Hook core | HookRigOrchestrator, HookRigBase, AfterSwapDeltaAggregator, FeeAggregator | 713 | Hook callbacks, registration, return-delta waterfall, fee resolution, claim ledger |
| Fee blocks | DynamicFee, ManagedFee, MarketHoursFee | 179 | LP fee override sources |
| Protection blocks | AntiSnipe, MEVProtection, JITGuard, ArbRecapture, AccessControl, CircuitBreaker | 330 | Per-swap / per-LP guards and arb capture |
| Token-rule blocks | BuySellTax, AutoBurn, WalletCap, VestingSellCap | 249 | Taxes, burn, anti-whale, daily sell cap |
| Reward blocks | KingOfThePool, FeeSharing, LPRewards, SwapRewards, ReferralSplit, AutoBuyback | 389 | Cuts credited / donated / pooled |
| Trading blocks | LimitOrders, TWAMM, Oracle | 326 | Order books, streaming orders, TWAP checkpoints |
| Launchpad | LaunchpadFactory, VirtualXYKLaunch, SteppedTrancheLaunch, NativeTickLaunch, HookRigToken | 645 | Token deploy, bonding curves, graduation into v4 |
| Libraries & presets | HookPermissionMasks, PoolTokenDir, TransientContext, HookRigPresets | 263 | Bitmaps, swap direction, transient snapshots, compiled presets |

### How It Fits Together

The core trick: one CREATE2-mined hook serves every pool, with each pool's behaviour selected by a bitmap; every value-moving block is a slice of a single `afterSwapReturnDelta` that the hook settles in the same callback.

### Swap Waterfall

```
Router → PoolManager.swap()
  ├─ HookRigOrchestrator._beforeSwap()          (:305)
  │    ├─ _resolveUser(sender, hookData)          ← hookData[0:32] can name any address
  │    ├─ AccessControlLogic.verifyAccess()       *gate against resolved user*
  │    ├─ OracleLogic / TWAMMLogic checkpoints
  │    ├─ TransientContext.storePreSwapSnapshot()
  │    └─ FeeAggregator._resolveBeforeSwapFee()   *max(dynamic, managed, mktHours, antiSnipe) | OVERRIDE*
  └─ HookRigOrchestrator._afterSwap() → _runAfterSwapPipeline()   (:357)
       ├─ MEVProtection / CircuitBreaker          *may revert swap*
       ├─ AfterSwapDeltaAggregator._executeAfterSwapDeltaWaterfall()
       │    ├─ Arb → Tax → Burn → FeeShare → LPRewards → King → Referral → Buyback
       │    ├─ each slice: _boundedCut() ≤ 25% total
       │    ├─ settle: mint ERC-6909 (claims/pot/reserve) | take→burn | donate
       │    └─ returns totalCut as hook delta     *must net to zero with PoolManager*
       └─ WalletCap / VestingSellCap / SwapRewards / LimitOrders tick scan
```

### Claim Withdrawal

```
Recipient → HookRigBase.withdrawClaim(poolId, currency, amount, to)   [nonReentrant]
  ├─ poolClaims[poolId][currency][msg.sender] -= amount               *per-pool ledger*
  └─ PoolManager.unlock() → unlockCallback()
       ├─ PoolManager.burn(hook, currency, amount)                    *global ERC-6909 balance*
       └─ PoolManager.take(currency, to, amount)
Winner → HookRigOrchestrator.claimKingPot(poolId, roundId, to) → same burn+take path
```

### Launch → Graduation

```
Creator → LaunchpadFactory.launchSteppedTranche(meta, quote, ..., hookContract, stackConfig, cfg, salt)
  ├─ new HookRigToken{salt}  (token > quote ⇒ currency1)
  ├─ hookContract.registerPoolStack(key, cfg{authorizedCurve})        *only factory may set curve*
  └─ SteppedTrancheLaunch(clone).initializeCurve()
Buyer → SteppedTrancheLaunch.buy()  … until realQuoteRaised ≥ target
  └─ _graduateToV4()
       ├─ PoolManager.initialize(key, sqrtP)  → _beforeInitialize: sender must be curve/factory
       ├─ hookOrchestrator.notifyPoolGraduated()    *impl-immutable orchestrator, not hookContract*
       ├─ PoolManager.unlock() → modifyLiquidity full range + mint kingPotSeed (quote) to hook
       └─ hookOrchestrator.seedKingPotFromLaunchCurve(poolId, currency0, seed)
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **DEX/AMM** with **token-launchpad (bonding curve)** characteristics

The hook mutates every swap's output (fees, return deltas, donations) and holds pooled claim balances for many pools; the launchpad adds constant-product and stepped curves that custody buyer quote until graduation.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Owner | Trusted | Instant `setLaunchpadFactory` (gates launchpad registration, graduation, and token-less pot/claim seeding) and `setTrustedRouter`; Ownable2Step only delays the seat transfer. |
| LaunchpadFactory / authorized curves | Trusted | Register launchpad stacks, initialize launchpad pools, reset Anti-snipe clock, credit King pot / admin claims with no transfer. |
| Stack registrant (`poolAdmin`) | Bounded (caps per block) | Chooses bitmap, recipients, managers, bps for any unregistered PoolKey — no proof of pool ownership. |
| Fee manager | Bounded (≤ feeCap ≤ 5%) | `setManagedPoolFee` instant. |
| Access manager | Bounded (swap/add gating only) | Edit allowlist / merkle root instantly; cannot block LP removal. |
| Trusted router | Bounded (identity oracle) | Its `msgSender()` becomes the resolved user for every block. |
| PoolManager | Trusted (external) | Sole caller of hook callbacks and unlock callbacks. |

**Adversary Ranking** (ordered by threat level for this protocol type, adjusted by git evidence):

1. **Pool-config griefer / front-runner** — anyone can register the first stack for any PoolKey, so pool economics belong to whoever registers first.
2. **Identity spoofer** — swappers and LPs control `hookData`, which feeds every identity-keyed protection and reward block.
3. **MEV / JIT searcher** — donations (Arb, LP rewards, buyback) and per-block fee state reward same-block liquidity and ordering games.
4. **Launch sniper / curve arbitrageur** — curves custody quote and price whole buys at a single tranche/marginal price.
5. **Compromised owner** — instant factory swap turns token-less seeding into withdrawable claims across all pools.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **Owner → launchpad trust root** — no timelock; `setLaunchpadFactory` (`HookRigBase.sol:57`) instantly authorizes an address to call `seedKingPotFromLaunchCurve` (`HookRigOrchestrator.sol:424`), which credits claims with no tokens. *Git signal: access_control touched in 3/3 source commits.*
- **Registrant → pool** — `registerPoolStack` (`HookRigOrchestrator.sol:79`) trusts `msg.sender` as pool owner; nothing ties registration to the initializer or forbids post-initialization registration.
- **Router/hookData → identity** — `_resolveUser` (`HookRigBase.sol:67-78`) trusts trusted routers *and* raw `hookData`; the doc's "non-privileged attribution only" is not enforced by callers.
- **Curve → orchestrator** — curves call their implementation-immutable `hookOrchestrator`, while the factory registers on a caller-chosen `hookContract` (`LaunchpadFactory.sol:72,166`).

### Key Attack Surfaces

- **Permissionless first-come stack registration** &nbsp;&#91;[X-4](invariants.md#x-4), [E-5](invariants.md#e-5), [G-1](invariants.md#g-1)&#93; — `registerPoolStack:79-87` has no initializer/ownership tie and no "not yet initialized" check; worth tracing what a third party can configure (tax recipient, AccessControl manager, CircuitBreaker, AutoBurn `useTokenBurnCall`) on pools it does not own, including CREATE2-predictable launchpad keys.

- **hookData-derived identity feeds protection blocks** &nbsp;&#91;[X-3](invariants.md#x-3), [E-4](invariants.md#e-4), [G-20](invariants.md#g-20), [G-22](invariants.md#g-22)&#93; — `HookRigBase._resolveUser:73-75` returns any address from `hookData`; worth checking AccessControl (`:320`), JIT posKey (`:277,:299`), WalletCap (`:393`) and VestingSellCap (`:400`) against a caller who names a different address per call.

- **King pot currency mixing across seed and buy paths** &nbsp;&#91;[I-3](invariants.md#i-3), [X-5](invariants.md#x-5), [E-1](invariants.md#e-1)&#93; — `seedKingPotFromLaunchCurve:431-436` seeds `currency0` into an empty pot; `KingOfThePoolBlock.processBuy:86-88` then overwrites `potCurrency` with the project token while keeping the amount; worth confirming what `claimKingPot:417-420` burns afterwards.

- **Token-less claim crediting via seeding** &nbsp;&#91;[I-2](invariants.md#i-2), [X-1](invariants.md#x-1), [G-8](invariants.md#g-8)&#93; — `seedKingPotFromLaunchCurve:424-441` trusts the caller to have minted ERC-6909 first; worth tracing every address that can satisfy `G-8` and whether all of them pre-mint.

- **Shared ERC-6909 balance behind per-pool ledgers** &nbsp;&#91;[I-1](invariants.md#i-1), [E-1](invariants.md#e-1)&#93; — `poolClaims` is per-pool but `unlockCallback:110-114` burns from one hook-wide balance per currency; worth checking whether any per-pool over-credit (pots, reserves, seeds) can draw on other pools' backing.

- **Return-delta settlement must net to zero** &nbsp;&#91;[I-6](invariants.md#i-6), [I-28](invariants.md#i-28), [E-3](invariants.md#e-3)&#93; — `_executeAfterSwapDeltaWaterfall:76-226` pairs eight cut types with mint/take/donate/burn and a zero-liquidity rollback at `:221`; worth checking exact-output swaps, buyback trigger (`:198-206`), and AutoBurn on non-burnable tokens.

- **Curve/orchestrator mismatch at graduation** &nbsp;&#91;[X-2](invariants.md#x-2)&#93; — `LaunchpadFactory.launch*:72,91,109` accepts `hookContract` while curves notify the implementation's orchestrator (`VirtualXYKLaunch.sol:196`); worth confirming graduation liveness when they differ.

- **Limit-order escrow for native currency** &nbsp;&#91;[I-21](invariants.md#i-21), [G-36](invariants.md#g-36)&#93; — `LimitOrdersLogic.placeOrder:62-76` records native orders without receiving ETH (non-payable entry) while cancel/claim transfer native out; worth checking escrow backing per currency and on arbitrary PoolKeys.

- **Anti-snipe clock re-arm** &nbsp;&#91;[I-23](invariants.md#i-23), [G-3](invariants.md#g-3)&#93; — `notifyPoolGraduated:90-99` has no once-only latch and resets `startBlock` each call; worth checking who can call it after trading starts.

- **Stepped tranche pricing and token-cap overpay** &nbsp;&#91;[I-16](invariants.md#i-16), [I-18](invariants.md#i-18)&#93; — `SteppedTrancheLaunch.buy:128-134` prices the whole buy at the starting tranche and caps tokens without refunding quote; worth checking single-buy tranche skipping and the final-buy refund claim in docs.

### Protocol-Type Concerns

**As a DEX/AMM hook:**
- `AfterSwapDeltaAggregator:186` reads post-swap `getLiquidity` to choose donate vs rollback; donations to in-range LPs reward JIT positions whenever the JIT guard can be keyed around (X-3).
- `LimitOrdersLogic.processCrossedTicks:142-161` aligns with `(prevTick / step) * step` (truncation toward zero) and caps at 16 steps, so negative-tick and large moves may mark the wrong or no buckets.
- `ArbRecaptureLogic.computeCutBps:43-51` measures against a reference tick refreshed once per block; tick distance (not price impact) drives the cut.

**As a launchpad:**
- `VirtualXYKLaunch.sell:156-171` accepts tokens from any source (e.g., creator `VestingWallet` allocation, `LaunchpadFactory.sol:192-201`) against `realQuoteRaised`.
- `NativeTickLaunch.unlockCallback:71-78` passes `tokenAmount` as `liquidityDelta` (liquidity units, not tokens).

### Temporal Risk Profile

**Deployment & Initialization:**
- `_beforeInitialize:210` only protects pools registered as launchpad before init; ordinary pools can be initialized unconfigured and configured later by anyone, skipping `_afterInitialize` anchors (`I-29`).
- Implementations' `factory` immutable is a predicted address (`HookRigTestBase` uses a nonce-predicted factory); a wrong prediction bricks every clone's `initializeCurve`.

**Market Stress:**
- `CircuitBreakerLogic.checkAndAdvance:24-34` reverts swaps once window drift exceeds `maxWindowTickDeviation`; with permissionless registration a tiny deviation is a swap freeze for up to `windowSeconds` per window.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **Uniswap v4 PoolManager** — via `HookRigOrchestrator` callbacks, `HookRigBase.unlockCallback`, curve `unlockCallback`s
> - Assumes: hook deltas settle; `getSlot0`/`getLiquidity` reflect post-swap state; `updateDynamicLPFee` callable in `afterInitialize`
> - Validates: callbacks `onlyPoolManager`; curve callbacks check `msg.sender`
> - Mutability: Immutable
> - On failure: revert (swap/withdraw/graduation)

> **Project / quote ERC-20s** — via `AutoBurnLogic.execute`, `WalletCapLogic`, `VestingSellCapLogic`, `LimitOrdersLogic`, curves
> - Assumes: `burn()` exists when `useTokenBurnCall`; `balanceOf`/`totalSupply` honest; exact-amount transfers
> - Validates: SafeERC20 on transfers; none on balances or burnability
> - Mutability: Arbitrary per pool (any PoolKey)
> - On failure: revert inside `afterSwap` → swap DoS for that direction

> **Trusted routers (`IMsgSender`)** — via `HookRigBase._resolveUser`
> - Assumes: `msgSender()` returns the real initiator
> - Validates: owner allowlist; `try/catch` fallback to hookData
> - Mutability: Owner-controlled
> - On failure: falls back to hookData / router address

**Token Assumptions** *(unvalidated only)*:
- Fee-on-transfer quote/order tokens: `placeOrder:64` and curve `buy` credit nominal amounts — escrow/raised accounting overstated.
- Non-burnable project token with `useTokenBurnCall=true`: `AutoBurnLogic.execute:41-42` reverts every qualifying buy.

**Shared State Exposure**:
- All pools share the hook's ERC-6909 balances in PoolManager; any per-pool over-credit is cross-pool exposure.

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **40 Enforced Guards** (`G-1` … `G-40`) — per-call preconditions with `Check` / `Location` / `Purpose`
> - **33 Single-Contract Invariants** (`I-1` … `I-33`) — Conservation, Bound, Ratio, StateMachine, Temporal
> - **5 Cross-Contract Invariants** (`X-1` … `X-5`) — caller/callee pairs that cross scope boundaries
> - **5 Economic Invariants** (`E-1` … `E-5`) — higher-order properties deriving from `I-N` + `X-N`
>
> Every inferred block cites a concrete Δ-pair, guard-lift + write-sites, state edge, temporal predicate, or NatSpec quote. The **On-chain=No** blocks are the high-signal ones — each is simultaneously an invariant and a potential bug. Attack-surface bullets above cross-link directly into the relevant blocks (e.g. `[X-4]`, `[I-3]`).

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `README.md` |
| NatSpec | ~111 `@notice`/`@dev` tags (~200 `///` lines) | Contract-level titles everywhere; most internal functions undocumented |
| Spec/Whitepaper | Present | `docs/01`–`06` (architecture, hook flow, security caveats, launch mechanics, attack vectors) |
| Inline Comments | Adequate | Several spec/code mismatches: tax updates (per spec) have no entry point; JIT penalty unused; oracle cap 100 ticks/s vs "200/block" (per spec); fee rule MAX vs waterfall inconsistent across docs |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 5 | File scan (always reliable) |
| Test functions | 45 | File scan (always reliable) |
| Line coverage | 95.74% (1235/1290) | `forge coverage` |
| Branch coverage | 79.81% (336/421) | `forge coverage` |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 41 | Blocks, presets, launchpad curves |
| Stateless Fuzz | 3 | Swap solvency, VirtualXYK round-trip, random bitmaps |
| Stateful Fuzz (Foundry) | 1 | Claim solvency on one pool (swaps + treasury withdraw only) |
| Stateful Fuzz (Echidna) | 0 | none |
| Stateful Fuzz (Medusa) | 0 | none |
| Formal Verification (Certora/Halmos/HEVM) | 0 | none |

### Gaps

- Only one stateful invariant; its handler never calls `registerPoolStack`, liquidity ops, limit orders, TWAMM, King claims/finalize, curves, or varies `hookData`/actors.
- The solvency check sums claims for three hardcoded accounts and assumes the King pot is in `currency1` — it cannot observe I-3 or cross-pool effects.
- No Echidna/Medusa campaigns; no formal verification of the return-delta settlement or curve math.
- Branch coverage weakest in `SteppedTrancheLaunch` (52%), `TWAMMBlock` (57%), `LimitOrdersBlock` (62%).

---

## 6. Developer & Git History

> Repo shape: squashed_import — 4 commits on 14/10/26 by one author; 3 touch source; no meaningful evolution history.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| 0xeabz | 4 | +4514 / -217 | 100% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 1 | Single-dev |
| Merge commits | 0 of 4 (0%) | No merge commits — likely no peer review |
| Repo age | 2026-10-14 → 2026-10-14 | < 1 day |
| Recent source activity (30d) | 3 commits | Entire history is recent |
| Test co-change rate | 33% | Co-modification only, not coverage |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| src/HookRigOrchestrator.sol | 3 | Every source commit |
| src/base/AfterSwapDeltaAggregator.sol | 3 | Settlement waterfall |
| src/blocks/protection/MEVProtectionBlock.sol | 3 | |
| src/blocks/protection/CircuitBreakerBlock.sol | 3 | |
| src/launchpad/curves/VirtualXYKLaunch.sol | 2 | |
| src/launchpad/curves/SteppedTrancheLaunch.sol | 2 | |
| src/blocks/rewards/KingOfThePoolBlock.sol | 2 | |

### Security-Relevant Commits

No development history — fix detection not applicable beyond noting `8477cac` ("initial tests and attack vectors and fund freeze", score 21) touched 15 source files including KingOfThePool, AutoBuyback, LimitOrders and both curves.

### Technical Debt Markers

None (0 TODO/FIXME/HACK).

### Security Observations

- **Single developer** — 100% of source lines from 0xeabz.
- **No review signal** — 0 merge commits.
- **Late wide change** — `8477cac` modified 15 source files in one commit alongside the first tests.
- **Uncommitted edits** — working tree had modified `src/` files at session start; this report reflects the files on disk.

### Cross-Reference Synthesis

- **Orchestrator + Aggregator are top churn and top attack-surface** → registration (`X-4`), identity (`X-3`) and settlement (`I-28`) all route through them.
- **`8477cac` touched KingOfThePool and both curves** → aligns with `I-3`/`X-5` (pot currency) and curve surfaces; worth re-reading that diff first.

---

## X-Ray Verdict

**FRAGILE** — Unit, fuzz and invariant tests plus a spec exist, but access control has instant owner powers with no timelock and pool configuration is permissionless.

**Structural facts:**
1. 3094 nSLOC across 8 subsystems; one hook contract inherits 15 block/base contracts.
2. 45 test functions in 5 files: 41 unit, 3 stateless fuzz, 1 stateful invariant; 95.7% line / 79.8% branch coverage.
3. 1 developer, 4 commits, all on 14/10/26; 0 merge commits.
4. 37 entry points: 17 permissionless, 15 role-gated, 5 admin-only; no upgradeable contracts.
