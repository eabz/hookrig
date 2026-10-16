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
- **The Attack**: `LP rewards`, `Arb recapture`, and `Auto buyback` distribute rewards to in-range liquidity `L` via `PoolManager.donate()`. An MEV searcher who sees a swap in the mempool can attempt to front-run with a single-tick `addLiquidity`, absorb `donate()` rewards, and immediately back-run with `removeLiquidity`.
- **Our Defense**:
  1. **Deferred Block-Gated LP Donations (`pendingLPDonation`)**: `ArbRecapture`, `LPRewards`, and `AutoBuyback` queue donations as ERC-6909 claims in `pendingLPDonation[poolId][currency]` during `afterSwap` and only flush them via `PoolManager.donate()` in `beforeSwap` of a later transaction when `block.number > _lastLiquidityAddBlock[poolId]`.
  2. **Per-Owner Tracked Liquidity & Position Hold (`JITGuard`)**: `JITGuardBlock` tracks both `lpAddedBlock` and `lpTrackedLiquidity` per `ownerKey` `(sender, lpOwner, tickLower, tickUpper, salt)` and per `posKey` `(sender, tickLower, tickUpper, salt)`. If an account attempts to remove more liquidity than its own `lpTrackedLiquidity[poolId][ownerKey]` (e.g., adding from account A and removing from account B on a shared router), `JITGuard` enforces the underlying `posKey`'s latest addition block as well. On shared untrusted routers (`lpOwner == sender`), dust additions (`< 5%` of existing tracked liquidity) do not reset an existing position's hold timer. When `jitExitPenaltyBps > 0` and `minLPHoldBlocks == 0`, `JITGuard` enforces a minimum 1-block hold in `beforeRemoveLiquidity` (no principal confiscation).

### 3.2 Recursive Hook Self-Swap Deadlocks (`TWAMM` & `Limit orders`)
- **The Attack**: When `Limit orders` or `TWAMM` executes virtual/claim swaps *inside* `beforeSwap` or via dedicated swap executors, `PoolManager` invokes `Hook.beforeSwap()` and `Hook.afterSwap()`. Without reentrancy/executor recognition, internal swaps would trigger recursive hook execution, double taxation, or corrupted transient storage snapshots.
- **Our Defense**:
  - `LimitOrderSwapExecutor` implements `IMsgSender` so limit-order claim swaps run through the full hook pipeline attributed to the order maker (`minAmountOut` slippage protection via `claimLimitOrder(key, orderId, minAmountOut)`).
  - `TWAMMBlock` settles accrued virtual order volume against pool liquidity in `beforeSwap` (and via `TWAMMSwapExecutor` when triggered outside `unlock` during `claimTWAMMOrder` / `cancelTWAMMOrder`), while `HookRigOrchestrator` bypasses recursive hook logic when `sender == address(this) || sender == address(_twammExecutor)`.

### 3.3 `afterSwapReturnDelta` Exact-In vs. Exact-Out Direction Inversion
- **The Attack**: In Uniswap v4, `afterSwapReturnDelta` always modifies the **unspecified currency**:
  - On **Exact-Input (`amountSpecified < 0`)**, the unspecified currency is the **output token** (the Hook takes a cut of output tokens).
  - On **Exact-Output (`amountSpecified > 0`)**, the unspecified currency is the **input token** (returning a positive delta charges the trader extra input tokens!).
  - If a hook blindly assumes `afterSwapReturnDelta` is always the output token, an attacker can submit an `exactOutput` buy (`amountSpecified > 0`) to force the hook to tax/burn the quote token instead of the project token, or underflow delta math.
- **Our Defense**:
  - `AfterSwapDeltaAggregator` explicitly branches on `params.amountSpecified < 0` vs `> 0`.
  - On `exactOutput` swaps, percentage cuts are computed against the gross input amount in the unspecified currency (using `Math.Rounding.Ceil` on added input cost), and `exactOutput` buys revert with `ExactOutputBuyNotSupported` on pools with `Auto burn` or `King of the Pool` (`GL-24`, `FF-03`).

