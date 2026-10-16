# 07. Roadmap & Engineering TODOs

This document tracks remaining deployment tasks and records the completed engineering & security audit remediation checklist (with completed work items checked and removed from the active queue).

---

## 1. Active Remaining TODO Queue

| Check | ID | Priority | Target | Summary | Status |
| :---: | :--- | :---: | :--- | :--- | :---: |
| `[ ]` | **TODO-09** | **P2 (Low)** | [`script/HoodiIntegration.s.sol`](../script/HoodiIntegration.s.sol) | **Live Broadcast & Contract Verification on Ethereum Hoodi (`chainId = 560048`)**: Broadcast the deployment script with `PRIVATE_KEY=0x... forge script script/HoodiIntegration.s.sol --rpc-url https://ethereum-hoodi-rpc.publicnode.com --broadcast -vv` and record canonical Hoodi testnet addresses. | **Fork Verified (`Ready for Live Broadcast`)** |

---

## 2. Checked & Completed Tasks (Removed from Active Queue)

All `src/` and `script/` engineering tasks, security audit remediations, and stateful fuzzing / coverage campaigns below have been implemented, verified against all **92 Foundry tests** (`unit`, `presets`, `launchpad`, `invariant`, `fizz/FoundryTester`, and `HoodiForkIntegration` across all **2,843** valid Tier 3 combinations) and **91 Medusa tests (`56 properties`)**, checked off, and removed from the active queue:

