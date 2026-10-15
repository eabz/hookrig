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

- **Vulnerability**: Inside Uniswap v4 hook callbacks, `msg.sender` is always `PoolManager`, and the `sender` parameter is the **Router contract** that called `PoolManager.swap(...)`. Trusting `sender` as the end-user breaks `WalletCap`, `AccessControl`, `VestingSellCap`, `ReferralSplit`, and `KingOfThePool` (crowning the Router instead of the trader), while blindly trusting `IMsgSender(sender).msgSender()` on an unverified router allows an attacker to deploy a fake router that spoofs another user's address.
- **How HookRig Fixes It**:
  - [`HookRigBase._resolveSwapUser`](../src/base/HookRigBase.sol#L153-L166) only queries `IMsgSender(sender).msgSender()` if `trustedRouters[sender] == true`. Otherwise, it falls back to `sender` (or a 20-byte beneficiary address passed in `hookData` for non-privileged recipient attribution).

---

### AV-07: Mid-Lifecycle Pool Reconfiguration & Static-Fee Flag Mismatch

- **Vulnerability**: Allowing a pool administrator to re-register a pool stack after initialization could alter tax rates, swap polarity, or recipients mid-flight. Initializing a pool without `LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`) when dynamic fee blocks are active causes `beforeSwap` fee overrides to silently fail.
- **How HookRig Fixes It**:
  - [`HookRigOrchestrator.registerPoolStack`](../src/HookRigOrchestrator.sol#L106-L120) sets `_poolRegistry[poolId].configLocked = true` on registration and reverts with `PoolStackAlreadyConfigured(poolId)` on any subsequent call. It also verifies `key.fee.isDynamicFee()` whenever any `Group 1` (`DynamicFee`, `ManagedFee`, `MarketHoursFee`) or `AntiSnipe` block is enabled.

---

### AV-08: Atomic JIT (Just-In-Time) Liquidity Dilution

- **Vulnerability**: MEV searchers bundle `[addLiquidity -> victim big buy swap -> removeLiquidity]` in the same block to capture ~99% of `PoolManager.donate()` rewards from `LPRewardsBlock` and `ArbRecaptureBlock` with zero directional duration risk.
- **How HookRig Fixes It**:
  - [`MEVProtectionBlock`](../src/blocks/protection/MEVProtectionBlock.sol) and [`JITGuardBlock`](../src/blocks/protection/JITGuardBlock.sol) record `lastAddBlock[poolId][positionKey] = uint64(block.number)` in `beforeAddLiquidity` and revert with `JITLiquidityCooldownActive` in `beforeRemoveLiquidity` if `block.number < lastAddBlock + minHoldBlocks`.

---

### AV-09: Flash-Loan Spot Price & TWAP Oracle Manipulation

- **Vulnerability**: An attacker takes a flash loan, skews spot tick by 5,000 ticks in a single transaction, triggers a false oracle reading or dynamic fee spike, and Arb-recaptures back.
- **How HookRig Fixes It**:
  - [`OracleBlock`](../src/blocks/trading/OracleBlock.sol) clamps single-step tick movement to `MAX_TICK_DELTA_PER_BLOCK = 200` ticks when accumulating `tickCumulative`.
  - [`CircuitBreakerBlock`](../src/blocks/protection/CircuitBreakerBlock.sol) maintains a rolling time-window anchor tick (`windowStartTick`) and reverts swaps that push the spot tick beyond `maxWindowTickDeviation` within `windowSeconds`.

---

### AV-10: Push-Transfer Blacklist / Reverting Recipient Swap DoS

- **Vulnerability**: If a hook performs direct ERC-20 `transfer()` calls to a `taxRecipient`, `feeShareRecipient`, `referrer`, or `KingOfThePool` winner *during* `afterSwap`, a blacklisted recipient (e.g., USDC blacklist) or a malicious contract that reverts on token receipt would permanently brick all swaps in the pool.
- **How HookRig Fixes It**:
  - During `afterSwap`, HookRig **never** pushes ERC-20 tokens to external recipients. Instead, [`AfterSwapDeltaAggregator`](../src/base/AfterSwapDeltaAggregator.sol#L204-L229) calls `poolManager.mint(address(this), unspecifiedCurrency.toId(), totalERC6909MintSlice)` once and credits internal pull-based balances via `_creditPoolClaim(...)`.
  - Recipients withdraw asynchronously via [`HookRigBase.withdrawClaim`](../src/base/HookRigBase.sol#L73-L86) or [`claimKingPot`](../src/HookRigOrchestrator.sol#L305-L315), which unlocks `PoolManager` (`_payoutERC6909Claim`), burns the ERC-6909 claim, and calls `poolManager.take(...)`.

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
| **FF-01** | **Limit Order Post-Fill Principal Lockup & Cross-Pool Spoofing** | Crossing a target tick marks `bucket.filled = true`; `cancelLimitOrder` reverts with `BucketAlreadyFilled`, leaving makers with no withdrawal path if no separate claim function exists. Additionally, passing a crafted `PoolKey` could withdraw another token from `HookRigOrchestrator`. | Added [`LimitOrdersBlock.claimLimitOrder`](../src/blocks/trading/LimitOrdersBlock.sol#L181-L186) ([`LimitOrdersLogic.claimOrder`](../src/blocks/trading/LimitOrdersBlock.sol#L98-L120)) and strict `PoolId.unwrap(key.toId()) == PoolId.unwrap(order.poolId)` verification (`OrderPoolKeyMismatch`) in both `cancelOrder` and `claimOrder`. | `PresetsAndSecurityVectorsTest::test_AntiFreeze01_LimitOrders_ClaimFilledOrderAndPoolKeyValidation` |
| **FF-02** | **`AutoBuybackBlock` Multi-Swap ERC-6909 Reserve Stranding & Cross-Currency Collision** | On accumulation swaps (`deployed == 0`), `AfterSwapDeltaAggregator` mints `bbCut` in ERC-6909 claims to `address(this)`. When a later swap crosses the floor tick (`deployed > 0`), donating only `bbCut` without burning the previously minted ERC-6909 reserve (`deployed - bbCut`) either reverts in `PoolManager` with currency delta mismatch or permanently strands the prior ERC-6909 reserve. Furthermore, accumulating `currency0` and `currency1` into a single `uint256 accumulatedReserve` mixes token denominations. | [`AutoBuybackBlock`](../src/blocks/rewards/AutoBuybackBlock.sol) isolates reserves per `Currency` (`mapping(Currency => uint256) reserveByCurrency`) and gates triggers on `activeLiquidity > 0`. [`AfterSwapDeltaAggregator`](../src/base/AfterSwapDeltaAggregator.sol#L168-L183) burns `priorReserve = deployed - bbCut` (`poolManager.burn`) while donating the full `deployed` amount to in-range LPs. | `PresetsAndSecurityVectorsTest::test_AntiFreeze02_AutoBuyback_MultiSwapReserveBurnAndZeroLiqSafety` |
| **FF-03** | **`KingOfThePool` Heterogeneous Currency Overwrite Freezing the Jackpot** | On an Exact-Input buy, `unspecifiedCurrency` is `projectCurrency`; on an Exact-Output buy, `unspecifiedCurrency` is `quoteCurrency`. If `KingOfThePool` overwrote `potCurrency = ctx.unspecifiedCurrency` while accumulating both into `potBalance`, calling `claimKingPot` would attempt to burn the combined `potBalance` from a single ERC-6909 currency ID and revert with insufficient ERC-6909 balance, freezing the entire pot. | [`AfterSwapDeltaAggregator`](../src/base/AfterSwapDeltaAggregator.sol#L148-L152) restricts `KingOfThePool` pot contributions to `ctx.unspecifiedCurrency == ctx.projectCurrency`, and [`HookRigOrchestrator.seedKingPotFromLaunchCurve`](../src/HookRigOrchestrator.sol#L326-L333) routes mismatched currency seeds to `poolClaims[poolId][currency][admin]` rather than corrupting `potCurrency`. | `BlocksUnitTest::test_Block14_KingOfThePool_JackpotCountdownAndClaim`, `PresetsAndSecurityVectorsTest::test_AttackVector05_ExactInAndExactOut_Token0AndToken1Polarity` |
| **FF-04** | **Stalled Launchpad Bonding Curve Capital Lockup & Accidental ETH Trapping** | If a launchpad bonding curve stalls and never reaches `graduationQuoteTarget`, buyers on a buy-only curve (`SteppedTrancheLaunch`) would have their capital permanently trapped. Additionally, sending non-zero `msg.value` to an ERC-20-quoted bonding curve would trap native ETH inside the curve contract. | Added pre-graduation `sell(...)` to [`SteppedTrancheLaunch`](../src/launchpad/curves/SteppedTrancheLaunch.sol#L148-L183) so buyers can always exit against `realQuoteRaised`, added cap-and-refund at `graduationQuoteTarget`, and enforced `require(msg.value == 0, "Unexpected ETH")` on ERC-20-quoted launches in both curves. | `LaunchpadSuiteTest::test_SteppedTrancheLaunch_TranchesAntiSnipeSurchargeAndGraduation` |
| **FF-05** | **Unbounded `JITGuard` Hold Duration or `CircuitBreaker` Window Permanently Freezing Pool / LP Exit** | If a pool creator configures `JITGuardParams.minLPHoldBlocks = type(uint32).max` (~1.65 billion years) or `CircuitBreakerParams.windowSeconds = type(uint32).max`, LP positions or pool swaps could be frozen forever without a governance intervention. | Enforced hard upper bounds [`MAX_LP_HOLD_BLOCKS = 7200`](../src/blocks/protection/JITGuardBlock.sol#L17) (~24 hours) in `JITGuardBlock` and [`MAX_WINDOW_SECONDS = 86_400`](../src/blocks/protection/CircuitBreakerBlock.sol#L18) (24 hours) in `CircuitBreakerBlock` so every lockup or circuit breaker automatically recovers within 24 hours. | `PresetsAndSecurityVectorsTest::test_AntiFreeze03_JITAndCircuitBreaker_HardCeilingsPreventInfiniteLock` |
| **FF-06** | **TWAMM Expired Order Unclaimed Earnings & Refund Liveness** | If a TWAMM order expires (`block.timestamp >= expiration`), calling `cancelTWAMMOrder` must never revert or forfeit already-streamed fills, and `executeVirtualOrders` must remain gas-bounded (`O(1)` per interval) even after long idle gaps. | [`TWAMMBlock.cancelTWAMMOrder`](../src/blocks/trading/TWAMMBlock.sol) checkpoints `executeVirtualOrders` up to `min(block.timestamp, expiration)` and refunds only the unstreamed remainder when `block.timestamp < expiration`, allowing clean post-expiry settlement. | `BlocksUnitTest::test_Block16_TWAMM_SubmitExecuteAndCancelRefund` |

---

## Custom Block Composition: Presets vs. All $2^{22} - 1$ Combinations

The 22 building blocks (`17 core + 5 expansion`) are **not** restricted to the 12 presets. Every block is an independent bit in `PoolStackConfig.enabledBlocksBitmap` (`bits 0..21`), meaning **all $2^{22} - 1 = 4,194,303$ non-empty block combinations** can be deployed via `PresetId.Blank` (or by starting from a preset and toggling additional bits).

### How Intra-Group & Cross-Group Combinations Resolve Without Conflict

1. **Multiple Fee Blocks Enabled Simultaneously (`Group 1` + `AntiSnipe`)**:
   - [`FeeAggregator.computeSwapFee`](../src/base/FeeAggregator.sol#L29-L63) resolves any subset of `{AntiSnipe, MarketHoursFee, ManagedFee, DynamicFee}` deterministically via a precedence waterfall:
     1. Active `AntiSnipe` window takes highest priority (`max(antiSnipeFee, baseFee)`).
     2. Otherwise, `MarketHoursFee` applies if enabled.
     3. Otherwise, `ManagedFee` applies if enabled.
     4. Otherwise, `DynamicFee` applies if enabled.
2. **Multiple Return-Delta Blocks Enabled Simultaneously (`Group 4` + `ArbRecapture` + `KingOfThePool` + `ReferralSplit` + `AutoBuyback`)**:
   - [`AfterSwapDeltaAggregator.executeAndSettleAfterSwap`](../src/base/AfterSwapDeltaAggregator.sol#L94-L234) evaluates all enabled return-delta blocks in a single pass, enforces `validateAggregateReturnDeltaBps <= 2,500 bps (25%)` at registration time, and performs **one aggregated settlement** (`1 burn + 1 donate + 1 ERC-6909 mint`) so blocks never fight over `PoolManager` deltas.
3. **Verification in `test/presets/PresetsAndSecurityVectors.t.sol`**:
   - `test_CustomStack_All22BlocksSimultaneously_KitchenSink()`: Enables all 22 blocks (`bitmap = (1 << 22) - 1 = 0x3FFFFF`) simultaneously on a single pool and executes buys, sells, limit orders, TWAMM orders, oracle checkpoints, and ERC-6909 claim withdrawals.
   - `test_CustomStack_MultiFeeBlockPrecedenceWaterfall()`: Enables all 4 fee blocks simultaneously and verifies the priority transition across blocks.
   - `testFuzz_ArbitraryBlockBitmapCombinations(uint32 rawBitmap, bool zeroForOne)`: Fuzzes random 22-bit bitmaps (`1 <= bitmap <= 0x3FFFFF`) across 1,000 runs and verifies every combination initializes, adds liquidity, and executes swaps without accounting mismatches.