### 3.4 `LP rewards` & `Arb recapture` Zero-Liquidity `donate()` Revert
- **The Caveat**: Calling `PoolManager.donate(key, amount0, amount1, "")` when active in-range liquidity `L == 0` reverts inside `PoolManager` (`NoLiquidityToReceiveFees`).
- **Our Defense**: LP reward cuts are queued in `pendingLPDonation[poolId][currency]` during `afterSwap`, and `AutoBuybackLogic.flushPendingDonations` only calls `PoolManager.donate()` in `beforeSwap` when `StateLibrary.getLiquidity(poolManager, poolId) > 0` and `block.number > _lastLiquidityAddBlock[poolId]`, ensuring swaps never brick in thin or zero-liquidity pools.

### 3.5 `King of the Pool` Dust-Reset Griefing & Router Crown Theft
- **The Caveats**:
  1. Without a minimum buy threshold, a bot could reset a 168-hour `King of the Pool` countdown timer forever by swapping $\$0.01$ every few hours.
  2. Recording an untrusted `sender` as the King would credit a shared Router contract instead of an EOA trader.
- **Our Defense**:
  - Enforces a configurable `minBuyAmountForReset` (and requires a non-zero `potContribution > 0`). Buys below this threshold still contribute `potBps` to the pot, but **do not reset the timer or transfer the crown**.
  - Resolves the King's address via `IMsgSender(sender).msgSender()` or verified `hookData` recipient on trusted routers; swaps through untrusted routers (`trader == sender`) contribute to the pot without crowning the router contract. Payouts settle strictly via pull (`claimKingPot(poolId, roundId, recipient)`).

### 3.6 Aggregate Return-Delta Budget Guardrail
- **The Caveat**: If a user stacks multiple return-delta blocks (`Arb recapture` + `Buy and sell tax` + `Auto burn` + `Fee sharing` + `LP rewards` + `King of the Pool` + `Referral split` + `Auto buyback` + `5 bps` `Protocol Royalty`) with excessive percentages, total cuts could exceed $100\%$ of swap output.
- **Our Defense**: `AfterSwapDeltaAggregator.validateTaxBudget` validates at pool configuration that neither the maximum deterministic Buy-side cut (`maxBuyBps`) nor the maximum deterministic Sell-side cut (`maxSellBps`), including `PROTOCOL_ROYALTY_BPS = 5`, can exceed `MAX_AGGREGATE_AFTER_SWAP_BPS = 2500` ($25\%$), while dynamic runtime slices (`ArbRecapture`) are bounded by remaining budget inside `_executeAfterSwapDeltaWaterfall`.

### 3.7 Audit Hardening (2026-10-15 four-pass audit)
- **Queued LP donations**: `ArbRecapture`, `LPRewards` and `AutoBuyback` cuts are always taken, held as hook ERC-6909 (`pendingLPDonation`), and donated in `beforeSwap` of a later swap — never by the swap that paid them, and never in a block where liquidity was added.
- **Exact-output buys** revert (`ExactOutputBuyNotSupported`) on pools with `AutoBurn` or `King of the Pool`, because both cut the project token on the unspecified leg.
- **Pool initialization authentication**: Registered pools can only be initialized in `PoolManager` by their `poolAdmin` (or `owner`) for standard pools, or by `authorizedCurve` for launchpad pools (`UnauthorizedPoolInitializer`). `setLaunchpadFactory` is one-time-only (`LaunchpadFactoryAlreadySet`).
- **Untrusted router attribution hardening**: `WalletCap` rejects buys through untrusted routers (`UntrustedRouterNotAllowedForWalletCap`) so disposable router contracts cannot bypass per-wallet caps; `KingOfThePool` and `ReferralSplit` do not crown or pay referral cuts to untrusted routers; `AccessControl` rejects self-attributed router addresses.
- **Launchpad**: launches accept only the default orchestrator, reject `AccessControl` and AntiSnipe launch fees above 25%, cap `tickSpacing` at `MAX_TICK_SPACING`, require non-zero `tokensOut` and reject fee-on-transfer quote tokens, validate `NativeTickLaunch` bands with zero stranded dust, gate creator `LaunchpadVestingWallet` releases until graduation, and bind the CREATE2 salt to the deployer (`predictTokenAddressFor(meta, salt, deployer)`).

---

## 4. Trust Taxonomy & Immutable On-Chain Anti-Rug Caps

