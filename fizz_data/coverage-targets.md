Fuzz profile: via_ir disabled — coverage numbers are accurate
Build command: FOUNDRY_PROFILE=fuzz forge build ([profile.fuzz] sets bytecode_hash=ipfs so Medusa can attribute coverage to harness-deployed contracts)

## Per-contract targets

| Contract | Role | Target |
|---|---|---|
| HookRigOrchestrator, HookRigBase, AfterSwapDeltaAggregator, FeeAggregator | Core | 80% |
| VirtualXYKLaunch, SteppedTrancheLaunch, NativeTickLaunch, LaunchpadFactory | Core (launchpad) | 80% |
| All block libraries (fees/protection/token-rules/rewards/trading) | Core logic | 80% |
| AccessControlBlock, ManagedFeeBlock | Access control | 60% |
| HookRigToken, TransientContext, PoolTokenDir, HookPermissionMasks | Peripheral / library | 50% |
| HookRigPresets | Out of harness scope | skip |

## Skips

- `HookRigPresets.sol` — 12 compiled preset hooks need their own mined addresses and are not deployed; the orchestrator's `presetId` path covers their bitmaps.
- `BuySellTaxBlock._updateBuySellTax` / `BuySellTaxLogic.update` — no external entry point (dead code, see x-ray I-30); unreachable by design.

## Cycle 1 (2026-10-15, 90 s, plateau at 9178 branches, 0 failures)

| Contract | Role | Target | Hit | Status |
|---|---|---|---|---|
| HookRigOrchestrator | Core | 80% | 93% | ✅ |
| HookRigBase | Core | 80% | 82% | ✅ |
| AfterSwapDeltaAggregator | Core | 80% | 100% | ✅ |
| FeeAggregator | Core | 80% | 100% | ✅ |
| VirtualXYKLaunch | Core | 80% | 86% | ✅ |
| SteppedTrancheLaunch | Core | 80% | 88% | ✅ |
| NativeTickLaunch | Core | 80% | 81% | ✅ |
| LaunchpadFactory | Core | 80% | 80% | ✅ |
| KingOfThePool / LimitOrders / TWAMM / AutoBuyback / ArbRecapture / AntiSnipe / DynamicFee / CircuitBreaker / MEV / JIT / Vesting / WalletCap / AutoBurn / FeeSharing / Referral / SwapRewards / Oracle / MarketHours / LPRewards | Core logic | 80% | 80–100% | ✅ |
| AccessControlBlock / ManagedFeeBlock | Access | 60% | 96% / 94% | ✅ |
| BuySellTaxBlock | Core logic | 80% (adjusted: update path dead) | 40% | ✅ (init + apply paths covered; remainder unreachable) |
| HookPermissionMasks | Library | 50% | 38% | ❌ (preset bitmaps not fuzzed) |
| HookRigToken / TransientContext / PoolTokenDir | Peripheral | 50% | 83% / 85% / 100% | ✅ |
| HookRigPresets | Out of scope | — | 0% | skip |

## Cycle 2 (2026-10-15, 117 s, plateau at 9242 branches, 0 failures) — added presetId fuzzing

| Contract | Role | Target | Hit | Status |
|---|---|---|---|---|
| HookRigOrchestrator | Core | 80% | 94% | ✅ |
| HookRigBase | Core | 80% | 82% | ✅ |
| AfterSwapDeltaAggregator / FeeAggregator | Core | 80% | 99% / 100% | ✅ |
| VirtualXYK / SteppedTranche / NativeTick / LaunchpadFactory | Core | 80% | 86% / 88% / 81% / 80% | ✅ |
| Block libraries | Core logic | 80% | 80–100% | ✅ |
| AccessControl / ManagedFee | Access | 60% | 92% / 94% | ✅ |
| BuySellTaxBlock | Core logic (adjusted) | — | 40% | ✅ (update path unreachable) |
| HookPermissionMasks | Library | 50% | 79% | ✅ (was 38%) |
| HookRigToken / TransientContext / PoolTokenDir | Peripheral | 50% | 83% / 85% / 100% | ✅ |
| HookRigPresets | Out of scope | — | 0% | skip |
