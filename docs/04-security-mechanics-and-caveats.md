# 04. Security Mechanics, Measures, Caveats & Best Practices

Because `hookrig` allows users to compose up to 17+ distinct building blocks and launch tokens across 3 curve models, security cannot rely on auditing individual blocks in isolation. It must enforce **system-wide composition invariants** and neutralize every known Uniswap v4 hook attack vector.

---

## 1. Real-World Uniswap v4 Hook Post-Mortems & Defenses

### Case Study A: Cork Protocol Exploit (~$12M Loss, May 2025)
- **What Happened**: An attacker drained ~3,761 `wstETH` from Cork Protocol's Uniswap v4 hook (`CorkHook`) and liquidity vault.
- **Root Causes**:
  1. **Missing Callback Access Control**: Critical hook entry points (`beforeSwap` and internal call dispatchers) did not strictly verify `msg.sender == address(poolManager)` or authenticate market context.
  2. **Cross-Market / Cross-Pool State Contamination**: The hook failed to isolate registered markets/pools. The attacker created a fake market using genuine derivative tokens from a legitimate market as the "redemption asset," tricking the hook into minting unbacked tokens and redeeming real underlying reserves.
- **`hookrig` Mandatory Defense**:
  - Every hook and sub-hook entry point inherits OpenZeppelin's `BaseHook` (`onlyPoolManager` on all external callbacks) or enforces `onlyOrchestrator`.
  - Every storage mapping and ERC-6909 claim is strictly isolated by `PoolId` (`key.toId()`). A malicious pool `[RealToken, FakeToken]` can never touch claims, state, or reserves of `[RealToken, WETH]`.

### Case Study B: Bunni V2 Exploit (~$8.4M Loss, September 2025)
- **What Happened**: Attackers drained $2.4M on Ethereum and $5.9M on Unichain from Bunni V2's Uniswap v4 liquidity management hook.
- **Root Causes**:
  1. **Rounding Direction Inversion in Custom Accounting**: Inside the custom Liquidity Distribution Function (LDF) and withdrawal logic, developers assumed rounding down an intermediate value would safely favor idle pool reserves. Under specific edge-case tick states, the rounding direction favored the withdrawing user instead.
  2. **Flash-Loan Amplification**: Using flash loans and carefully sized exact-input swaps to push spot ticks to boundary conditions, the attacker repeatedly triggered the precision error, accumulating unbacked share value and withdrawing more underlying tokens than deposited.
- **`hookrig` Mandatory Defense (The Anti-Bunni Rounding Law)**:
  - Every `Math.mulDiv` explicitly specifies a rounding direction:
    - **Credits leaving the pool/hook to a user**: Always round **DOWN** (`Math.Rounding.Floor`).
    - **Debts/fees entering the pool/hook from a user**: Always round **UP** (`Math.Rounding.Ceil`).
    - **Hook cuts sliced from `unspecifiedDelta`**: Always round **DOWN** (`Math.Rounding.Floor`) so the sum of parts never exceeds total swap output.

---

## 2. Core Uniswap v4 & Composable Hook Threat Matrix

