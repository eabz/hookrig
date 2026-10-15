# 06. Attack Vectors, Mitigations & Code-Level Fixes

This document catalogs every known Uniswap v4 hook, multi-block composition, and token launchpad attack vector addressed by **HookRig**, mapping each threat directly to its **on-chain code fix** in `src/` and its **regression test** in `test/`.

---

## Summary Matrix

| # | Attack Vector | Category | Primary Code Fix (`src/`) | Verification Test (`test/`) |
| :--- | :--- | :--- | :--- | :--- |
| **AV-01** | **Unauthenticated Hook Callback & Cross-Pool Claim Contamination** *(Cork Protocol May 2025 Vector)* | Core v4 Hook | `HookRigBase.onlyPoolManager`, `poolClaims[poolId][currency][recipient]` | `PresetsAndSecurityVectorsTest::test_AttackVector01_UnauthenticatedCallbackAndCrossPoolClaimIsolation` |
| **AV-02** | **1-Wei Dust Rounding & Custom Accounting Precision Drain** *(Bunni V2 Sept 2025 Vector)* | Math & Accounting | `AfterSwapDeltaAggregator` (`Math.Rounding.Floor` on slices, `Ceil` on Exact-Out debt) | `PresetsAndSecurityVectorsTest::test_AttackVector02_BunniV2_OneWeiDustRoundingSafety` |
| **AV-03** | **Stacking Excessive Return-Delta Blocks (`> 100%` Output Drain)** | Composition | `AfterSwapDeltaAggregator.validateAggregateReturnDeltaBps` (`<= 2,500 bps` / `25%` hard cap) | `PresetsAndSecurityVectorsTest::test_AttackVector03_AggregateReturnDeltaBpsCapEnforced` |
| **AV-04** | **Zero-Liquidity `PoolManager.donate()` Pool DoS (`NoLiquidityToReceiveFees`)** | Liquidity / DoS | `AfterSwapDeltaAggregator._settleAggregateAfterSwap` (`StateLibrary.getLiquidity > 0` check + fallback to `poolAdmin` claim) | `PresetsAndSecurityVectorsTest::test_AttackVector04_ZeroLiquidityDonateFallbackDoesNotRevert` |
| **AV-05** | **`afterSwapReturnDelta` Exact-In vs. Exact-Out & `token0`/`token1` Polarity Inversion** | Swap Polarity | `HookRigBase._classifySwapDirection` + `AfterSwapDeltaAggregator` unspecified-currency branching | `PresetsAndSecurityVectorsTest::test_AttackVector05_ExactInAndExactOut_Token0AndToken1Polarity` |
| **AV-06** | **The `msg.sender` vs. `sender` Router Spoofing Paradox** | Identity / Auth | `HookRigBase._resolveSwapUser` (trusted router allowlist via `IMsgSender.msgSender()` + 20-byte `hookData` fallback) | `PresetsAndSecurityVectorsTest::test_AttackVector06_UntrustedRouterResolutionAndDoubleConfigLock` |
| **AV-07** | **Mid-Lifecycle Pool Reconfiguration & Static-Fee Flag Mismatch** | Lifecycle | `HookRigOrchestrator.registerPoolStack` (`configLocked` guard + `LPFeeLibrary.isDynamicFee` validation) | `PresetsAndSecurityVectorsTest::test_AttackVector07_StaticFeePoolWithDynamicBlocksReverts` |
| **AV-08** | **Atomic JIT (Just-In-Time) Liquidity Dilution on `donate()` Rewards** | MEV / LP Dilution | `MEVProtectionBlock` & `JITGuardBlock` (`lastLiquidityAddBlock[poolId][positionKey]` cooldown) | `BlocksUnitTest::test_Block05_And_18_MEVProtection_PriceImpactAndJITGuard` |
| **AV-09** | **Flash-Loan Spot Price & TWAP Manipulation** | Oracle / Fee Manipulation | `OracleBlock` (`MAX_TICK_DELTA_PER_BLOCK = 200` truncation), `CircuitBreakerBlock` (`maxWindowTickDeviation`) | `BlocksUnitTest::test_Block17_Oracle_TruncatedTWAPCheckpointing`, `test_Block19_CircuitBreaker_RollingPriceBand` |
| **AV-10** | **Push-Transfer Blacklist / Reverting Recipient Swap DoS** | Pool Liveness | `HookRigBase._creditPoolClaim` + `_payoutERC6909Claim` (pull-based ERC-6909 claims for taxes, fee shares, referrals, and jackpots) | `BlocksUnitTest::test_Block09_BuySellTax_ClaimsAndBounds`, `test_Block14_KingOfThePool_JackpotCountdownAndClaim` |
| **AV-11** | **Malicious Admin Honeypot Configuration (100% Tax, Zero Wallet Cap, Freeze Withdrawals)** | Anti-Rug Governance | Immutable hard caps in every block + `AccessControlBlock` never hooking `beforeRemoveLiquidity` + `WalletCapBlock` exempting sells | `BlocksUnitTest::test_Block08_WalletCap_MaxHoldingsAndSunset`, `test_Block21_VestingSellCap_DailyEpochEnforcement` |
| **AV-12** | **`KingOfThePool` 1-Wei Dust Timer Reset Griefing** | Game-Fi Griefing | `KingOfThePoolLogic.onBuySwap` (`buyVolume >= minBuyAmountForReset` required to reset timer or transfer crown) | `BlocksUnitTest::test_Block14_KingOfThePool_JackpotCountdownAndClaim` |
| **AV-13** | **Self-Referral & Sybil Referral Hijacking** | Rewards Exploit | `ReferralSplitLogic.registerReferrer` (`trader == referrer` revert + immutable first-touch binding) | `BlocksUnitTest::test_Block20_ReferralSplit_FirstTouchAndAntiSelfReferral` |
| **AV-14** | **Bonding Curve Graduation Over-Contribution, Spot Discontinuity & Pre-Init Sniping** | Launchpad | `VirtualXYKLaunch` & `SteppedTrancheLaunch` cap-and-refund, continuous `sqrtPriceX96`, and `notifyPoolGraduated` anti-snipe clock reset | `LaunchpadSuiteTest::test_VirtualXYKLaunch_BuySellRefundAndAtomicGraduation` |