- [x] **TODO-01** — Enforce the Tier 3 Mutual-Exclusion Matrix (`2,843` Valid Combinations — `IT-03`) in [`HookPermissionMasks.sol`](../src/libraries/HookPermissionMasks.sol) and [`HookRigOrchestrator.sol`](../src/HookRigOrchestrator.sol).
- [x] **TODO-02** — Union Preset Bitmaps with Additional Blocks (`IT-01`) in [`HookRigOrchestrator.sol`](../src/HookRigOrchestrator.sol).
- [x] **TODO-03** — Curve-to-Pool `WalletCap` Alignment (`IT-02`) in [`LaunchpadFactory.sol`](../src/launchpad/LaunchpadFactory.sol).
- [x] **TODO-04** — Full-Balance Convenience Withdrawal (`amount == 0` — `IT-04`) in [`HookRigBase.sol`](../src/base/HookRigBase.sol).
- [x] **TODO-05** — Directional Buy vs. Sell Return-Delta Budget Validation (`IT-05`) in [`AfterSwapDeltaAggregator.sol`](../src/base/AfterSwapDeltaAggregator.sol).
- [x] **TODO-06** — Post-Cut Net Volume Attribution in `SwapRewards` (`IT-06`) in [`HookRigOrchestrator.sol`](../src/HookRigOrchestrator.sol).
- [x] **TODO-07** — Publicly Exposed Static `5 bps` (`0.05%`) Protocol Royalty (`PROTOCOL_ROYALTY_BPS = 5`, `PROTOCOL_ROYALTY_RECIPIENT = 0x576e9C47665887298EB39eeaa070Dfc1fF6B960A`) in [`HookRigBase.sol`](../src/base/HookRigBase.sol) and [`AfterSwapDeltaAggregator.sol`](../src/base/AfterSwapDeltaAggregator.sol).
- [x] **TODO-08** — Complete Configuration Parameter Bounds (`Min` / `Max`) & Overflow Hardening (`CFG-01`–`CFG-08`) across `src/blocks/**/*.sol`.
- [x] **TODO-10** — Remediate All 36 `solidity-auditor` 2-Pass Loop Security Findings (`SA-01`–`SA-36`).
- [x] **TODO-11** — Remediate All 66 `solidity-auditor` 3-Pass Loop Findings + 2 Leads (`SA2-01`–`SA2-68` — including `JIT exit penalty configuration is stored but never read on removal` and `Shared native ETH limit order escrow lacks per-pool balance isolation`).
- [x] **TODO-12** — Fizz Sync & Medusa Stateful Fuzzing + Coverage Campaign (`91/91` Medusa tests passed, `GL-24` exact-output AutoBurn currency guard fixed in [`AfterSwapDeltaAggregator.sol`](../src/base/AfterSwapDeltaAggregator.sol), `84%–100%` line coverage across all 35 `src/` contracts).
- [x] **TODO-13** — Remediate the 2026-10-15 `solidity-auditor` 3-Pass Loop Findings ([`full-report.md`](../.solidity-auditor/runs/20261015-100328/full-report.md)): 32 of 35 findings fixed with regression tests in [`AuditFixes.t.sol`](../test/unit/AuditFixes.t.sol). Full cross-iteration status of all 236 agentic audit items: [`audit/agentic/2026-10-15.pdf`](../audit/agentic/2026-10-15.pdf).
- [x] **TODO-14** — Real TWAMM Virtual Order Execution, Pro-Rata Swap Settlement, `claimTWAMMOrder` & Minimum Order Floor (`MIN_TWAMM_ORDER_AMOUNT = 1000` — `S3-F05`, `S3-F23`, `S3-F65`) in [`TWAMMBlock.sol`](../src/blocks/trading/TWAMMBlock.sol) and [`HookRigOrchestrator.sol`](../src/HookRigOrchestrator.sol).
- [x] **TODO-15** — Owner-Trust Hardening of `setLaunchpadFactory` (Set-Once Lock) & ERC-6909 Backing Validation in `seedKingPotFromLaunchCurve` (`S4-F06`, `S4-F07`, `S4-L05`) in [`HookRigBase.sol`](../src/base/HookRigBase.sol) and [`KingOfThePoolBlock.sol`](../src/blocks/rewards/KingOfThePoolBlock.sol).
- [x] **TODO-16** — JIT Guard Per-Owner Liquidity Tracking (`lpTrackedLiquidity`), Cross-Account Bypass Prevention, 5% Anti-Griefing Threshold & `jitExitPenaltyBps` Hold Floor (`S4-F08`, `S2-F41`, `S3-F58`) in [`JITGuardBlock.sol`](../src/blocks/protection/JITGuardBlock.sol).
- [x] **TODO-17** — Fee-on-Transfer Quote Token Rejection (`UnsupportedFeeOnTransferQuoteToken`) via Balance-Delta Verification (`S4-F09`, `S3-F69`) in [`VirtualXYKLaunch.sol`](../src/launchpad/curves/VirtualXYKLaunch.sol) and [`SteppedTrancheLaunch.sol`](../src/launchpad/curves/SteppedTrancheLaunch.sol).
- [x] **TODO-18** — Deploy Script `PRIVATE_KEY` Enforcement on Non-Local Chains (`chainId != 31337` — `S4-F12`, `S4-L03`) in [`script/HoodiIntegration.s.sol`](../script/HoodiIntegration.s.sol).
- [x] **TODO-19** — Integrator Notes, Preset Permission Flag Alignment & Security Caveat Documentation across [`docs/03-hooks-flow.md`](./03-hooks-flow.md), [`docs/04-security-mechanics-and-caveats.md`](./04-security-mechanics-and-caveats.md), [`docs/05-token-launch-mechanics.md`](./05-token-launch-mechanics.md), and [`docs/06-attack-vectors-and-fixes.md`](./06-attack-vectors-and-fixes.md).
- [x] **TODO-20** — Remediate All Remaining Audit Leads (`AutoBurn` balance-delta `takeAndBurn`, `HoodiSwapRouter` native `msg.value` isolation & refund, exact-output sell net `SwapRewards` volume, `LimitOrders` bucket `epoch` tracking to prevent 1-wei claim denial, `TransientContext` block-number validation — `S4-L02`, `S4-L04`, `S4-L06`, `S4-L13`, `S4-L15`, `S4-L16`, `S4-L19`).
- [x] **TODO-21** — Document Accepted Protocol Design Limits (Per-wallet vs. token-level transfer hooks and permanently locked graduation LP positions) in [`docs/04-security-mechanics-and-caveats.md`](./04-security-mechanics-and-caveats.md).
- [x] **TODO-22** — Fix Inverted `AutoBuyback` Floor-Tick Comparison (`isToken0ProjectToken ? postSwapTick <= triggerFloorTick : postSwapTick >= triggerFloorTick` — `S4-F01`, `S1-F05`, `S2-F04`, `S3-F14`) in [`AutoBuybackBlock.sol`](../src/blocks/rewards/AutoBuybackBlock.sol) with unit tests for both token orderings.
- [x] **TODO-23** — Standard-Pool Initialization Authorization (`AccessControlLogic.verifyInitializer` restricting `beforeInitialize`/`afterInitialize` on registered pools to `poolAdmin` or `owner` — `S4-F02`, `S2-F63`) in [`AccessControlBlock.sol`](../src/blocks/protection/AccessControlBlock.sol) and [`HookRigOrchestrator.sol`](../src/HookRigOrchestrator.sol).
- [x] **TODO-24** — Untrusted-Router Identity Hardening across `AccessControl` (reject trusted-router self-attribution), `WalletCap` (reject untrusted-router buys via `UntrustedRouterNotAllowedForWalletCap`), `KingOfThePool` (untrusted routers contribute to pot without crowning), `ReferralSplit` (reject router referrers and untrusted-router self-referrals), and `VestingSellCap` (`S4-F03`, `S4-F04`, `S4-F05`, `S4-L01`, `S3-F33`).
- [x] **TODO-25** — `DynamicFee` Same-Block Zero-Delta Wash-Swap Decay Prevention & Pre-Swap Observation Documentation (`S4-F11`, `S1-F08`) in [`DynamicFeeBlock.sol`](../src/blocks/fees/DynamicFeeBlock.sol).
- [x] **TODO-26** — Launch Curve Economics Hardening (`LaunchpadVestingWallet` gating creator vesting releases until curve graduation, zero-output buy rejection, `MAX_ANTI_SNIPE_BLOCKS = 50_400`, stalled-launch sniper surcharge refunds, clamped-LP proportional quote scaling, and automatic `WalletCap` alignment when `0` — `S1-F18`, `S2-F19`, `S4-L11`, `S4-L17`, `S3-F64`, `S2-F09`) across [`LaunchpadFactory.sol`](../src/launchpad/LaunchpadFactory.sol), [`VirtualXYKLaunch.sol`](../src/launchpad/curves/VirtualXYKLaunch.sol), and [`SteppedTrancheLaunch.sol`](../src/launchpad/curves/SteppedTrancheLaunch.sol).
- [x] **TODO-27** — `NativeTickLaunch` Band Validation (`tickLower`/`tickUpper` spacing, single-sided project-token placement, positive liquidity delta, total band token cap) & Unseeded Residual Burn to `0xdEaD` (`S4-F10`, `S2-F46`, `S3-F63`) in [`LaunchpadFactory.sol`](../src/launchpad/LaunchpadFactory.sol) and [`NativeTickLaunch.sol`](../src/launchpad/curves/NativeTickLaunch.sol).
- [x] **TODO-28** — Protection-Block Parameter & Threshold Documentation (`MEVProtection`, `CircuitBreaker`, `ArbRecapture`, and `AntiSnipeBlock.seedAntiSnipeBlock` caller validation — `S4-L07`, `S4-L08`, `S2-F40`).
- [x] **TODO-29** — Admin & Configuration Ergonomics (`ManagedFee` pre-initialization fee staging, `BuySellTax` zero-address recipient preservation on update, `LaunchpadFactory` `msg.sender` fallback for zero `creator`, and `VestingSellCap` `5000 bps` ceiling — `S2-F45`, `S2-F55`, `S4-L10`, `S4-L20`).