| # | Attack Vector | Mechanism | `hookrig` Architectural Mitigation |
| :--- | :--- | :--- | :--- |
| **1** | **The `msg.sender` vs. `sender` Router Paradox** | Inside any hook callback, `msg.sender` is `PoolManager`, while `sender` is the **Router** (not the end-user EOA). Trusting `sender` allows router spoofing or steals user rewards, while trusting unauthenticated `hookData` from an arbitrary router allows identity spoofing. | `AccessControlLogic.resolveUser` resolves the end-user via `IMsgSender(sender).msgSender()` or 20/32-byte `hookData` **strictly when `isTrustedRouter[sender] == true`**. For untrusted routers, it unconditionally returns `sender`, preventing `hookData` spoofing across `AccessControl`, `WalletCap`, `VestingSellCap`, `JITGuard`, and `KingOfThePool`. |
| **2** | **`BeforeSwapDelta` & Return-Delta Insolvency** | Mismatched sign conventions (`amountSpecified < 0` vs `BalanceDelta > 0`), unchecked `int128` bit-packing casts, or unsettled hook deltas revert or drain pools. | Standardized `AfterSwapDeltaAggregator` using OpenZeppelin `SafeCast.toInt128()`, `CurrencySettler`, and single-pass settlement invariant verification. |
| **3** | **Permission Bitmap & CREATE2 Salt Mismatch** | `PoolManager` only invokes callbacks whose corresponding bit in the lowest 14 bits of the hook address is `1`. | Constructor-time `Hooks.validateHookPermissions(this, getHookPermissions())` enforced via OpenZeppelin `BaseHook`. |
| **4** | **Pool DoS & Liquidity Lockup** | Reverting external calls, oracle staleness reverts, unbounded loops, or blacklisted token push-transfers inside `beforeRemoveLiquidity` or `afterSwap`. | 1. `beforeRemoveLiquidity` **never** runs `Access control` or reverting external checks.<br>2. All payouts (`Fee sharing`, `Buy/Sell tax`, `King of the Pool`) use **pull-based ERC-6909 claims** instead of push ERC-20 transfers during swaps. |
| **5** | **Dynamic Fee & Spot Oracle Manipulation** | Flash-loan swaps skewing spot `sqrtPriceX96` in the same block to manipulate dynamic fees or trigger false rebalances. | `Oracle` checkpoints pre-swap ticks with truncated max tick movement per block; `Dynamic fee` uses bounded volatility windows. |
| **6** | **Non-Standard Token & Native ETH Traps** | Fee-on-transfer tokens, zero-value transfer reverts, or Native ETH (`CurrencyLibrary.ADDRESS_ZERO`) requiring `msg.value` settlement. | OpenZeppelin `CurrencySettler` handles Native ETH vs ERC-20 branching and zero-amount guards automatically. |
| **7** | **Mid-Lock Pipeline Mutation** | Modifying a pool's enabled blocks mid-transaction between `beforeSwap` and `afterSwap`. | Pool block bitmaps are locked at `afterInitialize` and guarded against mutation while `PoolManager` is unlocked. |

---

## 3. Six Advanced Security Mechanics & Subtle Caveats

Beyond standard v4 checks, `hookrig` specifically defends against six subtle protocol-level attack vectors:

### 3.1 JIT (Just-In-Time) Liquidity Dilution on `LP rewards` & `Arb recapture`
- **The Attack**: `LP rewards` and `Arb recapture` call `PoolManager.donate()` inside `afterSwap`, which distributes rewards pro-rata to currently active in-range liquidity `L`. An MEV searcher who sees a large buy swap in the mempool can front-run with a massive single-tick `addLiquidity`, absorb $99\%$ of the `donate()` reward in `afterSwap`, and immediately back-run with `removeLiquidity` in the same block.
- **Our Defense**:
  - Optional **`JIT Liquidity Guard` (`jit_guard`)** tracks `lastAddBlock[poolId][positionKey]` in `beforeAddLiquidity` keyed on the canonical `PoolManager` position `(routerSender, tickLower, tickUpper, salt)`.
  - If liquidity is removed within `minHoldBlocks` (even `1` block prevents atomic JIT bundles), `beforeRemoveLiquidity` reverts with `JITExitPenaltyRequired(poolId, positionKey, earlyExitPenaltyBps)` when an exit penalty is configured or `JITGuardHoldActive` otherwise.

### 3.2 Recursive Hook Self-Swap Deadlocks (`TWAMM` & `Limit orders`)
- **The Attack**: When `Limit orders` or `TWAMM` executes virtual swaps or modifies liquidity *inside* a hook callback (`beforeSwap` or `afterSwap`), `PoolManager` is already unlocked. If the hook calls `PoolManager.swap()` to settle a virtual order, `PoolManager` will recursively invoke `Hook.beforeSwap()` and `Hook.afterSwap()` again—causing infinite recursion, double taxation, or corrupted transient storage snapshots.
- **Our Defense**:
  - `TransientContext` maintains a per-`PoolId` transient reentrancy/bypass flag (`bool isInternalHookExecution`).
  - Whenever `TWAMM` or `Limit orders` initiates an internal `PoolManager` action, it sets `isInternalHookExecution = true` in `EIP-1153` transient storage, causing the re-entered callback to immediately return a no-op selector and zero delta.