Every block in `hookrig` is assigned an explicit **Trust Level** (`Low` vs. `Medium`). Even for `Medium` trust blocks where a pool manager or creator can configure parameters, `hookrig` enforces **immutable hard caps** in code so a malicious or compromised manager can never rug user funds:

| Block | Trust Level | Manager Capability | Immutable On-Chain Hard Guardrail (Anti-Rug) |
| :--- | :--- | :--- | :--- |
| **Dynamic fee** | Low | Immutable once initialized | Bounded between `baseFee` and `maxFee` ($\le 5\%$). Observes completed pre-swap tick displacement and prevents same-block zero-delta wash swaps from decaying `emaTickDelta`. |
| **Managed fee** | Medium | Manager can update LP fee | Cannot exceed immutable `feeCap` set at initialization (max $\le 5\%$); pre-initialization updates stage the fee without reverting. |
| **Market-hours fee** | Low | Immutable UTC schedule | Open/closed fees bounded at initialization ($\le 5\%$). |
| **Anti-snipe** | Low | Immutable decay curve | Monotonically decreases from `launchFee` to `normalFee` over $N$ blocks; can never be re-triggered after block $N$. |
| **MEV protection** | Low | Immutable impact/cooldown bounds | Purely algorithmic; direction lock ignores `<= 1` tick dust swaps so 1-wei swaps cannot grief opposite-direction traders. |
| **Arb recapture** | Medium | Configurable recapture share % | Recapture cut capped at $\le 80\%$ of measured arbitrage spread; `referenceTick` remains anchored across sub-threshold steps to prevent split-swap evasion. |
| **Access control** | Medium | Manager updates allowlist / verifier | **Applies ONLY to `beforeAddLiquidity` and/or `beforeSwap`**. Never applies to `beforeRemoveLiquidity`, guaranteeing an unhindered exit even if a user is later removed from the allowlist. |
| **Wallet cap** | Low | Immutable max % of supply (or auto-sunset after $M$ blocks) | Checks `projectToken.balanceOf(recipient) <= maxWalletAmount` on trusted routers (`UntrustedRouterNotAllowedForWalletCap` on untrusted routers). Cannot freeze selling (`isBuy == false` is always exempt). |
| **Buy and sell tax** | Medium | `poolAdmin` can call `setBuySellTax` | Hard cap: `buyTaxBps <= 1000` ($10\%$) and `sellTaxBps <= 1000` ($10\%$). Always **decay-only**: `setBuySellTax` can only lower taxes after registration, and passing `newRecipient = address(0)` preserves the existing recipient. |
| **Auto burn** | Medium | Burn bps configured at init | Hard cap: `burnBps <= 500` ($5\%$). Burns actual received balance around `PoolManager.take()`. |
| **Fee sharing** | Medium | Recipient split updates | Hard cap: `feeShareBps <= 500` ($5\%$). Stored as pullable ERC-6909 claims. |
| **LP rewards** | Medium | Extra buy fee bps | Hard cap: `lpRewardBps <= 500` ($5\%$). Queued as hook ERC-6909 and donated by the first swap of a later block with no liquidity added (see 3.7). |
| **Swap rewards** | Low | Emission rate | Non-custodial accounting points on net post-cut project token volume; cannot block swaps. |
| **King of the Pool** | Medium | Pot fee bps & round duration | Hard cap: `potBps <= 500` ($5\%$). Winner claims jackpot via pull (`claimKingPot(poolId, roundId, recipient)`)—never pushed mid-swap. |
| **Limit orders** | Low | Fully permissionless | Per-pool currency escrow isolation (`limitOrderPoolEscrow`) and epoch-indexed tick buckets (`MAX_TICK_FILLS_PER_SWAP = 512`). Users can always cancel unclaimed orders (`cancelLimitOrder`) or claim filled orders (`claimLimitOrder(key, orderId, minAmountOut)`). |
| **TWAMM** | Low | Fully permissionless | Enforces `MIN_TWAMM_ORDER_AMOUNT = 1000` and `totalAmount >= durationSeconds` on initialized pools; settles streamed volume in `beforeSwap` (or via `TWAMMSwapExecutor` on `claimTWAMMOrder` / `cancelTWAMMOrder`) and refunds unswapped input + truncation dust. |
| **Oracle** | Low | Fully permissionless | Truncated max tick delta per second (`100 * dt` in `int256` before clamping to `[MIN_TICK, MAX_TICK]`) to resist flash-loan TWAP manipulation without `int24` overflow. |
| **JIT Guard** *(Expansion #18)* | Low | Immutable cooldown / hold floor | Tracks per-owner `lpTrackedLiquidity` and `lpAddedBlock` to prevent cross-account removal bypasses and 1-wei shared-router griefing; `jitExitPenaltyBps > 0` enforces a minimum 1-block hold floor. |
| **Circuit Breaker** *(Expansion #19)* | Low | Immutable rolling tick band & window | Purely algorithmic rolling price-band guard; auto-resets after `windowSeconds` ($\le 24\text{h}$) so pools cannot be permanently frozen. |
| **Referral Split** *(Expansion #20)* | Low | Immutable bps cap (`<= 300 bps`) | First-touch referrer binding with anti-self-referral and trusted-router exclusion checks, plus pull-based ERC-6909 claims. |
| **Vesting Sell Cap** *(Expansion #21)* | Low | Immutable daily epoch % cap | Enforces anti-honeypot floor (`maxDailySellBps >= 50` / `0.50%`) and ceiling (`<= 5000` / `50%` per day). Stateless pass-through routers holding zero post-settlement tokens do not brick. |
| **Auto Buyback** *(Expansion #22)* | Medium | Immutable bps cap (`<= 500 bps`) & floor tick | Accumulates swap fee slice inside pool-isolated reserve. Once `minBuybackReserve` in quote currency is reached and project token price drops to/beyond `triggerFloorTick`, both currency reserves move into `pendingLPDonation`. |

---

## 5. Verification & Testing Standards (Foundry + Medusa + Echidna)

Every `hookrig` block, preset, and launchpad curve is verified across **67 Foundry test suites** and **91 Medusa stateful fuzzing tests (`56 properties: 26 Global GL-01..GL-26 + 30 Specific SP-01..SP-30`)** achieving **84%–100% line coverage across all 35 `src/` contracts** (see [**06. Attack Vectors, Mitigations & Code-Level Fixes**](./06-attack-vectors-and-fixes.md) and [**PROPERTIES.md**](../PROPERTIES.md)):

1. **Permission Bitmap & Tier-3 Mutex Invariant Test**: Automated verification that `Hooks.Permissions` matches the 14-bit address flags across all 12 presets and all `2,843` valid Tier-3 block combinations.
2. **Delta Conservation & Full ERC-6909 Solvency (`GL-01`, `GL-02`, `SP-09`)**: Stateful Medusa & Foundry invariant fuzzing proving that across arbitrary sequences of `swap` (exact-in & exact-out), `modifyLiquidity`, `donate`, and `claim`, `PoolManager` + Hook ERC-6909 claims + King pots + AutoBuyback reserves remain strictly solvent (`sum(claims + pots + reserves) <= actual_erc6909_balance`).
3. **Rounding Monotonicity & No-Round-Trip-Profit Proofs (`SP-04`, `SP-05`, `SP-06`, `SP-10`–`SP-13`, `SP-26`, `SP-29`)**: Fuzz tests proving no sequence of dust swaps, bonding curve buy/sell cycles, or LP deposit/withdraw cycles can extract net positive value (`valueOut <= valueIn`), and exact-output cuts round up (`Math.Rounding.Ceil`).
4. **Withdrawal & Order Liveness Invariants (`GL-04`, `GL-17`, `GL-19`, `SP-01`–`SP-03`, `SP-21`, `SP-22`, `SP-28`, `SP-30`)**: Fuzz tests proving LPs, curve buyers, and limit/TWAMM order makers can **always** withdraw liquidity, exit bonding curves, or cancel/claim orders without `int24` oracle truncation or cross-pool escrow drain.
5. **Graduation Price Continuity & Zero Stranded Value (`GL-09`–`GL-15`, `GL-23`, `GL-26`, `SP-07`, `SP-08`, `SP-27`)**: Fuzz tests across `VirtualXYKLaunch` and `SteppedTrancheLaunch` proving that graduation initializes the v4 pool within `< 1%` of the final marginal curve price, refunds unused quote, and burns any excess `lpTokenReserve` so zero tokens remain stranded.
