# HookRig — Composable Hook Building Blocks & Token Launchpad for Uniswap v4

`hookrig` is a security-first, modular smart contract suite for **Uniswap v4** built with **Foundry** and **OpenZeppelin's audited `uniswap-hooks` & `contracts` v5** libraries.

Instead of building monolithic hooks from scratch, users and protocols compose custom pool logic from **17 standardized building blocks** (plus **5 optional expansion blocks**) across **5 functional groups**, deploy one of **12 curated presets**, or launch new tokens through one of **3 native bonding/launch curves** directly wired to their chosen hook stack.

---

## Documentation Index (`docs/`)

All architectural specifications, hook execution flows, security invariants, and token launchpad mechanics are documented in [`docs/`](file:///Users/eabz/Documents/GitHub/hookrig/docs):

1. [**01. Explanation, Building Blocks, Presets & Token Launchpad**](file:///Users/eabz/Documents/GitHub/hookrig/docs/01-explanation-and-catalog.md)
   - Complete breakdown of the **17 Core Building Blocks** (`Fees`, `Protection & Access`, `Token Rules`, `Rewards & Income`, `Trading`), callback footprints, and trust levels (`Low` vs. `Medium`), plus **5 Recommended Expansion Blocks** (`JIT Liquidity Guard`, `Circuit Breaker`, `Referral Split`, `Vesting Sell Cap`, `Auto Buyback`).
   - Full specification of the **12 Curated Presets** (*Fair launch*, *King of the Pool launch*, *Weekly King with buy rewards*, *Creator economy token*, *Charity token*, *Treasury-backed token*, *Stock-quoted token*, *Deep liquidity*, *Trader-first pools*, *Stable-pair project fee*, *Private pool*, *Pro trading pool*).
   - Overview of the **3 Token Launchpad Curves** (`VirtualXYKLaunch`, `SteppedTrancheLaunch`, `NativeTickLaunch`).
2. [**02. System Architecture**](file:///Users/eabz/Documents/GitHub/hookrig/docs/02-architecture.md)
   - Dual deployment modes: Singleton `HookRigOrchestrator` (bitmap-configured) vs. Standalone Compiled Preset Hooks.
   - Foundry + `Uniswap/v4-core` + `OpenZeppelin/uniswap-hooks` stack.
   - Buy/Sell direction normalization (`PoolTokenDir`), per-`PoolId` storage isolation, ERC-6909 claim custody, and `EIP-1153` transient context.
3. [**03. Hooks Execution Flow & Delta Aggregation**](file:///Users/eabz/Documents/GitHub/hookrig/docs/03-hooks-flow.md)
   - End-to-end sequence diagrams across `beforeInitialize`, `afterInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, `beforeSwap`, and `afterSwap`.
   - Deterministic `FeeAggregator` resolution (`MAX` rule across `Dynamic fee`, `Managed fee`, `Market-hours fee`, and `Anti-snipe`).
   - Single-pass `AfterSwapDeltaAggregator` waterfall for safely combining `Arb recapture`, `Buy and sell tax`, `Auto burn`, `Fee sharing`, `LP rewards`, and `King of the Pool`.
4. [**04. Security Mechanics, Measures, Caveats & Best Practices**](file:///Users/eabz/Documents/GitHub/hookrig/docs/04-security-mechanics-and-caveats.md)
   - Detailed post-mortems & defenses for real-world Uniswap v4 hook exploits (Cork Protocol ~$12M cross-market drain, Bunni V2 ~$8.4M rounding exploit) and the 7 core v4 threat vectors.
   - Six advanced security mechanics: JIT donation dilution defense, recursive hook self-swap deadlock prevention, Exact-In vs. Exact-Out return-delta branching, zero-liquidity `donate()` protection, `King of the Pool` dust-reset protection, and aggregate return-delta budget caps.
   - Immutable on-chain anti-rug guardrails for all `Medium`-trust blocks and our 5-stage Foundry/Halmos verification standard.
5. [**05. Token Launchpad Mechanics & Audited Stack**](file:///Users/eabz/Documents/GitHub/hookrig/docs/05-token-launch-mechanics.md)
   - Audited OpenZeppelin + Uniswap v4 dependency stack for the Launchpad (`ERC20Burnable`, `ERC20Permit`, `Clones`, `Create2`, `Math.mulDiv`, `CurrencySettler`, `ReentrancyGuardTransient`, `VestingWallet`).
   - Deterministic `Create2` token sorting (`currency0 = Quote`, `currency1 = ProjectToken`).
   - Exact mathematical formulas and graduation state machines for `VirtualXYKLaunch`, `SteppedTrancheLaunch`, and `NativeTickLaunch`.
   - The 4 Graduation Security Invariants (spot-price continuity, pre-initialization front-running lock, post-graduation `Anti-snipe` clock reset, and irreversible LP lock).

---

## Quick Overview: The 17 Core Blocks, 5 Expansion Blocks & 12 Presets

### The 17 Core Building Blocks (+ 5 Recommended Expansions)
| Group | Core Blocks (1–17) | Recommended Expansion Blocks (18–22) |
| :--- | :--- | :--- |
| **1. Fees** | `Dynamic fee`, `Managed fee`, `Market-hours fee` | — |
| **2. Protection & Access** | `Anti-snipe`, `MEV protection`, `Arb recapture`, `Access control` | `JIT liquidity guard`, `Circuit breaker / Price band` |
| **3. Token Rules** | `Wallet cap`, `Buy and sell tax`, `Auto burn` | `Vesting / Daily sell cap` |
| **4. Rewards & Income** | `Fee sharing`, `LP rewards`, `Swap rewards`, `King of the Pool` | `Referral & affiliate split`, `Buyback & floor defense` |
| **5. Trading** | `Limit orders`, `TWAMM`, `Oracle` | — |

### The 12 Presets
- **Fair launch**: `Dynamic fee` + `Anti-snipe` + `Wallet cap` + `Auto burn` + `LP rewards`
- **King of the Pool launch**: `Dynamic fee` + `Anti-snipe` + `Arb recapture` + `LP rewards` + `King of the Pool`
- **Weekly King with buy rewards**: `King of the Pool launch` + `Swap rewards` (168-hour round)
- **Creator economy token**: `Dynamic fee` + `Anti-snipe` + `Buy and sell tax` + `Fee sharing` + `LP rewards`
- **Charity token**: `Dynamic fee` + `Anti-snipe` + `Fee sharing` + `LP rewards` + `Auto burn`
- **Treasury-backed token**: `Dynamic fee` + `Anti-snipe` + `Arb recapture` + `Buy and sell tax (sell only)` + `LP rewards` + `Auto burn`
- **Stock-quoted token**: `Market-hours fee` + `Anti-snipe` + `Arb recapture` + `LP rewards` + `Auto burn`
- **Deep liquidity (existing token)**: `Dynamic fee` + `Arb recapture` + `LP rewards`
- **Trader-first pools**: `Dynamic fee` + `Anti-snipe` + `Arb recapture`
- **Stable-pair project fee**: `Arb recapture` + `Buy and sell tax (1.875% each way)` + `LP rewards`
- **Private pool (ours)**: `Access control` + `MEV protection` + `Oracle`
- **Pro trading pool (ours)**: `Dynamic fee` + `Limit orders` + `TWAMM` + `Oracle`

### The 3 Token Launchpad Curves
1. **`VirtualXYKLaunch`**: Classic Pump.fun-style virtual constant-product curve that atomically graduates into a Uniswap v4 pool with the chosen `hookrig` stack.
2. **`SteppedTrancheLaunch`**: Anti-bundle stepped/exponential accumulation curve with active `Wallet cap` and `Anti-snipe` during the curve phase before graduating to v4.
3. **`NativeTickLaunch`**: Zero-migration launch initialized directly inside Uniswap v4 at block 0 using single-sided concentrated tick ranges with the full `hookrig` stack active from trade #1.