### 3.3 `afterSwapReturnDelta` Exact-In vs. Exact-Out Direction Inversion
- **The Attack**: In Uniswap v4, `afterSwapReturnDelta` always modifies the **unspecified currency**:
  - On **Exact-Input (`amountSpecified < 0`)**, the unspecified currency is the **output token** (the Hook takes a cut of output tokens).
  - On **Exact-Output (`amountSpecified > 0`)**, the unspecified currency is the **input token** (returning a positive delta charges the trader extra input tokens!).
  - If a hook blindly assumes `afterSwapReturnDelta` is always the output token, an attacker can submit an `exactOutput` buy (`amountSpecified > 0`) to force the hook to tax/burn the quote token instead of the project token, or underflow delta math.
- **Our Defense**:
  - `AfterSwapDeltaAggregator` explicitly branches on `params.amountSpecified < 0` vs `> 0`.
  - On `exactOutput` swaps, percentage cuts are computed against the gross input amount in the unspecified currency (using `Math.Rounding.Ceil` on added input cost), and `Auto burn` / `King of the Pool` only execute when `ctx.unspecifiedCurrency == ctx.projectCurrency` (`GL-24`, `FF-03`).

### 3.4 `LP rewards` & `Arb recapture` Zero-Liquidity `donate()` Revert
- **The Caveat**: Calling `PoolManager.donate(key, amount0, amount1, "")` when active in-range liquidity `L == 0` reverts inside `PoolManager` (`NoLiquidityToReceiveFees`).
- **Our Defense**: Before calling `PoolManager.donate()`, `AfterSwapDeltaAggregator` checks `StateLibrary.getLiquidity(poolManager, poolId) > 0`. If active liquidity is `0`, the LP reward slice is skipped (`0` delta taken) or routed to a per-pool pending reward claim until liquidity returns, ensuring swaps never brick in thin pools.

### 3.5 `King of the Pool` Dust-Reset Griefing & Router Crown Theft
- **The Caveats**:
  1. Without a minimum buy threshold, a bot could reset a 168-hour `King of the Pool` countdown timer forever by swapping $\$0.01$ every few hours.
  2. Recording `sender` as the King would credit the Router contract instead of the trader.
- **Our Defense**:
  - Enforces a configurable `minBuyAmountForReset` (denominated in quote currency or basis points of current pot). Buys below this threshold still contribute `potBps` if configured, but **do not reset the timer or transfer the crown**.
  - Resolves the King's address via `IMsgSender(sender).msgSender()` or verified `hookData` recipient (on trusted routers), and settles payouts strictly via pull (`claimKingPot(poolId, roundId, recipient)`).

### 3.6 Aggregate Return-Delta Budget Guardrail
- **The Caveat**: If a user stacks multiple return-delta blocks (`Arb recapture` + `Buy and sell tax` + `Auto burn` + `Fee sharing` + `LP rewards` + `King of the Pool` + `Referral split` + `Auto buyback` + `5 bps` `Protocol Royalty`) with excessive percentages, total cuts could exceed $100\%$ of swap output.
- **Our Defense**: `AfterSwapDeltaAggregator._validateAggregateReturnDeltaBudget` validates at pool configuration that neither the maximum Buy-side cut (`maxBuyBps`) nor the maximum Sell-side cut (`maxSellBps`), including `PROTOCOL_ROYALTY_BPS = 5`, can exceed `MAX_AGGREGATE_AFTER_SWAP_BPS = 2500` ($25\%$).

### 3.7 Audit Hardening (2026-10-15 three-pass audit)
- **Queued LP donations**: `ArbRecapture`, `LPRewards` and `AutoBuyback` cuts are always taken, held as hook ERC-6909 (`pendingLPDonation`), and donated in `beforeSwap` of a later swap — never by the swap that paid them, and never in a block where liquidity was added. A just-in-time position must therefore hold across a block boundary, like any other LP.
- **Exact-output buys** revert (`ExactOutputBuyNotSupported`) on pools with `AutoBurn` or `King of the Pool`, because both cut the project token on the unspecified leg.
- **Preset hooks** reject any block whose callbacks the hook address does not enable (`validateBitmapAndPermissions` compares `permissionsForBitmap(bitmap)` with the address flags).
- **Launchpad**: launches accept only the default orchestrator, reject `AccessControl` and AntiSnipe launch fees above 25%, cap `tickSpacing` at `MAX_TICK_SPACING`, and bind the CREATE2 salt to the sender. Pools can only be registered for tokens that already exist.
- **Graduation**: `SteppedTrancheLaunch` opens the pool at the price of the last curve fill and seeds the King pot only when the pool runs `King of the Pool`; `VirtualXYKLaunch` seeds proportionally less quote when it clamps LP tokens. The curve-owned graduation LP is locked by design, so its fees stay in `PoolManager` (the equivalent of burned LP tokens).
- **Known limit**: the JIT guard keys hold periods per end user, so an attacker who adds from one address and removes an older position from another still escapes the hold. Keying by the router-owned position instead would let any router user re-lock everyone else's liquidity.