---

## Detailed Attack Vector Breakdown & Code Fixes

### AV-01: Unauthenticated Hook Callback & Cross-Pool Claim Contamination *(Cork Protocol Vector)*

- **Vulnerability**: In May 2025, Cork Protocol lost ~$12M when an attacker called unauthenticated hook entry points and deployed a counterfeit pool pairing a legitimate token with a fake token to drain shared reserves.
- **How HookRig Fixes It**:
  1. [`HookRigBase`](../src/base/HookRigBase.sol) inherits OpenZeppelin's `BaseHook`, enforcing `onlyPoolManager` on all external Uniswap v4 hook callbacks (`_afterInitialize`, `_beforeAddLiquidity`, `_beforeRemoveLiquidity`, `_beforeSwap`, `_afterSwap`).
  2. Every ERC-6909 claim balance is double-keyed by both `PoolId` and `Currency` inside [`HookRigBase.sol`](../src/base/HookRigBase.sol#L49-L51):
     ```solidity
     mapping(PoolId poolId => mapping(Currency currency => mapping(address account => uint256 amount))) public poolClaims;
     ```
     Even if two pools share the same token and use the same `HookRigOrchestrator` singleton, claims accrued in `Pool B` can never withdraw reserves belonging to `Pool A`.

---

### AV-02: 1-Wei Dust Rounding & Precision Amplification *(Bunni V2 Vector)*

- **Vulnerability**: In September 2025, Bunni V2 lost ~$8.4M when flash-loan-assisted micro-swaps exploited a rounding direction inversion in custom hook accounting.
- **How HookRig Fixes It**:
  1. In [`AfterSwapDeltaAggregator.sol`](../src/base/AfterSwapDeltaAggregator.sol#L127-L163), every percentage slice taken from `grossUnspecifiedAmount` on Exact-Input swaps uses `Math.mulDiv(..., Math.Rounding.Floor)` so the sum of individual block slices (`arbSlice + taxSlice + burnSlice + shareSlice + lpRewardSlice + kingPotSlice + referralSlice + buybackSlice`) can **never** exceed the swap's gross output or underflow `PoolManager` accounting.
  2. On Tiny/1-Wei swaps (`grossUnspecified == 1`), `Math.mulDiv(1, bps, 10_000, Math.Rounding.Floor)` evaluates cleanly to `0`, preventing revert or rounding inflation.
  3. In [`VirtualXYKLaunch.sol`](../src/launchpad/curves/VirtualXYKLaunch.sol#L100-L104), bonding curve reserve updates round new virtual reserves **UP** (`Math.Rounding.Ceil`) and user payouts **DOWN** (`Math.Rounding.Floor`), guaranteeing that a buy followed by an immediate sell never extracts excess quote currency (`testFuzz_VirtualXYK_NoRoundTripArbitrage`).

---

### AV-03: Aggregate Return-Delta Cap (`<= 25%`)

- **Vulnerability**: Because HookRig supports 8 distinct `afterSwapReturnDelta` blocks (`ArbRecapture`, `BuySellTax`, `AutoBurn`, `FeeSharing`, `LPRewards`, `KingOfThePool`, `ReferralSplit`, `AutoBuyback`), a misconfigured or malicious pool could stack all 8 blocks to confiscate `> 100%` of a trader's swap output.
- **How HookRig Fixes It**:
  - [`AfterSwapDeltaAggregator.validateAggregateReturnDeltaBps`](../src/base/AfterSwapDeltaAggregator.sol#L36-L81) sums the worst-case basis points across all enabled return-delta blocks (excluding `ArbRecapture`, which is bounded against price dislocation) at `registerPoolStack` time and reverts with `AggregateReturnDeltaExceedsCap(maxBuyBps, maxSellBps)` if either direction exceeds `MAX_AGGREGATE_AFTER_SWAP_BPS = 2500` (`25.00%`).

---

### AV-04: Zero-Liquidity `PoolManager.donate()` Revert Prevention

- **Vulnerability**: Calling `poolManager.donate(key, amount0, amount1, "")` when active in-range tick liquidity is `0` reverts inside Uniswap v4 `PoolManager` with `NoLiquidityToReceiveFees()`, bricking all swaps when price moves outside active LP ticks.
- **How HookRig Fixes It**:
  - Inside [`AfterSwapDeltaAggregator._settleAggregateAfterSwap`](../src/base/AfterSwapDeltaAggregator.sol#L186-L202), before calling `poolManager.donate(...)` for `ArbRecapture`, `LPRewards`, or `AutoBuyback` floor defense, HookRig inspects ` poolManager.getLiquidity(poolId)`:
    ```solidity
    uint128 activeLiq = poolManager.getLiquidity(poolId);
    if (activeLiq > 0) {
        poolManager.donate(key, d0, d1, "");
        totalLPRewardsDonated[poolId] += totalLPDonateSlice;
    } else {
        // Fallback when active liquidity is zero so swaps never revert
        poolManager.mint(address(this), unspecifiedCurrency.toId(), totalLPDonateSlice);
        address fallbackRecipient = _poolRegistry[poolId].poolAdmin != address(0)
            ? _poolRegistry[poolId].poolAdmin
            : address(this);
        _creditPoolClaim(poolId, unspecifiedCurrency, fallbackRecipient, totalLPDonateSlice);
    }
    ```

---

### AV-05: Exact-In vs. Exact-Out & `token0`/`token1` Polarity Inversion

- **Vulnerability**:
  1. In Uniswap v4, `Currency0` and `Currency1` are sorted strictly by numerical address (`uint160(currency0) < uint160(currency1)`). A project token may be `currency0` or `currency1` depending on its address relative to the quote asset.
  2. Furthermore, `afterSwapReturnDelta` always denominates the hook's delta in the **unspecified currency** (`output` currency on Exact-Input `amountSpecified < 0`, but `input` currency on Exact-Output `amountSpecified > 0`).
- **How HookRig Fixes It**:
  1. [`LaunchpadFactory`](../src/launchpad/LaunchpadFactory.sol#L186-L188) enforces `uint160(token) > uint160(quoteAddr)` via CREATE2 salt validation so launchpad tokens are deterministically `currency1`. For existing tokens, `PoolStackConfig.isToken0ProjectToken` configures polarity per pool.
  2. [`HookRigBase._classifySwapDirection`](../src/base/HookRigBase.sol#L121-L148) computes `isBuy`, `isExactInput`, `unspecifiedCurrency`, and `grossUnspecifiedAmount` across all 4 quadrants (`token0` vs `token1` project token $\times$ `Exact-In` vs `Exact-Out`).
  3. On `Exact-Output` swaps (`isExactInput == false`), `AutoBurnBlock` only burns when `unspecifiedCurrency == projectCurrency`, preventing accidental burning of the quote currency.

---

### AV-06: Router Spoofing (`msg.sender` vs. `sender`)

- **Vulnerability**: Inside Uniswap v4 hook callbacks, `msg.sender` is always `PoolManager`, and the `sender` parameter is the **Router contract** that called `PoolManager.swap(...)`. Trusting `sender` as the end-user breaks `WalletCap`, `AccessControl`, `VestingSellCap`, `ReferralSplit`, and `KingOfThePool` (crowning the Router instead of the trader), while blindly trusting `IMsgSender(sender).msgSender()` or unauthenticated `hookData` on an unverified router allows an attacker to spoof another user's address (`SP-15`, `SP-16`, `SP-17`, `SP-18`, `SP-25`).
- **How HookRig Fixes It**:
  - [`AccessControlLogic.resolveUser`](../src/blocks/protection/AccessControlBlock.sol#L63-L76) (called by [`HookRigBase._resolveUser`](../src/base/HookRigBase.sol#L73-L79)) queries `IMsgSender(routerSender).msgSender()` or 20/32-byte `hookData` **strictly when `isTrustedRouter[routerSender] == true`**. For untrusted routers, it unconditionally returns `routerSender`, preventing `hookData` identity spoofing.

---

### AV-07: Mid-Lifecycle Pool Reconfiguration & Static-Fee Flag Mismatch

- **Vulnerability**: Allowing a pool administrator to re-register a pool stack after initialization could alter tax rates, swap polarity, or recipients mid-flight. Initializing a pool without `LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`) when dynamic fee blocks are active causes `beforeSwap` fee overrides to silently fail.
- **How HookRig Fixes It**:
  - [`HookRigOrchestrator.registerPoolStack`](../src/HookRigOrchestrator.sol#L84-L108) verifies that the pool is not already initialized in `PoolManager` (`sqrtPriceX96 == 0`, `SP-19`), sets `_poolConfigs[poolId].initialized = true` on registration, and reverts with `PoolStackAlreadyRegistered(poolId)` on any subsequent call. It also verifies `key.fee.isDynamicFee()` whenever any `Group 1` (`DynamicFee`, `ManagedFee`, `MarketHoursFee`) or `AntiSnipe` block is enabled.

---

### AV-08: Atomic JIT (Just-In-Time) Liquidity Dilution

- **Vulnerability**: MEV searchers bundle `[addLiquidity -> victim big buy swap -> removeLiquidity]` in the same block to capture ~99% of `PoolManager.donate()` rewards from `LPRewardsBlock` and `ArbRecaptureBlock` with zero directional duration risk.
- **How HookRig Fixes It**:
  - [`MEVProtectionBlock`](../src/blocks/protection/MEVProtectionBlock.sol) and [`JITGuardBlock`](../src/blocks/protection/JITGuardBlock.sol) record `lastAddBlock[poolId][positionKey] = block.number` in `beforeAddLiquidity` keyed on the canonical `PoolManager` position `(routerSender, tickLower, tickUpper, salt)` (`SP-16`), and revert in `beforeRemoveLiquidity` if `block.number < lastAddBlock + minHoldBlocks` (enforcing `JITExitPenaltyRequired` when `earlyExitPenaltyBps > 0` or `JITGuardHoldActive`).

---

### AV-09: Flash-Loan Spot Price & TWAP Oracle Manipulation

- **Vulnerability**: An attacker takes a flash loan, skews spot tick by 5,000 ticks in a single transaction, triggers a false oracle reading or dynamic fee spike, and Arb-recaptures back.
- **How HookRig Fixes It**:
  - [`OracleBlock`](../src/blocks/trading/OracleBlock.sol) clamps single-step tick movement to `MAX_ORACLE_TICK_DELTA_PER_SEC = 100` ticks/second (computed in `int256` before clamping to `[MIN_TICK, MAX_TICK]` so long idle windows never truncate `int24`, `GL-19`) when accumulating `tickCumulative`.
  - [`CircuitBreakerBlock`](../src/blocks/protection/CircuitBreakerBlock.sol) maintains a rolling time-window anchor tick (`windowStartTick`) and reverts swaps that push the spot tick beyond `maxTickDeviation` within `windowSeconds`.

---

### AV-10: Push-Transfer Blacklist / Reverting Recipient Swap DoS

- **Vulnerability**: If a hook performs direct ERC-20 `transfer()` calls to a `taxRecipient`, `feeShareRecipient`, `referrer`, or `KingOfThePool` winner *during* `afterSwap`, a blacklisted recipient (e.g., USDC blacklist) or a malicious contract that reverts on token receipt would permanently brick all swaps in the pool.
- **How HookRig Fixes It**:
  - During `afterSwap`, HookRig **never** pushes ERC-20 tokens to external recipients. Instead, [`AfterSwapDeltaAggregator`](../src/base/AfterSwapDeltaAggregator.sol) calls `poolManager.mint(address(this), unspecifiedCurrency.toId(), totalERC6909MintSlice)` once and credits internal pull-based balances via `_creditClaim(...)` (including the static `5 bps` protocol royalty to `PROTOCOL_ROYALTY_RECIPIENT = 0x576e9C47665887298EB39eeaa070Dfc1fF6B960A`).
  - Recipients withdraw asynchronously via [`HookRigBase.withdrawClaim`](../src/base/HookRigBase.sol#L84-L106) or [`claimKingPot`](../src/HookRigOrchestrator.sol#L368-L390), which unlocks `PoolManager`, burns the ERC-6909 claim, and calls `poolManager.take(...)`.

---

### AV-11: Anti-Honeypot & Unhindered LP Exit Guarantees

- **Vulnerability**: Malicious token creators often use custom hooks to trap buyers by:
  1. Setting `WalletCap` to `0%` after launch so nobody can buy, or blocking sells with `WalletCap`.
  2. Setting `VestingSellCap` to `0 bps` so nobody can sell.
  3. Using `AccessControl` on `beforeRemoveLiquidity` to trap LPs' capital inside the pool.
- **How HookRig Fixes It**:
  1. [`WalletCapBlock`](../src/blocks/token-rules/WalletCapBlock.sol) enforces a minimum floor `maxWalletBps >= 10` (`0.10%` of supply) and **only runs when `isBuy == true`**—selling is unconditionally exempt.
  2. [`VestingSellCapBlock`](../src/blocks/token-rules/VestingSellCapBlock.sol) enforces a minimum floor `maxDailySellBps >= 50` (`0.50%` of holdings per day) and a ceiling `<= 5000` (`50%`).
  3. [`AccessControlBlock`](../src/blocks/protection/AccessControlBlock.sol) only hooks `beforeAddLiquidity` and `beforeSwap`. It **never** hooks `beforeRemoveLiquidity`, guaranteeing LPs can always withdraw their liquidity.

---

## Core Protocol Failures That Can Freeze Funds (Anti-Lockup & Liveness Guarantees)

Beyond external attacker exploits (`AV-01`–`AV-14`), stateful multi-hook protocols face **internal state machine deadlocks and accounting mismatches** that can permanently freeze user or LP capital. HookRig enforces 6 dedicated anti-freeze invariants (`FF-01`–`FF-06`):

| # | Fund-Freeze Failure Mode | Root Cause Without Fix | Code-Level Anti-Freeze Fix (`src/`) | Verification Test (`test/`) |
| :--- | :--- | :--- | :--- | :--- |
| **FF-01** | **Limit Order Post-Fill Principal Lockup, Native ETH Escrow & Cross-Pool Spoofing** | Crossing a target tick marks `bucket.filled = true`; `cancelLimitOrder` reverts with `BucketAlreadyFilled`. Additionally, un-escrowed native ETH orders or shared balances across pools could allow cross-pool drain (`GL-04`, `SP-03`, `SP-28`). | [`LimitOrdersBlock`](../src/blocks/trading/LimitOrdersBlock.sol) accepts `payable` native ETH orders (`msg.value == inputAmount`), isolates escrow per pool & currency (`limitOrderPoolEscrow[poolId][currency]`), validates `OrderPoolKeyMismatch`, and converts filled orders to output currency via `LimitOrderSwapExecutor` on `claimLimitOrder`. | `PresetsAndSecurityVectorsTest::test_AntiFreeze01_LimitOrders_ClaimFilledOrderAndPoolKeyValidation`, `FoundryTester::test_repro_SP03_nativeLimitOrderEscrow`, `FoundryTester::test_repro_SP28_filledOrderPaysOutput` |
| **FF-02** | **`AutoBuybackBlock` Multi-Swap ERC-6909 Reserve Stranding & Cross-Currency Collision** | On accumulation swaps (`deployed == 0`), `AfterSwapDeltaAggregator` mints `bbCut` in ERC-6909 claims to `address(this)`. When a later swap crosses the floor tick (`deployed > 0`), donating only `bbCut` without burning the previously minted ERC-6909 reserve (`deployed - bbCut`) either reverts in `PoolManager` with currency delta mismatch or permanently strands the prior ERC-6909 reserve. Furthermore, accumulating `currency0` and `currency1` into a single `uint256 accumulatedReserve` mixes token denominations. | [`AutoBuybackBlock`](../src/blocks/rewards/AutoBuybackBlock.sol) isolates reserves per `Currency` (`mapping(Currency => uint256) reserveByCurrency`) and gates triggers on `activeLiquidity > 0`. [`AfterSwapDeltaAggregator`](../src/base/AfterSwapDeltaAggregator.sol) burns `priorReserve = deployed - bbCut` (`poolManager.burn`) while donating the full `deployed` amount to in-range LPs. | `PresetsAndSecurityVectorsTest::test_AntiFreeze02_AutoBuyback_MultiSwapReserveBurnAndZeroLiqSafety` |
| **FF-03** | **`KingOfThePool` Heterogeneous Currency Overwrite Freezing the Jackpot** | On an Exact-Input buy, `unspecifiedCurrency` is `projectCurrency`; on an Exact-Output buy, `unspecifiedCurrency` is `quoteCurrency`. If `KingOfThePool` overwrote `potCurrency = ctx.unspecifiedCurrency` while accumulating both into `potBalance`, calling `claimKingPot` would attempt to burn the combined `potBalance` from a single ERC-6909 currency ID and revert with insufficient ERC-6909 balance, freezing the entire pot (`GL-03`). | [`AfterSwapDeltaAggregator`](../src/base/AfterSwapDeltaAggregator.sol) restricts `KingOfThePool` pot contributions to `ctx.unspecifiedCurrency == ctx.projectCurrency`, and [`HookRigOrchestrator.seedKingPotFromLaunchCurve`](../src/HookRigOrchestrator.sol) credits `currency0` launch curve seeds directly to `poolClaims[poolId][currency0][poolAdmin]` rather than mixing currencies in `pot` (`GL-02`, `GL-03`). | `BlocksUnitTest::test_Block14_KingOfThePool_JackpotCountdownAndClaim`, `FoundryTester::test_repro_GL03_kingPotCurrencyPurity` |
| **FF-04** | **Stalled Launchpad Bonding Curve Capital Lockup & Accidental ETH Trapping** | If a launchpad bonding curve stalls and never reaches `graduationQuoteTarget`, buyers on a buy-only curve (`SteppedTrancheLaunch`) would have their capital permanently trapped. Additionally, sending non-zero `msg.value` to an ERC-20-quoted bonding curve would trap native ETH inside the curve contract. | Added pre-graduation `sell(...)` to [`SteppedTrancheLaunch`](../src/launchpad/curves/SteppedTrancheLaunch.sol) so buyers can always exit against `realQuoteRaised`, added multi-tranche integral pricing + cap-and-refund at `graduationQuoteTarget` (`GL-15`, `SP-27`), and enforced `UnexpectedETHForERC20Quote` on ERC-20-quoted launches in both curves. | `LaunchpadSuiteTest::test_SteppedTrancheLaunch_TranchesAntiSnipeSurchargeAndGraduation` |
| **FF-05** | **Unbounded `JITGuard` Hold Duration or `CircuitBreaker` Window Permanently Freezing Pool / LP Exit** | If a pool creator configures `JITGuardParams.minLPHoldBlocks = type(uint32).max` (~1.65 billion years) or `CircuitBreakerParams.windowSeconds = type(uint32).max`, LP positions or pool swaps could be frozen forever without a governance intervention. | Enforced hard upper bounds [`MAX_LP_HOLD_BLOCKS = 7200`](../src/blocks/protection/JITGuardBlock.sol#L17) (~24 hours) in `JITGuardBlock` and [`MAX_WINDOW_SECONDS = 86_400`](../src/blocks/protection/CircuitBreakerBlock.sol#L18) (24 hours) in `CircuitBreakerBlock` so every lockup or circuit breaker automatically recovers within 24 hours. | `PresetsAndSecurityVectorsTest::test_AntiFreeze03_JITAndCircuitBreaker_HardCeilingsPreventInfiniteLock` |
| **FF-06** | **TWAMM Expired Order Unclaimed Earnings, Real Escrow & Sell-Rate Retirement** | If `submitTWAMMOrder` did not escrow input tokens (`SP-30`) or `executePending` never retired expired order sell rates (`GL-17`), orders could stream beyond their submitted volume or overflow `uint128` sell rates. | [`TWAMMBlock`](../src/blocks/trading/TWAMMBlock.sol) escrows real ERC-20 / native ETH input tokens on `submitTWAMMOrder`, caps active orders at `MAX_ACTIVE_TWAMM_ORDERS = 64`, retires expired order sell rates at their exact `expirationTimestamp` during `executePending`, and refunds unstreamed principal on `cancelTWAMMOrder`. | `BlocksUnitTest::test_Block16_TWAMM_SubmitExecuteAndCancelRefund`, `FoundryTester::test_repro_GL17_twammBounded`, `FoundryTester::test_repro_SP30_accumulatorGrief` |

---

## Custom Block Composition & The Tier 3 Mutual-Exclusion Matrix (`2,843` Valid Combinations)

While the 22 building blocks (`17 core + 5 expansion`) represent $2^{22} - 1 = 4,194,303$ raw bitmaps, unconstrained combinations allow contradictory configurations (such as enabling two base fee models simultaneously, or pairing `MEVProtection`/`CircuitBreaker` swap reverts with `ArbRecapture`).

To prevent contradictory block interactions while supporting **all 12 curated Presets** and rich custom compositions, HookRig enforces the **Tier 3 Mutual-Exclusion Matrix (`2,843` valid combinations — a 99.93% reduction from `4,194,303`)** on-chain via `HookPermissionMasks.isValidTier3Bitmap(uint32 bitmap)`:

### The 7 Tier-3 Mutual-Exclusion Rules

1. **Rule M1 — Single Base Fee Model (`<= 1 of 3`)**:
   - `DynamicFee`, `ManagedFee`, and `MarketHoursFee` are mutually exclusive (`popcount <= 1`).
   - `AntiSnipe` is only valid as a temporary launch decay overlay when paired with `DynamicFee` or `MarketHoursFee`.
2. **Rule M2 — Non-Overlapping LP Cooldown (`<= 1 of 2`)**:
   - `MEVProtection` (which already includes LP hold cooldown) and `JITGuard` are mutually exclusive.
3. **Rule M3 — Non-Contradictory Dislocation Strategy (`<= 1 of 3`)**:
   - `ArbRecapture` (taxes large tick movements for LPs), `MEVProtection` (reverts large single-swap tick movements), and `CircuitBreaker` (reverts rolling-window tick deviations) are mutually exclusive (`7` total valid states across `{MEVProtection, JITGuard, ArbRecapture, CircuitBreaker}`).
4. **Rule M4 — Single Holder / Dump Cap (`<= 1 of 2`)**:
   - `WalletCap` and `VestingSellCap` are mutually exclusive (`3` states: `None`, `WalletCap`, `VestingSellCap`).
5. **Rule M5 — Single Token Sink / Jackpot / Affiliate Mechanism (`<= 1 of 4`)**:
   - `AutoBurn`, `KingOfThePool`, `ReferralSplit`, and `AutoBuyback` are mutually exclusive (`5` states).
6. **Rule M6 — Revenue & LP/Trader Yield Coherence (`21` combined states with M5)**:
   - `SwapRewards` is mutually exclusive with `BuySellTax` and `FeeSharing`; `KingOfThePool` does not pair with `BuySellTax` (preventing double buy-taxation); any active Sink or Revenue block requires `LPRewards`.
7. **Rule M7 — Pool Archetype Separation (`2,645` Retail + `198` Institutional/Pro = `2,843` Total)**:
   - **Archetype A (`2,645` combinations)**: Retail Tokenomics / Launchpad pools (`AccessControl = 0, LimitOrders = 0, TWAMM = 0, Oracle = 0`).
   - **Archetype B (`198` combinations)**: Institutional & Pro-Trading pools (`{AccessControl, LimitOrders, TWAMM, Oracle}` active; all 11 Retail Tokenomics bits = `0`; `AccessControl` mutually exclusive with `LimitOrders`/`TWAMM`).

---

## Hoodi Network Integration Test Findings (Implemented & Verified in `src/`)

During end-to-end integration testing and exhaustive `2,843`-combination testing on the **Ethereum Hoodi Testnet** (`chainId = 560048`, [`test/integration/HoodiForkIntegration.t.sol`](../test/integration/HoodiForkIntegration.t.sol) and [`script/HoodiIntegration.s.sol`](../script/HoodiIntegration.s.sol)), six enhancements (`IT-01`–`IT-06`) were identified and **implemented in `src/`** (tracked as completed `TODO-01`–`TODO-06` in [`docs/07-roadmap-and-todo.md`](./07-roadmap-and-todo.md)):

### IT-01 (`TODO-02` — Implemented): `PresetId != PresetId.Blank` Unions with `enabledBlocksBitmap`
- **Location**: [`HookRigOrchestrator._configurePoolStackInternal`](../src/HookRigOrchestrator.sol)
- **Implemented Fix**:
  Computes `uint32 bitmap = HookPermissionMasks.getPresetBitmap(config.presetId) | config.enabledBlocksBitmap;` and validates the combined bitmap against the Tier 3 Mutual-Exclusion Matrix.

### IT-02 (`TODO-03` — Implemented): Bonding Curve `maxWalletBpsDuringCurve` vs. Post-Graduation `WalletCapParams.maxWalletBps`
- **Location**: [`LaunchpadFactory._validateLaunchParams`](../src/launchpad/LaunchpadFactory.sol)
- **Implemented Fix**:
  Enforces `walletCap.maxWalletBps >= curveWalletCapBps` whenever `BIT_WALLET_CAP` is enabled on the pool stack and `curveWalletCapBps > 0`, ensuring bonding-curve buyers are never locked out of post-graduation purchases due to a stricter pool wallet cap.

### IT-03 (`TODO-01` — Implemented): Enforce the Tier 3 Mutual-Exclusion Matrix (`2,843` Valid Combinations) On-Chain
- **Location**: [`HookPermissionMasks.isValidTier3Bitmap`](../src/libraries/HookPermissionMasks.sol) & [`HookRigOrchestrator._configurePoolStackInternal`](../src/HookRigOrchestrator.sol)
- **Implemented Fix**:
  Enforces `HookPermissionMasks.isValidTier3Bitmap(bitmap)` on-chain and reverts with `InvalidBlockBitmap(bitmap)` during `registerPoolStack` / `launchToken` if a bitmap violates any of the 7 Tier-3 Mutual-Exclusion rules (`M1`–`M7`).

### IT-04 (`TODO-04` — Implemented): `withdrawClaim(..., amount = 0, ...)` Claims Full Available Balance
- **Location**: [`HookRigBase.withdrawClaim`](../src/base/HookRigBase.sol#L84-L106)
- **Implemented Fix**:
  Defaults `amount == 0` to the caller's full available `poolClaims[poolId][currency][msg.sender]` balance (reverting with `InsufficientClaimBalance(0, 1)` only if the available balance is `0`).

### IT-05 (`TODO-05` — Implemented): Directional Buy vs. Sell Return-Delta Budget Validation
- **Location**: [`AfterSwapDeltaAggregator._validateAggregateReturnDeltaBudget`](../src/base/AfterSwapDeltaAggregator.sol#L43-L79)
- **Implemented Fix**:
  Tracks `maxBuyBps` and `maxSellBps` independently (including `PROTOCOL_ROYALTY_BPS = 5`) and validates `max(maxBuyBps, maxSellBps) <= MAX_AGGREGATE_AFTER_SWAP_BPS` (`2500 bps`).

### IT-06 (`TODO-06` — Implemented): Post-Cut Net Volume Attribution in `SwapRewards`
- **Location**: [`HookRigOrchestrator._afterSwap`](../src/HookRigOrchestrator.sol)
- **Implemented Fix**:
  Passes `netSwapVolume = ctx.grossUnspecifiedAmount > totalCutAmount ? ctx.grossUnspecifiedAmount - totalCutAmount : 0` to `_accrueSwapRewards`.



