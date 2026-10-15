# 07. Roadmap & Engineering TODOs

This document tracks remaining deployment tasks and records the completed engineering & security audit remediation checklist (with completed work items checked and removed from the active queue).

---

## 1. Active Remaining TODO Queue

| Check | ID | Priority | Target | Summary | Status |
| :---: | :--- | :---: | :--- | :--- | :---: |
| `[ ]` | **TODO-09** | **P2 (Low)** | [`script/HoodiIntegration.s.sol`](../script/HoodiIntegration.s.sol) | **Live Broadcast & Contract Verification on Ethereum Hoodi (`chainId = 560048`)**: Broadcast the deployment script with `PRIVATE_KEY=0x... forge script script/HoodiIntegration.s.sol --rpc-url https://ethereum-hoodi-rpc.publicnode.com --broadcast -vv` and record canonical Hoodi testnet addresses. | **Fork Verified (`Ready for Live Broadcast`)** |

---

## 2. Checked & Completed Tasks (Removed from Active Queue)

All `src/` and `script/` engineering tasks and security audit remediations below have been implemented, verified against all **67 Foundry tests** (`unit`, `presets`, `launchpad`, `invariant`, `fizz/FoundryTester`, and `HoodiForkIntegration` across all **2,843** valid Tier 3 combinations), checked off, and removed from the active queue:

- [x] **TODO-01** — Enforce the Tier 3 Mutual-Exclusion Matrix (`2,843` Valid Combinations — `IT-03`) in [`HookPermissionMasks.sol`](../src/libraries/HookPermissionMasks.sol) and [`HookRigOrchestrator.sol`](../src/HookRigOrchestrator.sol).
- [x] **TODO-02** — Union Preset Bitmaps with Additional Blocks (`IT-01`) in [`HookRigOrchestrator.sol`](../src/HookRigOrchestrator.sol).
- [x] **TODO-03** — Curve-to-Pool `WalletCap` Alignment (`IT-02`) in [`LaunchpadFactory.sol`](../src/launchpad/LaunchpadFactory.sol).
- [x] **TODO-04** — Full-Balance Convenience Withdrawal (`amount == 0` — `IT-04`) in [`HookRigBase.sol`](../src/base/HookRigBase.sol).
- [x] **TODO-05** — Directional Buy vs. Sell Return-Delta Budget Validation (`IT-05`) in [`AfterSwapDeltaAggregator.sol`](../src/base/AfterSwapDeltaAggregator.sol).
- [x] **TODO-06** — Post-Cut Net Volume Attribution in `SwapRewards` (`IT-06`) in [`HookRigOrchestrator.sol`](../src/HookRigOrchestrator.sol).
- [x] **TODO-07** — Publicly Exposed Static `5 bps` (`0.05%`) Protocol Royalty (`PROTOCOL_ROYALTY_BPS = 5`) in [`HookRigBase.sol`](../src/base/HookRigBase.sol) and [`AfterSwapDeltaAggregator.sol`](../src/base/AfterSwapDeltaAggregator.sol).
- [x] **TODO-08** — Complete Configuration Parameter Bounds (`Min` / `Max`) & Overflow Hardening (`CFG-01`–`CFG-08`) across `src/blocks/**/*.sol`.
- [x] **TODO-10** — Remediate All 36 `solidity-auditor` 2-Pass Loop Security Findings (`SA-01`–`SA-36`).
- [x] **TODO-11** — Remediate All 66 `solidity-auditor` 3-Pass Loop Findings + 2 Leads (`SA2-01`–`SA2-68` — including `JIT exit penalty configuration is stored but never read on removal` and `Shared native ETH limit order escrow lacks per-pool balance isolation`).