---

## 4. Trust Taxonomy & Immutable On-Chain Anti-Rug Caps

Every block in `hookrig` is assigned an explicit **Trust Level** (`Low` vs. `Medium`). Even for `Medium` trust blocks where a pool manager or creator can configure parameters, `hookrig` enforces **immutable hard caps** in code so a malicious or compromised manager can never rug user funds:

| Block | Trust Level | Manager Capability | Immutable On-Chain Hard Guardrail (Anti-Rug) |
| :--- | :--- | :--- | :--- |
| **Dynamic fee** | Low | Immutable once initialized | Bounded between `minFee` and `MAX_DYNAMIC_FEE` ($\le 5\%$). |
| **Managed fee** | Medium | Manager can update LP fee | Cannot exceed immutable `feeCap` set at initialization (max $\le 5\%$). |
| **Market-hours fee** | Low | Immutable UTC schedule | Open/closed fees bounded at initialization ($\le 5\%$). |
| **Anti-snipe** | Low | Immutable decay curve | Monotonically decreases from `launchFee` to `baseFee` over $N$ blocks; can never be re-triggered after block $N$. |
| **MEV protection** | Low | Immutable impact/cooldown bounds | Purely algorithmic; cannot block normal retail-sized swaps. |
| **Arb recapture** | Medium | Configurable recapture share % | Recapture cut capped at $\le 80\%$ of measured arbitrage spread; 100% of captured value is donated to pool LPs (`PoolManager.donate`). |
| **Access control** | Medium | Manager updates allowlist / verifier | **Applies ONLY to `beforeAddLiquidity` and/or `beforeSwap`**. Never applies to `beforeRemoveLiquidity`, guaranteeing an unhindered exit even if a user is later removed from the allowlist. |
| **Wallet cap** | Low | Immutable max % of supply (or auto-sunset after $M$ blocks) | Checks `projectToken.balanceOf(recipient) <= maxWalletAmount`. Cannot freeze selling (`isBuy == false` is always exempt). |
| **Buy and sell tax** | Medium | `poolAdmin` can call `setBuySellTax` | Hard cap: `buyTaxBps <= 1000` ($10\%$) and `sellTaxBps <= 1000` ($10\%$). Always **decay-only**: `setBuySellTax` can only lower taxes after registration, whatever `decayOnly` says. |
| **Auto burn** | Medium | Burn bps configured at init | Hard cap: `burnBps <= 500` ($5\%$). Applies on buys when `unspecifiedCurrency == projectCurrency` only (`GL-24`). |
| **Fee sharing** | Medium | Recipient split updates | Hard cap: `feeShareBps <= 500` ($5\%$). Stored as pullable ERC-6909 claims. |
| **LP rewards** | Medium | Extra buy fee bps | Hard cap: `lpRewardBps <= 500` ($5\%$). Queued as hook ERC-6909 and donated by the first swap of a later block with no liquidity added (see 3.7). |
| **Swap rewards** | Low | Emission rate | Non-custodial accounting points on net post-cut swap volume; cannot block swaps. |
| **King of the Pool** | Medium | Pot fee bps & round duration | Hard cap: `potBps <= 500` ($5\%$). Winner claims jackpot via pull (`claimKingPot(poolId, roundId, recipient)`)—never pushed mid-swap. |
| **Limit orders** | Low | Fully permissionless | Per-pool currency escrow isolation (`limitOrderPoolEscrow`); users can always cancel unclaimed orders, filled or not (`cancelLimitOrder`), or claim filled orders (`claimLimitOrder`, with an optional `minAmountOut`). The claim swap runs the full hook pipeline and is attributed to the maker. |
| **TWAMM** | Low | Fully permissionless | **New orders are disabled** (`submitTWAMMOrder` reverts `TWAMMOrdersDisabled`): the block only tracks virtual volume and never swaps deposits. Existing orders stay cancellable for a full refund. |
| **Oracle** | Low | Fully permissionless | Truncated max tick delta per second (`100 * dt` in `int256` before clamping to `[MIN_TICK, MAX_TICK]`) to resist flash-loan TWAP manipulation without `int24` overflow. |
| **JIT Guard** *(Expansion #18)* | Low | Immutable cooldown / early-exit penalty | Prevents same-block `addLiquidity -> donate -> removeLiquidity` MEV dilution; enforces `earlyExitPenaltyBps` on early removal. |
| **Circuit Breaker** *(Expansion #19)* | Low | Immutable rolling tick band & window | Purely algorithmic rolling price-band guard; auto-resets after `windowSeconds` ($\le 24\text{h}$) so pools cannot be permanently frozen. |
| **Referral Split** *(Expansion #20)* | Low | Immutable bps cap (`<= 300 bps`) | First-touch referrer binding with strict anti-self-referral check (`referrer != trader`) and pull-based ERC-6909 claims. |
| **Vesting Sell Cap** *(Expansion #21)* | Low | Immutable daily epoch % cap | Enforces anti-honeypot floor (`maxDailySellBps >= 50` / `0.50%` per day) so selling can never be completely disabled. The epoch balance nets out open PoolManager deltas (no flash-loan inflation) and drops when tokens leave the wallet; sells through an untrusted router that holds no tokens are not capped rather than bricked. Per-wallet caps cannot stop a holder who splits tokens across wallets. One-sided liquidity adds are rejected on capped pools. |
| **Auto Buyback** *(Expansion #22)* | Medium | Immutable bps cap (`<= 500 bps`) & floor tick | Accumulates swap fee slice inside pool-isolated reserve. `minBuybackReserve` is denominated in the quote currency; once reached below `triggerFloorTick`, both currency reserves move into the queued LP donation (see 3.7). |

---

## 5. Verification & Testing Standards (Foundry + Medusa + Echidna)

Every `hookrig` block, preset, and launchpad curve is verified across **67 Foundry test suites** and **91 Medusa stateful fuzzing tests (`56 properties: 26 Global GL-01..GL-26 + 30 Specific SP-01..SP-30`)** achieving **84%–100% line coverage across all 35 `src/` contracts** (see [**06. Attack Vectors, Mitigations & Code-Level Fixes**](./06-attack-vectors-and-fixes.md) and [**PROPERTIES.md**](../PROPERTIES.md)):

1. **Permission Bitmap & Tier-3 Mutex Invariant Test**: Automated verification that `Hooks.Permissions` matches the 14-bit address flags across all 12 presets and all `2,843` valid Tier-3 block combinations.
2. **Delta Conservation & Full ERC-6909 Solvency (`GL-01`, `GL-02`, `SP-09`)**: Stateful Medusa & Foundry invariant fuzzing proving that across arbitrary sequences of `swap` (exact-in & exact-out), `modifyLiquidity`, `donate`, and `claim`, `PoolManager` + Hook ERC-6909 claims + King pots + AutoBuyback reserves remain strictly solvent (`sum(claims + pots + reserves) <= actual_erc6909_balance`).
3. **Rounding Monotonicity & No-Round-Trip-Profit Proofs (`SP-04`, `SP-05`, `SP-06`, `SP-10`–`SP-13`, `SP-26`, `SP-29`)**: Fuzz tests proving no sequence of dust swaps, bonding curve buy/sell cycles, or LP deposit/withdraw cycles can extract net positive value (`valueOut <= valueIn`), and exact-output cuts round up (`Math.Rounding.Ceil`).
4. **Withdrawal & Order Liveness Invariants (`GL-04`, `GL-17`, `GL-19`, `SP-01`–`SP-03`, `SP-21`, `SP-22`, `SP-28`, `SP-30`)**: Fuzz tests proving LPs, curve buyers, and limit/TWAMM order makers can **always** withdraw liquidity, exit bonding curves, or cancel/claim orders without `int24` oracle truncation or cross-pool escrow drain.
5. **Graduation Price Continuity & Zero Stranded Value (`GL-09`–`GL-15`, `GL-23`, `GL-26`, `SP-07`, `SP-08`, `SP-27`)**: Fuzz tests across `VirtualXYKLaunch` and `SteppedTrancheLaunch` proving that graduation initializes the v4 pool within `< 1%` of the final marginal curve price, refunds unused quote, and burns any excess `lpTokenReserve` so zero tokens remain stranded.
