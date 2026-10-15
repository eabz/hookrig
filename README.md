<div align="center">

# HookRig

**Composable Hook Building Blocks, Presets & Token Launchpad for Uniswap v4**

[![CI](https://github.com/eabz/hookrig/actions/workflows/test.yml/badge.svg)](./.github/workflows/test.yml)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.30-363636?logo=solidity)](./foundry.toml)
[![EVM](https://img.shields.io/badge/EVM-Cancun%20(EIP--1153)-blue)](./foundry.toml)
[![Uniswap v4](https://img.shields.io/badge/Uniswap-v4-FF007A?logo=uniswap)](https://github.com/Uniswap/v4-core)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-v5%20%2B%20uniswap--hooks-4E5EE4?logo=openzeppelin)](https://github.com/OpenZeppelin/uniswap-hooks)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C)](https://book.getfoundry.sh/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)

</div>

---

## Overview

**HookRig** is a security-first, modular smart contract framework for **Uniswap v4** built on top of **OpenZeppelin's `uniswap-hooks` and `contracts` v5**.

Compose custom pool behavior from **17 standardized building blocks**, deploy one of **12 production presets**, or launch new tokens through **3 native bonding/launch curves** that graduate directly into a HookRig-powered Uniswap v4 pool.

---

## Quickstart

```bash
# 1. Clone with submodules
git clone --recurse-submodules https://github.com/eabz/hookrig.git
cd hookrig

# 2. Build & check EIP-170 contract sizes
forge build --sizes

# 3. Check formatting & run tests
forge fmt --check
forge test -vvv
```

---

## The 17 Building Blocks

All blocks are defined in [`src/blocks/`](./src/blocks) and can be combined via [`HookRigOrchestrator`](./src/HookRigOrchestrator.sol).

| Group | Block | Callbacks | Trust |
| :--- | :--- | :--- | :---: |
| **Fees** | [`DynamicFeeBlock`](./src/blocks/fees/DynamicFeeBlock.sol) | `afterInitialize`, `beforeSwap` | Low |
| | [`ManagedFeeBlock`](./src/blocks/fees/ManagedFeeBlock.sol) | `afterInitialize` | Medium |
| | [`MarketHoursFeeBlock`](./src/blocks/fees/MarketHoursFeeBlock.sol) | `afterInitialize`, `beforeSwap` | Low |
| **Protection & Access** | [`AntiSnipeBlock`](./src/blocks/protection/AntiSnipeBlock.sol) | `afterInitialize`, `beforeSwap` | Low |
| | [`MEVProtectionBlock`](./src/blocks/protection/MEVProtectionBlock.sol) *(+ JIT Guard)* | `beforeSwap`, `afterSwap`, `beforeAdd/RemoveLiquidity` | Low |
| | [`ArbRecaptureBlock`](./src/blocks/protection/ArbRecaptureBlock.sol) | `beforeSwap`, `afterSwap`, `afterSwapReturnDelta` | Medium |
| | [`AccessControlBlock`](./src/blocks/protection/AccessControlBlock.sol) | `beforeAddLiquidity` and/or `beforeSwap` | Medium |
| **Token Rules** | [`WalletCapBlock`](./src/blocks/token-rules/WalletCapBlock.sol) | `beforeSwap`, `afterSwap` | Low |
| | [`BuySellTaxBlock`](./src/blocks/token-rules/BuySellTaxBlock.sol) | `afterSwap`, `afterSwapReturnDelta` | Medium |
| | [`AutoBurnBlock`](./src/blocks/token-rules/AutoBurnBlock.sol) | `afterSwap`, `afterSwapReturnDelta` | Medium |
| **Rewards & Income** | [`FeeSharingBlock`](./src/blocks/rewards/FeeSharingBlock.sol) | `afterSwap`, `afterSwapReturnDelta` | Medium |
| | [`LPRewardsBlock`](./src/blocks/rewards/LPRewardsBlock.sol) | `afterSwap`, `afterSwapReturnDelta` | Medium |
| | [`SwapRewardsBlock`](./src/blocks/rewards/SwapRewardsBlock.sol) | `afterSwap` | Low |
| | [`KingOfThePoolBlock`](./src/blocks/rewards/KingOfThePoolBlock.sol) | `afterSwap`, `afterSwapReturnDelta` | Medium |
| **Trading** | [`LimitOrdersBlock`](./src/blocks/trading/LimitOrdersBlock.sol) | `afterInitialize`, `afterSwap` | Low |
| | [`TWAMMBlock`](./src/blocks/trading/TWAMMBlock.sol) | `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap` | Low |
| | [`OracleBlock`](./src/blocks/trading/OracleBlock.sol) | `afterInitialize`, `beforeAdd/RemoveLiquidity`, `beforeSwap` | Low |

### The 5 Expansion Blocks

| # | Block | Group | Callbacks | Trust |
| :-: | :--- | :--- | :--- | :---: |
| 18 | [`JITGuardBlock`](./src/blocks/protection/JITGuardBlock.sol) | Protection & Access | `beforeAddLiquidity`, `beforeRemoveLiquidity` | Low |
| 19 | [`CircuitBreakerBlock`](./src/blocks/protection/CircuitBreakerBlock.sol) | Protection & Access | `beforeSwap`, `afterSwap` | Low |
| 20 | [`ReferralSplitBlock`](./src/blocks/rewards/ReferralSplitBlock.sol) | Rewards & Income | `afterSwap`, `afterSwapReturnDelta` | Low |
| 21 | [`VestingSellCapBlock`](./src/blocks/token-rules/VestingSellCapBlock.sol) | Token Rules | `beforeSwap`, `afterSwap` | Low |
| 22 | [`AutoBuybackBlock`](./src/blocks/rewards/AutoBuybackBlock.sol) | Rewards & Income | `afterSwap`, `afterSwapReturnDelta` | Medium |

---

## The 12 Presets

Pre-configured stacks in [`src/presets/HookRigPresets.sol`](./src/presets/HookRigPresets.sol):

| # | Preset | Composed Blocks |
| :-: | :--- | :--- |
| 1 | **Fair launch** | `Dynamic fee` + `Anti-snipe` + `Wallet cap` + `Auto burn` + `LP rewards` |
| 2 | **King of the Pool launch** | `Dynamic fee` + `Anti-snipe` + `Arb recapture` + `LP rewards` + `King of the Pool` |
| 3 | **Weekly King with buy rewards** | `King of the Pool launch` + `Swap rewards` *(168-hour round)* |
| 4 | **Creator economy token** | `Dynamic fee` + `Anti-snipe` + `Buy and sell tax` + `Fee sharing` + `LP rewards` |
| 5 | **Charity token** | `Dynamic fee` + `Anti-snipe` + `Fee sharing` + `LP rewards` + `Auto burn` |
| 6 | **Treasury-backed token** | `Dynamic fee` + `Anti-snipe` + `Arb recapture` + `Sell tax` + `LP rewards` + `Auto burn` |
| 7 | **Stock-quoted token** | `Market-hours fee` + `Anti-snipe` + `Arb recapture` + `LP rewards` + `Auto burn` |
| 8 | **Deep liquidity** | `Dynamic fee` + `Arb recapture` + `LP rewards` |
| 9 | **Trader-first pools** | `Dynamic fee` + `Anti-snipe` + `Arb recapture` |
| 10 | **Stable-pair project fee** | `Arb recapture` + `Buy and sell tax (1.875% each way)` + `LP rewards` |
| 11 | **Private pool** | `Access control` + `MEV protection` + `Oracle` |
| 12 | **Pro trading pool** | `Dynamic fee` + `Limit orders` + `TWAMM` + `Oracle` |

---

## Token Launchpad Suite

Launch tokens via [`LaunchpadFactory`](./src/launchpad/LaunchpadFactory.sol) with any preset or custom HookRig stack:

| Curve Model | Contract | Description |
| :--- | :--- | :--- |
| **Virtual XYK** | [`VirtualXYKLaunch`](./src/launchpad/curves/VirtualXYKLaunch.sol) | Pump.fun-style virtual constant-product curve $(X_0 + x_{\text{real}}) \cdot Y_{\text{virtual}} = k$ with atomic graduation into Uniswap v4. |
| **Stepped Tranche** | [`SteppedTrancheLaunch`](./src/launchpad/curves/SteppedTrancheLaunch.sol) | Anti-bundle stepped curve enforcing per-block and per-wallet caps during bonding; routes sniper surcharges to LP depth and Round #1 `KingOfThePool`. |
| **Native Tick** | [`NativeTickLaunch`](./src/launchpad/curves/NativeTickLaunch.sol) | Zero-migration launch initialized directly inside Uniswap v4 at Block 0 using single-sided concentrated tick bands. |

---

## Documentation (`docs/`)

| Document | Focus |
| :--- | :--- |
| [**01. Explanation & Catalog**](./docs/01-explanation-and-catalog.md) | Block specs, trust taxonomy (`Low` vs `Medium`), 12 presets, and launchpad overview. |
| [**02. Architecture**](./docs/02-architecture.md) | Orchestrator vs. Preset deployment modes, `PoolTokenDir` normalization, and storage isolation. |
| [**03. Hooks Execution Flow**](./docs/03-hooks-flow.md) | Callback sequence diagrams, `FeeAggregator`, and `AfterSwapDeltaAggregator` waterfall. |
| [**04. Security Mechanics & Caveats**](./docs/04-security-mechanics-and-caveats.md) | Real-world v4 exploit defenses (Cork Protocol, Bunni V2), rounding laws, and hard caps. |
| [**05. Token Launchpad Mechanics**](./docs/05-token-launch-mechanics.md) | Bonding math, `Create2` address sorting, and graduation security invariants. |

---

## Project Layout

```text
src/
├── HookRigOrchestrator.sol     # Master composable Uniswap v4 hook orchestrator
├── base/                       # HookRigBase, FeeAggregator, AfterSwapDeltaAggregator
├── blocks/                     # 17 core blocks (+ expansion blocks) across 5 groups
├── presets/                    # 12 concrete preset hook contracts
├── launchpad/                  # HookRigToken, LaunchpadFactory, and 3 curve contracts
├── interfaces/                 # Canonical interfaces & config structs
└── libraries/                  # Bitmasks, PoolTokenDir, EIP-1153 TransientContext
```
