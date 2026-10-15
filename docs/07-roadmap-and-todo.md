# 07. Roadmap & Post-Review Engineering TODOs

This document tracks all planned `src/` contract enhancements, mutual-exclusion rules, and deployment tasks queued for implementation immediately following the ongoing security peer review and fuzzing campaign.

---

## 1. Completed `src/` Contract Changes (Post-Peer-Review Queue)

| ID | Priority | Target Contract(s) | Summary | Status |
| :--- | :---: | :--- | :--- | :---: |
| **TODO-01** | **P0 (High)** | [`HookPermissionMasks.sol`](../src/libraries/HookPermissionMasks.sol), [`HookRigOrchestrator.sol`](../src/HookRigOrchestrator.sol) | **Enforce the Tier 3 Mutual-Exclusion Matrix (`2,843` Valid Combinations — `IT-03`)** on-chain during pool registration (`registerPoolStack` / `launchToken`) to prevent contradictory block interactions (`M1`–`M7`). | **Completed (`src/` & Tests Passing)** |
| **TODO-02** | **P1 (Med)** | [`HookRigOrchestrator.sol`](../src/HookRigOrchestrator.sol#L108-L110) | **Union Preset Bitmaps with Additional Blocks (`IT-01`)**: Compute `HookPermissionMasks.getPresetBitmap(config.presetId) \| config.enabledBlocksBitmap` before validating against `isValidTier3Bitmap`. | **Completed (`src/` & Tests Passing)** |
| **TODO-03** | **P1 (Med)** | [`LaunchpadFactory.sol`](../src/launchpad/LaunchpadFactory.sol) | **Curve-to-Pool `WalletCap` Alignment (`IT-02`)**: Validate `stackConfig.walletCap.maxWalletBps >= curveCfg.maxWalletBpsDuringCurve` when `BIT_WALLET_CAP` is enabled on a bonding curve launch. | **Completed (`src/` & Tests Passing)** |
| **TODO-04** | **P2 (Low)** | [`HookRigBase.sol`](../src/base/HookRigBase.sol#L73-L86) | **Full-Balance Convenience Withdrawal (`amount == 0` — `IT-04`)**: Allow `withdrawClaim(poolId, currency, 0, recipient)` to default to the caller's full available `poolClaims[poolId][currency][msg.sender]` balance. | **Completed (`src/` & Tests Passing)** |
| **TODO-05** | **P2 (Low)** | [`AfterSwapDeltaAggregator.sol`](../src/base/AfterSwapDeltaAggregator.sol#L45-L74) | **Directional Buy vs. Sell Return-Delta Budget Validation (`IT-05`)**: Separate `maxBuyBps` (which includes buy-only blocks `AutoBurn`, `LPRewards`, `KingOfThePool`) and `maxSellBps` in `_validateAggregateReturnDeltaBudget` so high `sellTaxBps` does not falsely collide with buy-only block budgets. | **Completed (`src/` & Tests Passing)** |
| **TODO-06** | **P2 (Low)** | [`HookRigOrchestrator.sol`](../src/HookRigOrchestrator.sol#L403-L405) | **Post-Cut Net Volume Attribution in `SwapRewards` (`IT-06`)**: Accrue `SwapRewards` on net post-cut volume (`ctx.grossUnspecifiedAmount - totalCutAmount`) rather than pre-cut gross volume so taxed/donated slices do not inflate reward points. | **Completed (`src/` & Tests Passing)** |
| **TODO-07** | **P1 (Med)** | [`AfterSwapDeltaAggregator.sol`](../src/base/AfterSwapDeltaAggregator.sol), [`HookRigBase.sol`](../src/base/HookRigBase.sol) | **Publicly Exposed Static `5 bps` (`0.05%`) Protocol Royalty (`PROTOCOL_ROYALTY_BPS = 5`, `PROTOCOL_ROYALTY_RECIPIENT`)**: Zero-admin-key constant royalty settled via pullable ERC-6909 claims. | **Completed (`src/` & Tests Passing)** |
| **TODO-08** | **P0 (High)** | All `src/blocks/**/*.sol` | **Complete Configuration Parameter Bounds (`Min` / `Max`) & Overflow Hardening (`CFG-01`–`CFG-08`)**: Enforce strict `[min, max]` ranges across all 22 blocks and fix the `OracleBlock` `int24` idle-wrap overflow (`CFG-01`) and `WalletCap` `uint32` sunset overflow (`CFG-02`). | **Completed (`src/` & Tests Passing)** |
| **TODO-09** | **P2 (Low)** | [`script/HoodiIntegration.s.sol`](../script/HoodiIntegration.s.sol) | **Live Broadcast & Contract Verification on Ethereum Hoodi (`chainId = 560048`)**: Broadcast the deployment script with `--broadcast --verify` and record canonical Hoodi testnet addresses. | **Fork Verified (`Ready for Live Broadcast`)** |
| **TODO-10** | **P0 (Critical)** | All `src/` & `script/` contracts | **Remediate All 36 `solidity-auditor` 2-Pass Loop Security Findings (`SA-01`–`SA-36`)**: Fix untrusted `hookData` user spoofing, launchpad curve pricing/sell/graduation defects, hook permission masks, mixed-currency pots, unfunded orders, flash-accounting cap bypasses, and block logic bugs. | **Completed (`All 36 Fixed & Verified`)** |

---

## 2. Detailed Specification for `TODO-01`: Tier 3 Mutual-Exclusion Matrix (`2,843` Valid Combinations)

### Why We Restrict $2^{22} - 1 = 4,194,303 \rightarrow 2,843$ Valid Combinations

Allowing arbitrary 22-bit combinations creates 6 classes of contradictory behavior:
1. **Multiple Base Fee Models (`DynamicFee`, `ManagedFee`, `MarketHoursFee`)**: Uniswap v4 only accepts one `lpFeeOverride` per swap; enabling multiple base fee blocks causes one to silently overwrite the others.
2. **Duplicate LP Hold Cooldown (`MEVProtection` + `JITGuard`)**: Both write to the same LP hold cooldown storage (`_mevConfig[poolId]`) and run duplicate `beforeRemoveLiquidity` checks.
3. **Conflicting Price-Dislocation Philosophies (`ArbRecapture` vs. `MEVProtection` vs. `CircuitBreaker`)**: `ArbRecapture` requires large tick dislocations to capture MEV spread for LPs, whereas `MEVProtection` and `CircuitBreaker` revert swaps that move the tick past their thresholds.
4. **Competing Contract-Held ERC-6909 Accumulators (`KingOfThePool` vs. `AutoBuyback` vs. `AutoBurn` vs. `ReferralSplit`)**: Enforcing a single primary token sink / pot / affiliate accumulator per pool prevents overlapping ERC-6909 sub-ledgers and excessive return-delta stacking.
5. **Double Buy-Taxation & Reward Overlap (`SwapRewards` vs. `BuySellTax`/`FeeSharing`, `KingOfThePool` + `BuySellTax`)**: Prevents stacking redundant taxes on buyers and enforces `LPRewards` whenever a sink or tax block is active.
6. **Pool Archetype Separation (`Retail Tokenomics / Launchpad` vs. `Institutional / Pro Orderbook`)**: Prevents mixing institutional/orderbook execution blocks (`AccessControl`, `LimitOrders`, `TWAMM`, `Oracle`) with retail launchpad/tax blocks (`AntiSnipe`, `WalletCap`, `VestingSellCap`, `BuySellTax`, `AutoBurn`, `FeeSharing`, `LPRewards`, `SwapRewards`, `KingOfThePool`, `ReferralSplit`, `AutoBuyback`). Additionally, under Tier 3 rules a pool has **at most 10 active blocks simultaneously** (vs. 22 previously), bounding worst-case swap gas overhead.

### Exact Combinatorial Breakdown (`2,843` Valid Stacks)

- **Archetype A — Retail Tokenomics, Creator & Launchpad Pools (`2,645` non-empty combinations)**:
  - **Slot A1 (`Base Fee + AntiSnipe`)**: `6` valid states (`None`, `DynamicFee`, `DynamicFee + AntiSnipe`, `ManagedFee`, `MarketHoursFee`, `MarketHoursFee + AntiSnipe`)
  - **Slot A2 (`Dislocation & JIT Protection`)**: `7` valid states (`None`, `MEVProtection`, `JITGuard`, `ArbRecapture`, `CircuitBreaker`, `ArbRecapture + JITGuard`, `CircuitBreaker + JITGuard`)
  - **Slot A3 (`Holder / Dump Cap`)**: `3` valid states (`None`, `WalletCap`, `VestingSellCap`)
  - **Slot A4 (`Sink, Revenue & LP/Trader Yield`)**: `21` valid states (`1` state with `LPRewards = 0` and no Sink/Revenue + `20` states with `LPRewards = 1` across compatible `(Sink, Revenue)` pairs)
  - **Subtotal**: $(6 \times 7 \times 3 \times 21) - 1 = \mathbf{2,645}$ valid combinations.

- **Archetype B — Institutional & Pro-Trading Pools (`198` non-empty combinations)**:
  - **Slot B1 (`Base Fee`)**: `4` valid states (`None`, `DynamicFee`, `ManagedFee`, `MarketHoursFee`)
  - **Slot B2 (`Dislocation & JIT Protection`)**: `7` valid states (same 7 states as Slot A2)
  - **Slot B3 (`Institutional / Pro Execution`)**: `7` states across any `B1 × B2` (`AccessControl`, `AccessControl + Oracle`, `Oracle`, `LimitOrders`, `TWAMM`, `LimitOrders + Oracle`, `TWAMM + Oracle`, `LimitOrders + TWAMM + Oracle` with `AccessControl` $\perp$ `{LimitOrders, TWAMM}` and `LimitOrders + TWAMM` requiring `Oracle = 1`), plus `2` states for `LimitOrders + TWAMM` (`Oracle = 0, B2 = None`) with `DynamicFee` or `ManagedFee`.
  - **Subtotal**: $(4 \times 7 \times 7) + 2 = \mathbf{198}$ valid combinations.

- **Total Valid Combinations**: $2,645 + 198 = \mathbf{2,843}$ (all **12 Curated Presets** are valid members of this set).

---

## 3. Exact Code Fixes for All Hoodi Integration & Interaction Findings (`Completed in src/`)

### Fix 1 (`TODO-01` / `IT-03` & `TODO-02` / `IT-01`): Preset + Custom Bitmap Union & On-Chain Tier 3 Mutex Validation

- **Finding Summary**:
  1. **`IT-01` (`TODO-02`)**: In [`HookRigOrchestrator._configurePoolStackInternal`](../src/HookRigOrchestrator.sol#L108-L110), passing `config.presetId != PresetId.Blank` along with extra bits in `config.enabledBlocksBitmap` ignored `config.enabledBlocksBitmap` instead of unioning them (`HookPermissionMasks.getPresetBitmap(config.presetId) | config.enabledBlocksBitmap`).
  2. **`IT-03` (`TODO-01`)**: Custom bitmaps were not validated against the Tier 3 Mutual-Exclusion Matrix (`2,843` valid combinations), allowing contradictory block pairs.
- **Target File 1**: [`src/libraries/HookPermissionMasks.sol`](../src/libraries/HookPermissionMasks.sol) — Add `isValidTier3Bitmap(uint32 bitmap)`:
  ```solidity
  function isValidTier3Bitmap(uint32 bitmap) internal pure returns (bool) {
      if (bitmap == 0 || (bitmap & ~ALL_BLOCKS_MASK) != 0) return false;

      // 1. Slot B1 / A1: Base Fee Mutex (at most 1 of Dynamic, Managed, MarketHours)
      uint32 baseFeeBits = bitmap & (BIT_DYNAMIC_FEE | BIT_MANAGED_FEE | BIT_MARKET_HOURS_FEE);
      if (baseFeeBits != 0 && (baseFeeBits & (baseFeeBits - 1)) != 0) return false;

      // AntiSnipe only valid with DynamicFee or MarketHoursFee
      bool hasAntiSnipe = (bitmap & BIT_ANTI_SNIPE) != 0;
      if (hasAntiSnipe && (bitmap & (BIT_DYNAMIC_FEE | BIT_MARKET_HOURS_FEE)) == 0) return false;

      // 2. Slot A2 / B2: Dislocation & JIT Protection (7 valid states)
      bool hasMev = (bitmap & BIT_MEV_PROTECTION) != 0;
      bool hasJit = (bitmap & BIT_JIT_GUARD) != 0;
      bool hasArb = (bitmap & BIT_ARB_RECAPTURE) != 0;
      bool hasCb = (bitmap & BIT_CIRCUIT_BREAKER) != 0;
      if (hasMev && (hasJit || hasArb || hasCb)) return false;
      if (hasArb && hasCb) return false;

      // 3. Archetype Split: Institutional/Pro (Archetype B) vs Retail/Tokenomics (Archetype A)
      uint32 proMask = BIT_ACCESS_CONTROL | BIT_LIMIT_ORDERS | BIT_TWAMM | BIT_ORACLE;
      uint32 retailMask = BIT_ANTI_SNIPE | BIT_WALLET_CAP | BIT_VESTING_SELL_CAP | BIT_BUY_SELL_TAX
          | BIT_AUTO_BURN | BIT_FEE_SHARING | BIT_LP_REWARDS | BIT_SWAP_REWARDS | BIT_KING_OF_THE_POOL
          | BIT_REFERRAL_SPLIT | BIT_AUTO_BUYBACK;

      bool hasPro = (bitmap & proMask) != 0;
      bool hasRetail = (bitmap & retailMask) != 0;
      if (hasPro && hasRetail) return false;

      if (hasPro) {
          bool hasAccess = (bitmap & BIT_ACCESS_CONTROL) != 0;
          bool hasLo = (bitmap & BIT_LIMIT_ORDERS) != 0;
          bool hasTwamm = (bitmap & BIT_TWAMM) != 0;
          bool hasOracle = (bitmap & BIT_ORACLE) != 0;

          if (hasAccess && (hasLo || hasTwamm)) return false;
          if (hasLo && hasTwamm && !hasOracle) {
              bool noProtection = !hasMev && !hasJit && !hasArb && !hasCb;
              bool validFeeForProOrderbook =
                  (bitmap & (BIT_DYNAMIC_FEE | BIT_MANAGED_FEE)) != 0;
              return noProtection && validFeeForProOrderbook;
          }
          return true;
      }

      // Archetype A (Retail / Launchpad / Tokenomics)
      if ((bitmap & BIT_WALLET_CAP) != 0 && (bitmap & BIT_VESTING_SELL_CAP) != 0) return false;

      uint32 sinkBits = bitmap & (BIT_AUTO_BURN | BIT_KING_OF_THE_POOL | BIT_REFERRAL_SPLIT | BIT_AUTO_BUYBACK);
      if (sinkBits != 0 && (sinkBits & (sinkBits - 1)) != 0) return false;

      bool hasTax = (bitmap & BIT_BUY_SELL_TAX) != 0;
      bool hasShare = (bitmap & BIT_FEE_SHARING) != 0;
      bool hasSwapRewards = (bitmap & BIT_SWAP_REWARDS) != 0;
      bool hasLpRewards = (bitmap & BIT_LP_REWARDS) != 0;
      bool hasKing = (bitmap & BIT_KING_OF_THE_POOL) != 0;

      if (hasSwapRewards && (hasTax || hasShare)) return false;
      if (hasKing && hasTax) return false;
      if (!hasLpRewards && (sinkBits != 0 || hasTax || hasShare || hasSwapRewards)) return false;

      return true;
  }
  ```
- **Target File 2**: [`src/HookRigOrchestrator.sol`](../src/HookRigOrchestrator.sol#L108-L113)
  ```solidity
  // BEFORE:
  uint32 bitmap = config.presetId == PresetId.Blank
      ? config.enabledBlocksBitmap
      : HookPermissionMasks.getPresetBitmap(config.presetId);

  if (bitmap == 0) revert InvalidBlockBitmap(bitmap);

  // AFTER (Fixes IT-01 and IT-03):
  uint32 bitmap = HookPermissionMasks.getPresetBitmap(config.presetId) | config.enabledBlocksBitmap;

  if (!HookPermissionMasks.isValidTier3Bitmap(bitmap)) {
      revert InvalidBlockBitmap(bitmap);
  }
  ```

---

### Fix 2 (`TODO-03` / `IT-02`): Bonding Curve `maxWalletBpsDuringCurve` vs. Post-Graduation `WalletCapParams.maxWalletBps` Alignment

- **Finding Summary**:
  During Hoodi fork testing ([`test_HoodiFork_EndToEndCreate2DeployLaunchGraduateAndMultiBlockSwaps`](../test/integration/HoodiForkIntegration.t.sol)), setting `curveCfg.maxWalletBpsDuringCurve = 5000` (`50%`) on `VirtualXYKLaunch` while setting `stackConfig.walletCap.maxWalletBps = 500` (`5%`) on the Uniswap v4 pool meant that `trader1` (who bought `13.3%` of supply on the bonding curve) immediately reverted with `WalletCapExceeded` when attempting a post-graduation buy on the Uniswap v4 pool.
- **Target File**: [`src/launchpad/LaunchpadFactory.sol`](../src/launchpad/LaunchpadFactory.sol)
  - Add custom error `error PostGraduationWalletCapBelowCurveCap(uint16 poolWalletCapBps, uint16 curveWalletCapBps);`
  - Inside `launchVirtualXYK` (before deploying the token and curve), validate that if `BIT_WALLET_CAP` is active on the resolved pool bitmap and `curveConfig.maxWalletBpsDuringCurve > 0`, the post-graduation pool `maxWalletBps` is at least `curveConfig.maxWalletBpsDuringCurve`:
  ```solidity
  uint32 resolvedBitmap =
      HookPermissionMasks.getPresetBitmap(stackConfig.presetId) | stackConfig.enabledBlocksBitmap;
  if (
      (resolvedBitmap & HookPermissionMasks.BIT_WALLET_CAP) != 0
          && curveConfig.maxWalletBpsDuringCurve > 0
          && stackConfig.walletCap.maxWalletBps < curveConfig.maxWalletBpsDuringCurve
  ) {
      revert PostGraduationWalletCapBelowCurveCap(
          stackConfig.walletCap.maxWalletBps, curveConfig.maxWalletBpsDuringCurve
      );
  }
  ```

---

### Fix 3 (`TODO-04` / `IT-04`): `withdrawClaim(..., amount = 0, ...)` Full-Balance Convenience Withdrawal

- **Finding Summary**:
  During Hoodi fork testing of `ReferralSplit` claim withdrawals, calling `orchestrator.withdrawClaim(poolId, currency, 0, recipient)` reverted with `InsufficientClaimBalance(0, available)` rather than withdrawing the caller's full available ERC-6909 claim balance.
- **Target File**: [`src/base/HookRigBase.sol`](../src/base/HookRigBase.sol#L73-L86)
  ```solidity
  // BEFORE:
  function withdrawClaim(PoolId poolId, Currency currency, uint256 amount, address recipient) external {
      uint256 available = poolClaims[poolId][currency][msg.sender];
      if (amount == 0 || available < amount) revert InsufficientClaimBalance(available, amount);
      poolClaims[poolId][currency][msg.sender] = available - amount;
      _payoutERC6909Claim(currency, recipient == address(0) ? msg.sender : recipient, amount);
      emit PoolClaimWithdrawn(poolId, currency, msg.sender, amount);
  }

  // AFTER (Allows amount == 0 to withdraw the full available claim balance):
  function withdrawClaim(PoolId poolId, Currency currency, uint256 amount, address recipient)
      external
      returns (uint256 withdrawn)
  {
      uint256 available = poolClaims[poolId][currency][msg.sender];
      withdrawn = amount == 0 ? available : amount;
      if (withdrawn == 0 || available < withdrawn) revert InsufficientClaimBalance(available, withdrawn);
      poolClaims[poolId][currency][msg.sender] = available - withdrawn;
      _payoutERC6909Claim(currency, recipient == address(0) ? msg.sender : recipient, withdrawn);
      emit PoolClaimWithdrawn(poolId, currency, msg.sender, withdrawn);
  }
  ```

---

### Fix 4 (`TODO-05` / `IT-05`): Directional Buy vs. Sell Return-Delta Budget Validation in `AfterSwapDeltaAggregator`

- **Finding Summary**:
  In [`AfterSwapDeltaAggregator._validateAggregateReturnDeltaBudget`](../src/base/AfterSwapDeltaAggregator.sol#L45-L74), `maxTax = max(buyTaxBps, sellTaxBps)` is added to buy-only blocks (`AutoBurn.burnOnBuyBps`, `LPRewards.extraBuyFeeBps`, `KingOfThePool.potFeeOnBuyBps`). If a pool configures a `0%` buy tax and `15%` sell tax (`sellTaxBps = 1500`) alongside buy-only blocks totaling `12%` (`1200 bps`), the single-sum check computes `1500 + 1200 = 2700 > 2500` and reverts even though neither a buy (`12%`) nor a sell (`15%`) ever exceeds `25%`.
- **Target File**: [`src/base/AfterSwapDeltaAggregator.sol`](../src/base/AfterSwapDeltaAggregator.sol#L45-L74)
  ```solidity
  function _validateAggregateReturnDeltaBudget(PoolStackConfig calldata cfg, uint32 bitmap)
      internal
      pure
      returns (uint256 maxPossibleBps)
  {
      uint256 maxBuyBps = PROTOCOL_ROYALTY_BPS;
      uint256 maxSellBps = PROTOCOL_ROYALTY_BPS;

      if ((bitmap & HookPermissionMasks.BIT_BUY_SELL_TAX) != 0) {
          maxBuyBps += cfg.buySellTax.buyTaxBps;
          maxSellBps += cfg.buySellTax.sellTaxBps;
      }
      if ((bitmap & HookPermissionMasks.BIT_AUTO_BURN) != 0) {
          maxBuyBps += cfg.autoBurn.burnOnBuyBps;
      }
      if ((bitmap & HookPermissionMasks.BIT_FEE_SHARING) != 0) {
          maxBuyBps += cfg.feeSharing.feeShareBps;
          maxSellBps += cfg.feeSharing.feeShareBps;
      }
      if ((bitmap & HookPermissionMasks.BIT_LP_REWARDS) != 0) {
          maxBuyBps += cfg.lpRewards.extraBuyFeeBps;
      }
      if ((bitmap & HookPermissionMasks.BIT_KING_OF_THE_POOL) != 0) {
          maxBuyBps += cfg.kingOfThePool.potFeeOnBuyBps;
      }
      if ((bitmap & HookPermissionMasks.BIT_REFERRAL_SPLIT) != 0) {
          maxBuyBps += cfg.referralSplit.referralFeeBps;
          maxSellBps += cfg.referralSplit.referralFeeBps;
      }
      if ((bitmap & HookPermissionMasks.BIT_AUTO_BUYBACK) != 0) {
          maxBuyBps += cfg.autoBuyback.buybackFeeBps;
          maxSellBps += cfg.autoBuyback.buybackFeeBps;
      }

      maxPossibleBps = maxBuyBps > maxSellBps ? maxBuyBps : maxSellBps;
  }
  ```

---

### Fix 5 (`TODO-06` / `IT-06`): Post-Cut Net Volume Attribution in `SwapRewards`

- **Finding Summary**:
  In [`HookRigOrchestrator._runAfterSwapPipeline`](../src/HookRigOrchestrator.sol#L403-L405), `_accrueSwapRewards` is called with `ctx.grossUnspecifiedAmount` rather than the net post-waterfall amount (`ctx.grossUnspecifiedAmount - totalCutAmount`), awarding volume points on tokens that were withheld by `afterSwapReturnDelta` blocks (`LPRewards`, `AutoBurn`, `ReferralSplit`, etc.).
- **Target File**: [`src/HookRigOrchestrator.sol`](../src/HookRigOrchestrator.sol#L403-L405)
  ```solidity
  // BEFORE:
  if ((bitmap & HookPermissionMasks.BIT_SWAP_REWARDS) != 0) {
      _accrueSwapRewards(poolId, ctx.trader, ctx.grossUnspecifiedAmount);
  }

  // AFTER:
  if ((bitmap & HookPermissionMasks.BIT_SWAP_REWARDS) != 0) {
      uint256 netVolume = ctx.grossUnspecifiedAmount > totalCutAmount
          ? ctx.grossUnspecifiedAmount - totalCutAmount
          : 0;
      _accrueSwapRewards(poolId, ctx.trader, netVolume);
  }
  ```

---

## 4. Detailed Specification for `TODO-07`: Publicly Exposed Static `5 bps` (`0.05%`) Protocol Royalty

### Design Philosophy: Transparent, Immutable, Zero Admin Key Complexity

To charge a small, predictable `5 bps` (`0.05%`) protocol royalty without introducing governance risk, key-rotation complexity, or storage read (`SLOAD`) overhead on swaps:

1. **Publicly Announced Compile-Time Constants**:
   - Define `PROTOCOL_ROYALTY_BPS = 5` (`0.05%`) and `PROTOCOL_ROYALTY_RECIPIENT = 0x...` as `public constant` values directly on [`AfterSwapDeltaAggregator.sol`](../src/base/AfterSwapDeltaAggregator.sol) (and exposed on `IHookRigOrchestrator`).
   - **No Admin Setter / No Mutable Key**: Because both the `5 bps` rate and the recipient address are hardcoded into contract bytecode at build time, there is **zero admin key** to manage, rotate, or compromise. Users, auditors, and block explorers can read `orchestrator.PROTOCOL_ROYALTY_BPS()` and `orchestrator.PROTOCOL_ROYALTY_RECIPIENT()` directly.
   - **Zero `SLOAD` Overhead**: Constants compile to inline `PUSH` opcodes (`0` storage reads per swap).
2. **Pull-Based ERC-6909 Claim Settlement (Zero Swap DoS Risk)**:
   - Inside [`AfterSwapDeltaAggregator._executeAfterSwapDeltaWaterfall`](../src/base/AfterSwapDeltaAggregator.sol#L76-L92), before running the optional pool blocks, compute:
     `uint256 royaltyCut = _boundedCut(grossAmount, PROTOCOL_ROYALTY_BPS, totalCutAmount, maxAllowedTotalCut);`
   - Credit `royaltyCut` to `PROTOCOL_ROYALTY_RECIPIENT` via `_creditClaimInternal(poolId, ctx.unspecifiedCurrency, PROTOCOL_ROYALTY_RECIPIENT, royaltyCut)` (which mints an isolated ERC-6909 claim inside `PoolManager`).
   - On micro/dust swaps (`grossAmount < 2,000 wei`), `Math.mulDiv(grossAmount, 5, 10_000, Math.Rounding.Floor)` rounds cleanly to `0`, so tiny swaps never revert.
   - `PROTOCOL_ROYALTY_RECIPIENT` can withdraw accumulated fees from any pool at any time via `orchestrator.withdrawClaim(poolId, currency, 0, recipient)`.

### Exact Code Fix (`src/base/AfterSwapDeltaAggregator.sol`)

```solidity
/// @notice Publicly announced 5 bps (0.05%) protocol royalty on swaps.
uint16 public constant PROTOCOL_ROYALTY_BPS = 5;

/// @notice Publicly exposed static protocol royalty recipient address defined at build time (no admin setter).
address public constant PROTOCOL_ROYALTY_RECIPIENT = 0x000000000000000000000000000000000000dEaD; // Replace with canonical HookRig treasury multisig / splitter address at build

function _executeAfterSwapDeltaWaterfall(
    IPoolManager manager,
    PoolKey calldata key,
    PoolId poolId,
    uint32 bitmap,
    PoolTokenDir.SwapContext memory ctx
) internal returns (int128 totalHookDeltaUnspecified, uint256 totalCutAmount) {
    if (ctx.grossUnspecifiedAmount == 0) {
        return (0, 0);
    }

    uint256 grossAmount = ctx.grossUnspecifiedAmount;
    uint256 maxAllowedTotalCut = Math.mulDiv(grossAmount, MAX_AGGREGATE_AFTER_SWAP_BPS, 10_000, Math.Rounding.Floor);
    uint256 lpDonationAmount = 0;

    // 0. Static 5 bps (0.05%) Protocol Royalty (credited as pullable ERC-6909 claim)
    if (PROTOCOL_ROYALTY_RECIPIENT != address(0) && PROTOCOL_ROYALTY_BPS > 0) {
        uint256 royaltyCut = _boundedCut(grossAmount, PROTOCOL_ROYALTY_BPS, totalCutAmount, maxAllowedTotalCut);
        if (royaltyCut > 0) {
            totalCutAmount += royaltyCut;
            _creditClaimInternal(poolId, ctx.unspecifiedCurrency, PROTOCOL_ROYALTY_RECIPIENT, royaltyCut);
        }
    }

    if ((bitmap & HookPermissionMasks.AFTER_SWAP_RETURN_DELTA_BLOCKS_MASK) == 0) {
        return (SafeCast.toInt128(SafeCast.toInt256(totalCutAmount)), totalCutAmount);
    }
    // ... existing blocks 1..8 follow unchanged ...
```

---

## 5. Detailed Specification for `TODO-08`: Configuration Parameter Ranges (`Min` & `Max`) & Overflow Hardening Across All 22 Blocks

### 5.1 Master Configuration Bounds Table (`All 22 Blocks + Launchpad`)

Every configurable parameter across the 22 blocks must enforce explicit `[Min, Max]` bounds at registration/submission time so that:
1. No `uint24` / `uint32` / `uint64` / `int24` arithmetic can overflow or wrap during swap/liquidity callbacks.
2. No pool can be configured into a permanent honeypot (`100%` ongoing fee, `0%` sell cap, infinite lockup, or unreachable tick threshold).

| Block # | Block Name | Parameter | Type | Min Allowed | Max Allowed | Default (if `0`) | Audit Status / Action Required |
| :---: | :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| **Global** | `AfterSwapDeltaAggregator` | Aggregate Return-Delta Sum | `uint16` | `5 bps` (`0.05%` royalty) | `2,500 bps` (`25.00%`) | — | Enforced (`MAX_AGGREGATE_AFTER_SWAP_BPS = 2500`) |
| **#0** | `DynamicFee` | `baseFee` | `uint24` | `0` (`0.00%`) | `maxFee` (`<= 50,000`) | `0` | Enforced (`MAX_DYNAMIC_FEE = 50_000`) |
| **#0** | `DynamicFee` | `maxFee` | `uint24` | `baseFee` | `50,000` (`5.00%`) | `0` | Enforced (`MAX_DYNAMIC_FEE = 50_000`) |
| **#0** | `DynamicFee` | `volatilityTickThreshold` | `int24` | `1` tick | `1,000` ticks | `50` ticks | **Fix `CFG-04`**: Revert if `< 0` or `> 1000` (since EMA clamps `absDelta` at `1000`) |
| **#1** | `ManagedFee` | `startingFee` | `uint24` | `0` (`0.00%`) | `feeCap` (`<= 50,000`) | `0` | Enforced (`startingFee <= cap`) |
| **#1** | `ManagedFee` | `feeCap` | `uint24` | `1` (`0.0001%`) | `50,000` (`5.00%`) | `50,000` (`5.00%`) | **Fix `CFG-08`**: Revert if `feeCap > 50_000` (instead of silent clamp) and default `manager` to `poolAdmin` if `address(0)` |
| **#2** | `MarketHoursFee` | `openFee` / `closedFee` | `uint24` | `0` (`0.00%`) | `50,000` (`5.00%`) | `0` | Enforced (`MAX_MARKET_HOURS_FEE = 50_000`) |
| **#2** | `MarketHoursFee` | `openHourUtc` / `closeHourUtc` | `uint8` | `0` | `23` | `0` | **Fix `CFG-08`**: Require `openHourUtc != closeHourUtc` when `openFee != closedFee` |
| **#3** | `AntiSnipe` | `launchFee` | `uint24` | `normalFee` | `800,000` (`80.00%`) | `0` | Enforced (`MAX_ANTI_SNIPE_LAUNCH_FEE = 800_000`) |
| **#3** | `AntiSnipe` | `normalFee` | `uint24` | `0` (`0.00%`) | `50,000` (`5.00%`) | `0` | **Fix `CFG-03`**: Cap `normalFee <= 50_000` (`5%`) so `AntiSnipe` cannot bypass the `5%` ongoing fee cap |
| **#3** | `AntiSnipe` | `decayBlocks` | `uint32` | `0` blocks | `50,400` blocks (~7d) | `0` | **Fix `CFG-03`**: Cap `decayBlocks <= 50_400` to prevent `type(uint32).max` permanent 80% fee lock |
| **#4** | `MEVProtection` | `maxTickDeltaPerSwap` | `int24` | `10` ticks (~`0.10%`) | `887,272` ticks | `0` (disabled) | **Fix `CFG-04`**: Revert if `< 0`, `1..9` (bricks normal swaps), or `> 887,272` |
| **#4 / #17** | `MEVProtection` / `JITGuard` | `minLPHoldBlocks` | `uint32` | `0` blocks | `7,200` blocks (~24h) | `0` | **Fix `CFG-02`**: Revert if `> 7200` and widen `uint256(addedBlock) + uint256(minHold)` |
| **#4 / #17** | `MEVProtection` / `JITGuard` | `jitExitPenaltyBps` | `uint16` | `0 bps` | `5,000 bps` (`50.00%`) | `0` | **Fix `CFG-04`**: Revert if `jitExitPenaltyBps > 5000` |
| **#5** | `ArbRecapture` | `recaptureShareBps` | `uint16` | `0 bps` | `8,000 bps` (`80.00%`) | `0` | Enforced (`MAX_ARB_RECAPTURE_SHARE_BPS = 8000`; effective cut capped at `1000 bps`) |
| **#5** | `ArbRecapture` | `arbTriggerTickDelta` | `int24` | `1` tick | `100,000` ticks | `20` ticks | **Fix `CFG-04`**: Revert if `< 0` or `> 100,000` |
| **#6** | `AccessControl` | `manager` / `merkleRoot` | `address`/`bytes32` | Non-empty if active | — | `poolAdmin` | **Fix `CFG-08`**: Default `manager` to `poolAdmin` if `address(0)` so pool cannot be bricked |
| **#7** | `WalletCap` | `maxWalletBps` | `uint16` | `10 bps` (`0.10%`) | `10,000 bps` (`100%`) | `0` (disabled) | Enforced (`MIN_WALLET_CAP_BPS = 10`, `<= 10_000`) |
| **#7** | `WalletCap` | `sunsetBlocks` | `uint32` | `0` (permanent) | `2,628,000` (~1 yr) | `0` | **Fix `CFG-02`**: Cap `<= 2,628,000` and widen `uint256(state.startBlock) + uint256(sunset)` to prevent `uint32` overflow |
| **#8** | `BuySellTax` | `buyTaxBps` / `sellTaxBps` | `uint16` | `0 bps` | `1,000 bps` (`10.00%`) | `0` | Enforced (`MAX_TAX_BPS = 1000`); **Fix `CFG-08`** in `update()` recipient check |
| **#9** | `AutoBurn` | `burnOnBuyBps` | `uint16` | `0 bps` | `500 bps` (`5.00%`) | `0` | Enforced (`MAX_AUTO_BURN_BPS = 500`) |
| **#10** | `FeeSharing` | `feeShareBps` | `uint16` | `0 bps` | `500 bps` (`5.00%`) | `0` | Enforced (`MAX_FEE_SHARE_BPS = 500`) |
| **#10** | `FeeSharing` | `secondaryShareBps` | `uint16` | `0 bps` | `10,000 bps` (`100%`) | `0` | **Fix `CFG-08`**: Require `secondaryRecipient != address(0)` if `secondaryShareBps > 0` |
| **#11** | `LPRewards` | `extraBuyFeeBps` | `uint16` | `0 bps` | `500 bps` (`5.00%`) | `0` | Enforced (`MAX_LP_REWARD_BPS = 500`) |
| **#12** | `SwapRewards` | `pointsPerUnitVolume` | `uint128` | `0` | `1e27` (`10^9 * 1e18`) | `0` | **Fix `CFG-07`**: Cap `<= 1e27` to prevent `totalPoolSwapPoints` overflow |
| **#13** | `KingOfThePool` | `potFeeOnBuyBps` | `uint16` | `0 bps` | `500 bps` (`5.00%`) | `0` | Enforced (`MAX_KING_POT_BPS = 500`) |
| **#13** | `KingOfThePool` | `roundDurationSeconds` | `uint32` | `60s` (1 min) | `2,592,000s` (30 days) | `3,600s` (1h) | **Fix `CFG-06`**: Enforce `[60, 2_592_000]` when `> 0` so jackpot rounds cannot lock for 136 years |
| **#14** | `LimitOrders` | `targetTick` | `int24` | `TickMath.MIN_TICK` | `TickMath.MAX_TICK` | — | **Fix `CFG-05`**: Require `targetTick % key.tickSpacing == 0` so `processCrossedTicks` never skips the order |
| **#15** | `TWAMM` | `durationSeconds` | `uint64` | `60s` (1 min) | `31,536,000s` (365d) | — | **Fix `CFG-06`**: Enforce `[60, 365 days]` to prevent `uint64` expiry overflow |
| **#16** | `Oracle` | `MAX_ORACLE_TICK_DELTA_PER_SEC` | `int24` | — | `100` ticks/sec | — | **Fix `CFG-01` (Critical)**: Widen `maxChange` math to `int256` so `elapsed >= 83,887s` (~23.3h idle) never wraps `int24` negative! |
| **#18** | `CircuitBreaker` | `maxWindowTickDeviation` | `int24` | `10` ticks (~`0.10%`) | `887,272` ticks | `0` (disabled) | **Fix `CFG-04`**: Revert if `< 0`, `1..9`, or `> 887,272` |
| **#18** | `CircuitBreaker` | `windowSeconds` | `uint32` | `10s` | `86,400s` (24h) | `300s` (5m) | **Fix `CFG-02`**: Revert if `> 86,400` and widen `uint256(cb.windowStartTimestamp) + uint256(cb.windowSeconds)` |
| **#19** | `ReferralSplit` | `referralFeeBps` | `uint16` | `0 bps` | `300 bps` (`3.00%`) | `0` | Enforced (`MAX_REFERRAL_FEE_BPS = 300`) |
| **#20** | `VestingSellCap` | `maxDailySellBps` | `uint16` | `50 bps` (`0.50%/d`) | `10,000 bps` (`100%/d`) | `0` (disabled) | Enforced (`MIN_DAILY_SELL_BPS = 50`); **Fix `CFG-07`**: Use `Math.Rounding.Ceil` so dust balances never compute `maxAllowed == 0` |
| **#21** | `AutoBuyback` | `buybackFeeBps` | `uint16` | `0 bps` | `500 bps` (`5.00%`) | `0` | Enforced (`MAX_AUTO_BUYBACK_BPS = 500`) |
| **#21** | `AutoBuyback` | `triggerFloorTick` | `int24` | `-887,272` | `+887,272` | `0` | **Fix `CFG-04`**: Require `triggerFloorTick >= TickMath.MIN_TICK && triggerFloorTick <= TickMath.MAX_TICK` |

---

### 5.2 Exact Code Fixes for Range & Overflow Findings (`CFG-01` through `CFG-08`)

#### `CFG-01` (Critical Fund-Freeze Prevention): `OracleBlock` `int24` Idle-Pool Narrowing Wrap (`src/blocks/trading/OracleBlock.sol`)
- **Vulnerability Found During Range Audit**:
  In [`OracleLogic.updateCheckpoint`](../src/blocks/trading/OracleBlock.sol#L31-L37):
  ```solidity
  int24 diff = currentTick - obs.lastTick;
  int24 maxChange = int24(int256(uint256(elapsed)) * int256(MAX_ORACLE_TICK_DELTA_PER_SEC));
  if (diff > maxChange) {
      currentTick = obs.lastTick + maxChange;
  ```
  `type(int24).max` is `8,388,607`. If an `Oracle`-enabled pool has no swap or liquidity activity for `elapsed >= 83,887` seconds (`~23.3 hours`), `elapsed * 100 >= 8,388,700 > type(int24).max`. The narrowing cast `int24(...)` truncates higher bits and wraps `maxChange` to a **negative number** (e.g., at `elapsed = 86,400s`, `maxChange = -8,137,216`). Then `diff > maxChange` evaluates to `true`, and `obs.lastTick + maxChange` subtracts `8.13M` ticks, **underflowing `int24` (`Panic(0x11)`) and permanently freezing all swaps, `addLiquidity`, and `removeLiquidity` on the pool!**
- **Exact Fix (`src/blocks/trading/OracleBlock.sol`)**:
  ```solidity
  // AFTER (Compute diff and maxChange in int256 so idle periods of any length never wrap or overflow int24):
  int256 diff = int256(currentTick) - int256(obs.lastTick);
  int256 maxChange = int256(uint256(elapsed)) * int256(MAX_ORACLE_TICK_DELTA_PER_SEC);
  if (diff > maxChange) {
      currentTick = int24(int256(obs.lastTick) + maxChange);
  } else if (diff < -maxChange) {
      currentTick = int24(int256(obs.lastTick) - maxChange);
  }
  ```

#### `CFG-02` (High): `uint32` Addition Overflow in `WalletCapBlock`, `JITGuardBlock`, and `CircuitBreakerBlock`
- **Vulnerability Found**:
  In [`WalletCapLogic.enforceAfterBuy`](../src/blocks/token-rules/WalletCapBlock.sol#L47), `state.startBlock + sunset` adds two `uint32` values before widening to `uint256`. Setting `sunsetBlocks = type(uint32).max` causes `state.startBlock + sunset` to revert with `Panic(0x11)` on every buy swap. The same `uint32 + uint32` pattern exists in [`JITGuardLogic.enforceOnRemove`](../src/blocks/protection/JITGuardBlock.sol#L38) (`addedBlock + minHold`) and [`CircuitBreakerLogic.checkAndAdvance`](../src/blocks/protection/CircuitBreakerBlock.sol#L26) (`cb.windowStartTimestamp + cb.windowSeconds`).
- **Exact Fix**:
  1. In [`WalletCapBlock.sol`](../src/blocks/token-rules/WalletCapBlock.sol):
     - Add `uint32 internal constant MAX_SUNSET_BLOCKS = 2_628_000; // ~1 year at 12s blocks` and revert if `params.sunsetBlocks > MAX_SUNSET_BLOCKS`.
     - Change line 47 to: `if (sunset > 0 && block.number >= uint256(state.startBlock) + uint256(sunset)) return;`
  2. In [`JITGuardBlock.sol`](../src/blocks/protection/JITGuardBlock.sol):
     - Revert if `minLPHoldBlocks > MAX_LP_HOLD_BLOCKS` (`7200`) or `jitExitPenaltyBps > 5000`.
     - Change line 38 to: `if (addedBlock > 0 && block.number < uint256(addedBlock) + uint256(minHold))`
  3. In [`CircuitBreakerBlock.sol`](../src/blocks/protection/CircuitBreakerBlock.sol):
     - Revert if `params.windowSeconds > MAX_WINDOW_SECONDS` (`86_400`) or `(params.maxWindowTickDeviation != 0 && (params.maxWindowTickDeviation < 10 || params.maxWindowTickDeviation > 887_272))`.
     - Change line 26 to: `if (cb.windowStartTimestamp == 0 || block.timestamp >= uint256(cb.windowStartTimestamp) + uint256(cb.windowSeconds))`

#### `CFG-03` (High): `AntiSnipeBlock` Ongoing `normalFee` (`<= 5%`) & `decayBlocks` (`<= 50,400`) Bounds
- **Vulnerability Found**:
  [`AntiSnipeLogic.init`](../src/blocks/protection/AntiSnipeBlock.sol#L25) checks `launchFee >= normalFee && launchFee <= 800_000`, allowing a malicious pool creator to set `launchFee = 800_000` (`80%`), `normalFee = 800_000` (`80%`), or `decayBlocks = type(uint32).max`, creating a permanent `80%` fee honeypot.
- **Exact Fix (`src/blocks/protection/AntiSnipeBlock.sol`)**:
  ```solidity
  uint24 internal constant MAX_ANTI_SNIPE_LAUNCH_FEE = 800_000; // 80.00%
  uint24 internal constant MAX_ANTI_SNIPE_NORMAL_FEE = 50_000;  // 5.00%
  uint32 internal constant MAX_ANTI_SNIPE_DECAY_BLOCKS = 50_400; // ~7 days at 12s blocks

  if (
      params.launchFee < params.normalFee
          || params.launchFee > MAX_ANTI_SNIPE_LAUNCH_FEE
          || params.normalFee > MAX_ANTI_SNIPE_NORMAL_FEE
          || params.decayBlocks > MAX_ANTI_SNIPE_DECAY_BLOCKS
  ) {
      revert InvalidAntiSnipeConfig(params.launchFee, params.normalFee);
  }
  ```

#### `CFG-04` (Medium): Tick Threshold & Deviation Bounds in `DynamicFee`, `ArbRecapture`, `MEVProtection`, and `AutoBuyback`
- **Exact Fix**:
  - [`DynamicFeeBlock.sol`](../src/blocks/fees/DynamicFeeBlock.sol): Require `params.volatilityTickThreshold >= 0 && params.volatilityTickThreshold <= 1000` (since `absDelta` is clamped to `1000` ticks on line 47).
  - [`ArbRecaptureBlock.sol`](../src/blocks/protection/ArbRecaptureBlock.sol): Require `params.arbTriggerTickDelta >= 0 && params.arbTriggerTickDelta <= 100_000`.
  - [`MEVProtectionBlock.sol`](../src/blocks/protection/MEVProtectionBlock.sol): Require `params.maxTickDeltaPerSwap == 0 || (params.maxTickDeltaPerSwap >= 10 && params.maxTickDeltaPerSwap <= 887_272)`.
  - [`AutoBuybackBlock.sol`](../src/blocks/rewards/AutoBuybackBlock.sol): Require `params.triggerFloorTick >= -887_272 && params.triggerFloorTick <= 887_272`.

#### `CFG-05` (Medium): `LimitOrdersBlock` Tick-Spacing Alignment Validation
- **Vulnerability Found**:
  [`LimitOrdersLogic.processCrossedTicks`](../src/blocks/trading/LimitOrdersBlock.sol#L143-L162) steps by `key.tickSpacing` (`int24 aligned = (prevTick / step) * step; for (...; t += step)`), so any limit order placed at a `targetTick` where `targetTick % key.tickSpacing != 0` is stepped over and can never be marked `filled`.
- **Exact Fix (`src/blocks/trading/LimitOrdersBlock.sol`)**:
  ```solidity
  error UnalignedLimitOrderTick(int24 targetTick, int24 tickSpacing);

  // Inside placeOrder:
  if (
      key.tickSpacing <= 0 || targetTick % key.tickSpacing != 0
          || targetTick < -887_272 || targetTick > 887_272
  ) {
      revert UnalignedLimitOrderTick(targetTick, key.tickSpacing);
  }
  ```

#### `CFG-06` (Medium): Duration Bounds in `KingOfThePoolBlock` & `TWAMMBlock`
- **Exact Fix**:
  - [`KingOfThePoolBlock.sol`](../src/blocks/rewards/KingOfThePoolBlock.sol): Enforce `MIN_KING_ROUND_DURATION = 60` (1 minute) and `MAX_KING_ROUND_DURATION = 30 days` (`2,592,000` seconds) whenever `duration > 0` so jackpots can never be locked for years.
  - [`TWAMMBlock.sol`](../src/blocks/trading/TWAMMBlock.sol): Enforce `durationSeconds >= 60 && durationSeconds <= 365 days` (`31,536,000` seconds) in `submitOrder` so `uint64(block.timestamp) + durationSeconds` never overflows or locks streaming orders indefinitely.

#### `CFG-07` (Low): `VestingSellCap` Dust-Balance Sell Liveness & `SwapRewards` Rate Cap
- **Exact Fix**:
  - [`VestingSellCapBlock.sol`](../src/blocks/token-rules/VestingSellCapBlock.sol#L57): Change `Math.Rounding.Floor` to `Math.Rounding.Ceil` in `uint256 maxAllowed = Math.mulDiv(ep.startOfEpochBalance, maxBps, 10_000, Math.Rounding.Ceil);` so a wallet holding a tiny dust balance (`< 200 wei`) always has `maxAllowed >= 1` and is never blocked from selling its dust.
  - [`SwapRewardsBlock.sol`](../src/blocks/rewards/SwapRewardsBlock.sol): Enforce `params.pointsPerUnitVolume <= 1e27` (`MAX_POINTS_PER_UNIT_VOLUME`) in `_initSwapRewards`.

#### `CFG-08` (Low): `BuySellTax.update`, `FeeSharing`, `ManagedFee`, `MarketHoursFee`, and `AccessControl` Config Sanity
- **Exact Fix**:
  - [`BuySellTaxBlock.sol`](../src/blocks/token-rules/BuySellTaxBlock.sol#L44): In `BuySellTaxLogic.update`, resolve `address effectiveRecipient = newRecipient != address(0) ? newRecipient : cfg.taxRecipient;` first, then check `if ((newBuyTaxBps > 0 || newSellTaxBps > 0) && effectiveRecipient == address(0)) revert InvalidTaxRecipient();`.
  - [`FeeSharingBlock.sol`](../src/blocks/rewards/FeeSharingBlock.sol#L18): Revert with `InvalidFeeSharingConfig()` if `params.secondaryShareBps > 0 && params.secondaryRecipient == address(0)`.
  - [`MarketHoursFeeBlock.sol`](../src/blocks/fees/MarketHoursFeeBlock.sol#L17): Revert with `InvalidMarketHoursConfig()` if `params.openFee != params.closedFee && params.openHourUtc == params.closeHourUtc`.
  - [`AccessControlBlock.sol`](../src/blocks/protection/AccessControlBlock.sol#L54): Default `manager` to `poolAdmin` if `params.manager == address(0)` so allowlist management is never orphaned.

---

## 6. Detailed Specification for `TODO-10`: All 36 `solidity-auditor` 2-Pass Loop Security Findings (`SA-01`–`SA-36`)

Source report: [`.solidity-auditor/runs/20261014-215713/full-report.md`](../.solidity-auditor/runs/20261014-215713/full-report.md) · Ledger: [`.solidity-auditor/memory.tsv`](../.solidity-auditor/memory.tsv) (`3edd4d2` · 36 records · 2 passes, 12/12 agents per pass).

### 6.1 Master Checklist of All 36 Findings

| ID | Status | Conf | Pass Coverage | Location | Ledger Key | Summary Title |
| :--- | :---: | :---: | :---: | :--- | :--- | :--- |
| **`SA-01`** | `[x]` | `[95]` | 1/2 runs (Pass 2) (5/12 agents) | `AccessControlBlock._verifyAccess` | `accesscontrolblock|verifyaccess|single-leaf-merkle-proof-rejection` | AccessControlLogic.verifyAccess requires hookData.length >= 64 and rejects single-leaf Merkle trees |
| **`SA-02`** | `[x]` | `[95]` | 2/2 runs (11/12 agents) | `AfterSwapDeltaAggregator._executeAfterSwapDeltaWaterfall` | `afterswapdeltaaggregator|executeafterswapdeltawaterfall|exact-output-buy-fee-bypass` | A buyer who submits an exact-output swap skips AutoBurnBlock and KingOfThePoolBlock fees |
| **`SA-03`** | `[x]` | `[95]` | 2/2 runs (11/12 agents) | `AfterSwapDeltaAggregator._validateAggregateReturnDeltaBudget` | `afterswapdeltaaggregator|validateaggregatereturndeltabudget|arb-recapture-budget-starvation` | _validateAggregateReturnDeltaBudget omits BIT_ARB_RECAPTURE and counts zero-liquidity LP donations against the cap |
| **`SA-04`** | `[x]` | `[95]` | 2/2 runs (11/12 agents) | `ArbRecaptureBlock.computeCutBps` | `arbrecaptureblock|computecutbps|stale-reference-tick-order` | computeCutBps reads state.referenceTick before it updates referenceTick for a new block |
| **`SA-05`** | `[x]` | `[95]` | 2/2 runs (10/12 agents) | `AutoBuybackBlock._processAutoBuyback` | `autobuybackblock|processautobuyback|inverted-floor-tick-and-threshold-mismatch` | accumulateAndCheckTrigger checks postSwapTick <= triggerFloorTick even when projectToken is currency1 |
| **`SA-06`** | `[x]` | `[95]` | 2/2 runs (10/12 agents) | `BuySellTaxBlock._updateBuySellTax` | `buyselltaxblock|updatebuyselltax|unreachable-tax-update-and-recipient-check` | HookRigOrchestrator exposes no external function for _updateBuySellTax and update rejects zero newRecipient |
| **`SA-07`** | `[x]` | `[95]` | 1/2 runs (Pass 2) (3/12 agents) | `CircuitBreakerBlock._checkAndAdvanceCircuitBreaker` | `circuitbreakerblock|checkandadvance|window-rollover-anchor-tick-manipulation` | CircuitBreakerLogic.checkAndAdvance anchors new windows to preSwapTick and lets an attacker lock out one swap direction |
| **`SA-08`** | `[x]` | `[95]` | 1/2 runs (Pass 2) (8/12 agents) | `DynamicFeeBlock._computeDynamicFee` | `dynamicfeeblock|compute|pre-swap-tick-volatility-lag-and-intra-block-spike` | DynamicFeeLogic.compute reads preSwapTick before the swap moves the price and spikes intra-block volatility without EMA damping |
| **`SA-09`** | `[x]` | `[95]` | 2/2 runs (11/12 agents) | `HookPermissionMasks.permissionsForBitmap` | `hookpermissionmasks|permissionsforbitmap|missing-hook-permission-flags` | permissionsForBitmap omits callback flags for beforeInitialize, afterInitialize, beforeSwap, and afterSwap |
| **`SA-10`** | `[x]` | `[95]` | 2/2 runs (11/12 agents) | `HookRigBase._resolveUser` | `hookrigbase|resolveuser|untrusted-hookdata-user-spoofing` | An attacker passes a chosen address in hookData from an untrusted router to bypass access and cap rules |
| **`SA-11`** | `[x]` | `[95]` | 2/2 runs (11/12 agents) | `HookRigOrchestrator._beforeAddLiquidity` | `hookrigorchestrator|beforeaddliquidity|missing-authorized-curve-exemption` | _beforeAddLiquidity enforces AccessControlBlock on authorizedCurve and blocks graduation liquidity |
| **`SA-12`** | `[x]` | `[95]` | 2/2 runs (9/12 agents) | `HookRigOrchestrator.notifyPoolGraduated` | `hookrigorchestrator|notifypoolgraduated|unreset-graduation-clocks` | notifyPoolGraduated resets AntiSnipeBlock startBlock but leaves WalletCapBlock and KingOfThePoolBlock clocks unreset |
| **`SA-13`** | `[x]` | `[95]` | 2/2 runs (11/12 agents) | `HookRigOrchestrator.registerPoolStack` | `hookrigorchestrator|registerpoolstack|unguarded-pool-registration-and-init` | An attacker can front-run registerPoolStack or PoolManager.initialize to take control or block graduation |
| **`SA-14`** | `[x]` | `[95]` | 1/2 runs (Pass 2) (5/12 agents) | `HookRigOrchestrator._runAfterSwapPipeline` | `hookrigorchestrator|runafterswappipeline|partial-fill-amount-specified-overcount` | HookRigOrchestrator._runAfterSwapPipeline uses params.amountSpecified instead of settled swapDelta on partial fills |
| **`SA-15`** | `[x]` | `[95]` | 1/2 runs (Pass 2) (3/12 agents) | `HookRigOrchestrator.seedKingPotFromLaunchCurve` | `hookrigorchestrator|seedkingpotfromlaunchcurve|creator-surcharge-claim-diversion` | HookRigOrchestrator.seedKingPotFromLaunchCurve diverts buyer anti-snipe surcharges to poolAdmin when KingOfThePoolBlock is disabled |
| **`SA-16`** | `[x]` | `[95]` | 1/2 runs (Pass 2) (11/12 agents) | `JITGuardBlock._recordLPAddition` | `jitguardblock|recordaddition|position-owner-mismatch-and-cooldown-reset` | JITGuardLogic.recordAddition keys positions by _resolveUser and overwrites lpAddedBlock on any 1-wei addition |
| **`SA-17`** | `[x]` | `[95]` | 2/2 runs (12/12 agents) | `KingOfThePoolBlock.processBuy` | `kingofthepoolblock|processbuy|mixed-currency-pot-accounting` | processBuy overwrites potCurrency from currency0 to currency1 and sums both currencies into currentPotAmount |
| **`SA-18`** | `[x]` | `[95]` | 2/2 runs (11/12 agents) | `LaunchpadFactory._deployTokenAndVest` | `launchpadfactory|deploytokenandvest|pre-graduation-creator-vesting-and-supply-mismatch` | _deployTokenAndVest allows pre-graduation vested token dumps and unvalidated curve supply allocations |
| **`SA-19`** | `[x]` | `[95]` | 2/2 runs (12/12 agents) | `LaunchpadFactory.launchVirtualXYK` | `launchpadfactory|launchvirtualxyk|immutable-orchestrator-mismatch` | Launch curves call notifyPoolGraduated on immutable hookOrchestrator instead of poolKey.hooks |
| **`SA-20`** | `[x]` | `[95]` | 2/2 runs (12/12 agents) | `LimitOrdersBlock.placeLimitOrder` | `limitordersblock|placelimitorder|unfunded-native-limit-order-drain` | placeOrder collects no ETH when inputCurrency is address zero and lets callers drain contract ETH |
| **`SA-21`** | `[x]` | `[95]` | 2/2 runs (11/12 agents) | `LimitOrdersBlock.processCrossedTicks` | `limitordersblock|processcrossedticks|signed-tick-division-and-sticky-bucket` | processCrossedTicks truncates toward zero, skips ticks past 16 steps, and never resets bucket.filled |
| **`SA-22`** | `[x]` | `[95]` | 2/2 runs (9/12 agents) | `MEVProtectionBlock.enforceAfterSwap` | `mevprotectionblock|enforceafterswap|unread-sandwich-tracking-state` | MEVProtectionLogic.enforceAfterSwap writes lastSwapBlock and lastSwapZeroForOne without reading them |
| **`SA-23`** | `[x]` | `[95]` | 2/2 runs (12/12 agents) | `NativeTickLaunch.unlockCallback` | `nativeticklaunch|unlockcallback|token-amount-used-as-liquidity-delta` | NativeTickLaunch.unlockCallback passes bands[i].tokenAmount directly as liquidityDelta |
| **`SA-24`** | `[x]` | `[95]` | 2/2 runs (11/12 agents) | `OracleBlock.updateCheckpoint` | `oracleblock|updatecheckpoint|int24-truncation-overflow` | updateCheckpoint truncates elapsed * MAX_ORACLE_TICK_DELTA_PER_SEC to int24 and wraps negative |
| **`SA-25`** | `[x]` | `[95]` | 2/2 runs (11/12 agents) | `SteppedTrancheLaunch.buy` | `steppedtranchelaunch|buy|single-tranche-bulk-buy-pricing` | SteppedTrancheLaunch.buy prices the full order at the current tranche price and skips higher tranches |
| **`SA-26`** | `[x]` | `[95]` | 2/2 runs (10/12 agents) | `SteppedTrancheLaunch.initializeCurve` | `steppedtranchelaunch|initializecurve|unbounded-surcharge-bps` | SteppedTrancheLaunch.initializeCurve does not cap antiSnipeSurchargeBps or surchargeToKingPotBps at 10_000 |
| **`SA-27`** | `[x]` | `[95]` | 1/2 runs (Pass 2) (10/12 agents) | `SteppedTrancheLaunch.sell` | `steppedtranchelaunch|sell|base-price-redemption-locks-step-quote` | SteppedTrancheLaunch.sell caps redemptions at basePriceQ96 and locks higher-tranche quote deposits in stalled launches |
| **`SA-28`** | `[x]` | `[95]` | 1/2 runs (Pass 2) (10/12 agents) | `SwapRewardsBlock._accrueSwapRewards` | `swaprewardsblock|accrue|unnormalized-unspecified-currency-volume` | SwapRewardsBlock._accrueSwapRewards uses raw unspecified currency units and inflates points on token-side swaps |
| **`SA-29`** | `[x]` | `[95]` | 2/2 runs (11/12 agents) | `TWAMMBlock.submitTWAMMOrder` | `twammblock|submittwammorder|unfunded-unexpiring-twamm-orders` | submitTWAMMOrder collects no tokens and executePending never subtracts expired order sell rates |
| **`SA-30`** | `[x]` | `[95]` | 2/2 runs (11/12 agents) | `VestingSellCapBlock.enforceSellCap` | `vestingsellcapblock|enforcesellcap|pre-settlement-balance-double-count` | enforceSellCap adds tokensSold to balanceOf(seller) before PoolManager settles input tokens |
| **`SA-31`** | `[x]` | `[95]` | 2/2 runs (12/12 agents) | `VirtualXYKLaunch.buy` | `virtualxyklaunch|buy|unrefunded-quote-on-token-allocation-cap` | VirtualXYKLaunch.buy caps tokensOut at remainingCurveTokens without reducing quoteUsed |
| **`SA-32`** | `[x]` | `[95]` | 2/2 runs (12/12 agents) | `VirtualXYKLaunch._graduateToV4` | `virtualxyklaunch|graduatetov4|sqrt-price-muldiv-overflow` | _graduateToV4 overflows Math.mulDiv when tokensToSeed / quoteToSeed reaches 2^64 |
| **`SA-33`** | `[x]` | `[95]` | 1/2 runs (Pass 2) (3/12 agents) | `VirtualXYKLaunch.sell` | `virtualxyklaunch|sell|invariant-k-desync-on-clamped-sell` | VirtualXYKLaunch.sell increases virtualTokenReserve above invariantK when quoteOut clamps at realQuoteRaised |
| **`SA-34`** | `[x]` | `[95]` | 2/2 runs (11/12 agents) | `WalletCapBlock._enforceWalletCapAfterBuy` | `walletcapblock|enforcewalletcapafterbuy|flash-accounting-wallet-cap-bypass` | enforceAfterBuy reads token.balanceOf(recipient) before PoolManager settles swap outputs |
| **`SA-35`** | `[x]` | `[90]` | 1/2 runs (Pass 2) (2/12 agents) | `AutoBurnBlock._executeAutoBurn` | `autoburnblock|execute|non-burnable-token-buy-dos` | AutoBurnLogic.execute calls ERC20Burnable.burn without fallback and bricks exact-input buys on standard ERC-20 tokens |
| **`SA-36`** | `[x]` | `[85]` | 1/2 runs (Pass 2) (1/12 agents) | `HoodiSwapRouter.swap` | `hoodiswaprouter|swap|unrefunded-native-eth-and-reentrant-sender` | HoodiSwapRouter.swap retains excess msg.value on exact-output ETH swaps and leaves it drainable by the next caller |

### 6.2 Detailed Root Causes & Minimal Code Fixes (`SA-01`–`SA-36`)

#### `SA-01` `[95]` — AccessControlLogic.verifyAccess requires hookData.length >= 64 and rejects single-leaf Merkle trees
- **Location**: `AccessControlBlock._verifyAccess` · **Ledger Key**: `accesscontrolblock|verifyaccess|single-leaf-merkle-proof-rejection` · **Coverage**: `1/2 runs (Pass 2)` (`5/12` agents in Pass 2)
- **Description**: `AccessControlLogic.verifyAccess` requires at least 64 bytes of `hookData`, so a single-leaf Merkle allowlist with an empty proof always reverts.
- **Fix**:
```diff
--- a/src/blocks/protection/AccessControlBlock.sol
+++ b/src/blocks/protection/AccessControlBlock.sol
@@ -26,7 +26,7 @@ library AccessControlLogic {
         bytes32 root = cfg.merkleRoot;
-        if (root != bytes32(0) && hookData.length >= 64) {
+        if (root != bytes32(0) && hookData.length >= 32) {
             bytes32 computedHash = keccak256(bytes.concat(keccak256(abi.encode(user))));
```

#### `SA-02` `[95]` — A buyer who submits an exact-output swap skips AutoBurnBlock and KingOfThePoolBlock fees
- **Location**: `AfterSwapDeltaAggregator._executeAfterSwapDeltaWaterfall` · **Ledger Key**: `afterswapdeltaaggregator|executeafterswapdeltawaterfall|exact-output-buy-fee-bypass` · **Coverage**: `2/2 runs` (`11/12` agents in Pass 2)
- **Description**: A buyer who submits an exact-output swap skips `AutoBurnBlock` and `KingOfThePoolBlock` fees because `unspecifiedCurrency` is the quote token.
- **Fix**:
```diff
--- a/src/base/AfterSwapDeltaAggregator.sol
+++ b/src/base/AfterSwapDeltaAggregator.sol
@@ -119,6 +119,5 @@ abstract contract AfterSwapDeltaAggregator is
         if (
-            (bitmap & HookPermissionMasks.BIT_AUTO_BURN) != 0 && ctx.isBuy
-                && ctx.unspecifiedCurrency == ctx.projectCurrency
+            (bitmap & HookPermissionMasks.BIT_AUTO_BURN) != 0 && ctx.isBuy
         ) {
             uint16 burnBps = _getAutoBurnBps(poolId, true);
```

#### `SA-03` `[95]` — _validateAggregateReturnDeltaBudget omits BIT_ARB_RECAPTURE and counts zero-liquidity LP donations against the cap
- **Location**: `AfterSwapDeltaAggregator._validateAggregateReturnDeltaBudget` · **Ledger Key**: `afterswapdeltaaggregator|validateaggregatereturndeltabudget|arb-recapture-budget-starvation` · **Coverage**: `2/2 runs` (`11/12` agents in Pass 2)
- **Description**: When post-swap liquidity is zero, `ArbRecapture` and `LPRewards` fill `maxAllowedTotalCut` before `totalCutAmount` drops `lpDonationAmount`, so later fee blocks get zero cut.
- **Fix**:
```diff
--- a/src/base/AfterSwapDeltaAggregator.sol
+++ b/src/base/AfterSwapDeltaAggregator.sol
@@ -50,4 +50,7 @@ abstract contract AfterSwapDeltaAggregator is
         uint256 maxBuyBps;
         uint256 maxSellBps;
+        if ((b & HookPermissionMasks.BIT_ARB_RECAPTURE) != 0) {
+            maxBuyBps += MAX_ARB_EFFECTIVE_CUT_BPS;
+            maxSellBps += MAX_ARB_EFFECTIVE_CUT_BPS;
+        }
```

#### `SA-04` `[95]` — computeCutBps reads state.referenceTick before it updates referenceTick for a new block
- **Location**: `ArbRecaptureBlock.computeCutBps` · **Ledger Key**: `arbrecaptureblock|computecutbps|stale-reference-tick-order` · **Coverage**: `2/2 runs` (`11/12` agents in Pass 2)
- **Description**: `computeCutBps` updates `state.referenceTick` after it reads `refTick`, so the first swap in the next block pays up to 10% extra fee.
- **Fix**:
```diff
--- a/src/blocks/protection/ArbRecaptureBlock.sol
+++ b/src/blocks/protection/ArbRecaptureBlock.sol
@@ -43,11 +43,10 @@ library ArbRecaptureLogic {
+        if (block.number > state.lastUpdatedBlock) {
+            state.referenceTick = preSwapTick;
+            state.lastUpdatedBlock = uint32(block.number);
+        }
         int24 refTick = state.referenceTick;
         int24 swapTickMoved = postSwapTick >= preSwapTick ? postSwapTick - preSwapTick : preSwapTick - postSwapTick;
         int24 refTickMoved = postSwapTick >= refTick ? postSwapTick - refTick : refTick - postSwapTick;
         int24 tickMoved = refTickMoved > swapTickMoved ? refTickMoved : swapTickMoved;
-
-        if (block.number > state.lastUpdatedBlock) {
-            state.referenceTick = preSwapTick;
-            state.lastUpdatedBlock = uint32(block.number);
-        }
```

#### `SA-05` `[95]` — accumulateAndCheckTrigger checks postSwapTick <= triggerFloorTick even when projectToken is currency1
- **Location**: `AutoBuybackBlock._processAutoBuyback` · **Ledger Key**: `autobuybackblock|processautobuyback|inverted-floor-tick-and-threshold-mismatch` · **Coverage**: `2/2 runs` (`10/12` agents in Pass 2)
- **Description**: The `accumulateAndCheckTrigger` function checks `postSwapTick <= triggerFloorTick` even when the project token is `currency1`, where price drops move the tick up instead of down.
- **Fix**:
```diff
--- a/src/blocks/rewards/AutoBuybackBlock.sol
+++ b/src/blocks/rewards/AutoBuybackBlock.sol
@@ -66,4 +66,5 @@ library AutoBuybackLogic {
         if (
-            hasActiveLiquidity && st.minBuybackReserve > 0 && newReserve >= st.minBuybackReserve
-                && postSwapTick <= st.triggerFloorTick
+            hasActiveLiquidity && st.minBuybackReserve > 0 && newReserve >= st.minBuybackReserve
+                && (isToken0ProjectToken ? postSwapTick <= st.triggerFloorTick : postSwapTick >= st.triggerFloorTick)
         ) {
```

#### `SA-06` `[95]` — HookRigOrchestrator exposes no external function for _updateBuySellTax and update rejects zero newRecipient
- **Location**: `BuySellTaxBlock._updateBuySellTax` · **Ledger Key**: `buyselltaxblock|updatebuyselltax|unreachable-tax-update-and-recipient-check` · **Coverage**: `2/2 runs` (`10/12` agents in Pass 2)
- **Description**: The pool admin cannot lower taxes in `BuySellTaxBlock`, because `HookRigOrchestrator` exposes no external function for `_updateBuySellTax` and `BuySellTaxLogic.update` rejects a zero `newRecipient`.
- **Fix**:
```diff
--- a/src/blocks/token-rules/BuySellTaxBlock.sol
+++ b/src/blocks/token-rules/BuySellTaxBlock.sol
@@ -46,3 +46,3 @@ library BuySellTaxLogic {
-        if ((newBuyTaxBps > 0 || newSellTaxBps > cfg.sellTaxBps) && newRecipient == address(0)) {
+        if ((newBuyTaxBps > 0 || newSellTaxBps > 0) && newRecipient == address(0) && cfg.taxRecipient == address(0)) {
             revert InvalidTaxRecipient();
```

#### `SA-07` `[95]` — CircuitBreakerLogic.checkAndAdvance anchors new windows to preSwapTick and lets an attacker lock out one swap direction
- **Location**: `CircuitBreakerBlock._checkAndAdvanceCircuitBreaker` · **Ledger Key**: `circuitbreakerblock|checkandadvance|window-rollover-anchor-tick-manipulation` · **Coverage**: `1/2 runs (Pass 2)` (`3/12` agents in Pass 2)
- **Description**: An attacker swaps to the band edge before window expiry and unwinds in the new window to lock `anchorTick` and block sells.
- **Fix**:
```diff
--- a/src/blocks/protection/CircuitBreakerBlock.sol
+++ b/src/blocks/protection/CircuitBreakerBlock.sol
@@ -30,7 +30,7 @@ library CircuitBreakerLogic {
         if (block.timestamp >= uint256(cb.windowStartTimestamp) + uint256(cb.windowSeconds)) {
-            cb.anchorTick = preSwapTick;
+            cb.anchorTick = postSwapTick;
             cb.windowStartTimestamp = uint64(block.timestamp);
         }
```

#### `SA-08` `[95]` — DynamicFeeLogic.compute reads preSwapTick before the swap moves the price and spikes intra-block volatility without EMA damping
- **Location**: `DynamicFeeBlock._computeDynamicFee` · **Ledger Key**: `dynamicfeeblock|compute|pre-swap-tick-volatility-lag-and-intra-block-spike` · **Coverage**: `1/2 runs (Pass 2)` (`8/12` agents in Pass 2)
- **Description**: A whale who executes the first swap in a block pays `baseFee` on a large tick move and shifts `maxFee` onto subsequent traders.
- **Fix**:
```diff
--- a/src/blocks/fees/DynamicFeeBlock.sol
+++ b/src/blocks/fees/DynamicFeeBlock.sol
@@ -43,7 +43,7 @@ library DynamicFeeLogic {
             state.lastObservedTick = currentTick;
             state.lastUpdateBlock = uint32(block.number);
         } else if (absDelta > state.rollingVolatilityTicks) {
-            state.rollingVolatilityTicks = absDelta;
+            state.rollingVolatilityTicks = (state.rollingVolatilityTicks * 3 + absDelta) / 4;
         }
```

#### `SA-09` `[95]` — permissionsForBitmap omits callback flags for beforeInitialize, afterInitialize, beforeSwap, and afterSwap
- **Location**: `HookPermissionMasks.permissionsForBitmap` · **Ledger Key**: `hookpermissionmasks|permissionsforbitmap|missing-hook-permission-flags` · **Coverage**: `2/2 runs` (`11/12` agents in Pass 2)
- **Description**: `permissionsForBitmap` omits callback flags, so an attacker can initialize launchpad pools early on preset hooks and make graduation fail forever.
- **Fix**:
```diff
--- a/src/libraries/HookPermissionMasks.sol
+++ b/src/libraries/HookPermissionMasks.sol
@@ -121,11 +121,13 @@ library HookPermissionMasks {
-        perms.beforeInitialize = (bitmap & BIT_TWAMM) != 0;
+        perms.beforeInitialize = true;
         perms.afterInitialize =
             (bitmap
                         & (BIT_DYNAMIC_FEE
                             | BIT_MANAGED_FEE
                             | BIT_MARKET_HOURS_FEE
                             | BIT_ANTI_SNIPE
                             | BIT_LIMIT_ORDERS
-                            | BIT_ORACLE)) != 0;
+                            | BIT_ORACLE
+                            | BIT_ARB_RECAPTURE
+                            | BIT_TWAMM)) != 0;
@@ -149,7 +151,8 @@ library HookPermissionMasks {
         perms.afterSwap =
             (bitmap
                         & (AFTER_SWAP_RETURN_DELTA_BLOCKS_MASK
                             | BIT_MEV_PROTECTION
                             | BIT_WALLET_CAP
+                            | BIT_VESTING_SELL_CAP
                             | BIT_SWAP_REWARDS
                             | BIT_LIMIT_ORDERS
                             | BIT_CIRCUIT_BREAKER)) != 0;
```

#### `SA-10` `[95]` — An attacker passes a chosen address in hookData from an untrusted router to bypass access and cap rules
- **Location**: `HookRigBase._resolveUser` · **Ledger Key**: `hookrigbase|resolveuser|untrusted-hookdata-user-spoofing` · **Coverage**: `2/2 runs` (`11/12` agents in Pass 2)
- **Description**: An attacker passes a chosen address in `hookData` from an untrusted router, so `_resolveUser` returns that address and bypasses access and cap rules.
- **Fix**:
```diff
--- a/src/base/HookRigBase.sol
+++ b/src/base/HookRigBase.sol
@@ -70,11 +70,11 @@ abstract contract HookRigBase is IUnlockCallback {
         if (isTrustedRouter[routerSender]) {
             try IMsgSender(routerSender).msgSender() returns (address resolved) {
                 if (resolved != address(0)) return resolved;
             } catch {}
+            if (hookData.length >= 32) {
+                user = abi.decode(hookData[:32], (address));
+                if (user != address(0)) return user;
+            }
         }
-        if (hookData.length >= 32) {
-            user = abi.decode(hookData[:32], (address));
-            if (user != address(0)) return user;
-        }
         return routerSender;
     }
```

#### `SA-11` `[95]` — _beforeAddLiquidity enforces AccessControlBlock on authorizedCurve and blocks graduation liquidity
- **Location**: `HookRigOrchestrator._beforeAddLiquidity` · **Ledger Key**: `hookrigorchestrator|beforeaddliquidity|missing-authorized-curve-exemption` · **Coverage**: `2/2 runs` (`11/12` agents in Pass 2)
- **Description**: `_beforeAddLiquidity` checks `AccessControlBlock` even when `sender` is `authorizedCurve`, so a launch curve with access control fails when it adds liquidity.
- **Fix**:
```diff
--- a/src/HookRigOrchestrator.sol
+++ b/src/HookRigOrchestrator.sol
@@ -262,4 +262,4 @@ contract HookRigOrchestrator is
-        if ((bitmap & HookPermissionMasks.BIT_ACCESS_CONTROL) != 0) {
+        if ((bitmap & HookPermissionMasks.BIT_ACCESS_CONTROL) != 0 && sender != _poolMeta[poolId].authorizedCurve) {
             _verifyAccess(poolId, user, hookData, true);
         }
```

#### `SA-12` `[95]` — notifyPoolGraduated resets AntiSnipeBlock startBlock but leaves WalletCapBlock and KingOfThePoolBlock clocks unreset
- **Location**: `HookRigOrchestrator.notifyPoolGraduated` · **Ledger Key**: `hookrigorchestrator|notifypoolgraduated|unreset-graduation-clocks` · **Coverage**: `2/2 runs` (`9/12` agents in Pass 2)
- **Description**: A buyer after launchpad graduation can bypass `WalletCapBlock` and trade in an expired `KingOfThePoolBlock` round, because `notifyPoolGraduated` resets only `AntiSnipeBlock`.
- **Fix**:
```diff
--- a/src/HookRigOrchestrator.sol
+++ b/src/HookRigOrchestrator.sol
@@ -98,4 +98,7 @@ contract HookRigOrchestrator is
         if ((_poolMeta[poolId].enabledBlocksBitmap & HookPermissionMasks.BIT_ANTI_SNIPE) != 0) {
             _antiSnipeStates[poolId].startBlock = uint32(block.number);
         }
+        if ((_poolMeta[poolId].enabledBlocksBitmap & HookPermissionMasks.BIT_WALLET_CAP) != 0) {
+            _walletCapStates[poolId].startBlock = uint32(block.number);
+        }
```

#### `SA-13` `[95]` — An attacker can front-run registerPoolStack or PoolManager.initialize to take control or block graduation
- **Location**: `HookRigOrchestrator.registerPoolStack` · **Ledger Key**: `hookrigorchestrator|registerpoolstack|unguarded-pool-registration-and-init` · **Coverage**: `2/2 runs` (`11/12` agents in Pass 2)
- **Description**: An attacker calls `registerPoolStack` or `initialize` before a launch, so the attacker takes control of the pool settings or makes graduation fail.
- **Fix**:
```diff
--- a/src/HookRigOrchestrator.sol
+++ b/src/HookRigOrchestrator.sol
@@ -80,8 +80,10 @@ contract HookRigOrchestrator is
     function registerPoolStack(PoolKey calldata key, PoolStackConfig calldata config) external override {
         PoolId poolId = key.toId();
         if (_poolMeta[poolId].configured) revert PoolAlreadyConfigured(poolId);
+        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
+        require(sqrtPriceX96 == 0, "PoolAlreadyInitialized");
         bool isLaunchpad = config.authorizedCurve != address(0);
-        if (isLaunchpad && msg.sender != launchpadFactory) {
+        if (msg.sender != launchpadFactory && msg.sender != config.poolAdmin) {
             revert OnlyLaunchpadFactory(msg.sender);
         }
```

#### `SA-14` `[95]` — HookRigOrchestrator._runAfterSwapPipeline uses params.amountSpecified instead of settled swapDelta on partial fills
- **Location**: `HookRigOrchestrator._runAfterSwapPipeline` · **Ledger Key**: `hookrigorchestrator|runafterswappipeline|partial-fill-amount-specified-overcount` · **Coverage**: `1/2 runs (Pass 2)` (`5/12` agents in Pass 2)
- **Description**: A partial swap stopped by `sqrtPriceLimitX96` passes the full `params.amountSpecified` to `VestingSellCapBlock` and `WalletCapBlock`, which overcounts the trade.
- **Fix**:
```diff
--- a/src/HookRigOrchestrator.sol
+++ b/src/HookRigOrchestrator.sol
@@ -384,7 +384,8 @@ contract HookRigOrchestrator is
         if ((bitmap & HookPermissionMasks.BIT_VESTING_SELL_CAP) != 0 && !ctx.isBuy) {
-            uint256 projectTokensSold =
-                ctx.isExactInput ? uint256(-params.amountSpecified) : ctx.grossUnspecifiedAmount;
+            int128 specDelta = ctx.isToken0ProjectToken ? swapDelta.amount0() : swapDelta.amount1();
+            uint256 projectTokensSold = specDelta < 0 ? uint256(uint128(-specDelta)) : ctx.grossUnspecifiedAmount;
             _enforceVestingSellCap(poolId, ctx.projectCurrency, ctx.trader, projectTokensSold);
         }
```

#### `SA-15` `[95]` — HookRigOrchestrator.seedKingPotFromLaunchCurve diverts buyer anti-snipe surcharges to poolAdmin when KingOfThePoolBlock is disabled
- **Location**: `HookRigOrchestrator.seedKingPotFromLaunchCurve` · **Ledger Key**: `hookrigorchestrator|seedkingpotfromlaunchcurve|creator-surcharge-claim-diversion` · **Coverage**: `1/2 runs (Pass 2)` (`3/12` agents in Pass 2)
- **Description**: A token creator who disables `KingOfThePoolBlock` on a stepped tranche launch receives the buyer anti-snipe surcharges in `poolClaims`.
- **Fix**:
```diff
--- a/src/launchpad/curves/SteppedTrancheLaunch.sol
+++ b/src/launchpad/curves/SteppedTrancheLaunch.sol
@@ -66,6 +66,7 @@ contract SteppedTrancheLaunch is ITokenLaunchpad, IUnlockCallback, ReentrancyGua
         if (_config.numTranches == 0 || _config.curveTokenAllocation == 0 || _config.graduationQuoteTarget == 0) {
             revert InvalidTrancheParameters();
         }
+        require(_config.basePriceQ96 > 0 && _config.antiSnipeSurchargeBps < 10_000 && _config.surchargeToKingPotBps <= 10_000, "InvalidConfig");
```

#### `SA-16` `[95]` — JITGuardLogic.recordAddition keys positions by _resolveUser and overwrites lpAddedBlock on any 1-wei addition
- **Location**: `JITGuardBlock._recordLPAddition` · **Ledger Key**: `jitguardblock|recordaddition|position-owner-mismatch-and-cooldown-reset` · **Coverage**: `1/2 runs (Pass 2)` (`11/12` agents in Pass 2)
- **Description**: An attacker passes a different or victim address in `hookData` during `modifyLiquidity` to bypass the hold period or reset a victim cooldown timer.
- **Fix**:
```diff
--- a/src/blocks/protection/JITGuardBlock.sol
+++ b/src/blocks/protection/JITGuardBlock.sol
@@ -26,7 +26,9 @@ library JITGuardLogic {
         ModifyLiquidityParams calldata params
     ) external {
         bytes32 posKey = keccak256(abi.encodePacked(lpOwner, params.tickLower, params.tickUpper, params.salt));
-        lpAddedBlock[poolId][posKey] = uint32(block.number);
+        if (lpAddedBlock[poolId][posKey] == 0) {
+            lpAddedBlock[poolId][posKey] = uint32(block.number);
+        }
     }
```

#### `SA-17` `[95]` — processBuy overwrites potCurrency from currency0 to currency1 and sums both currencies into currentPotAmount
- **Location**: `KingOfThePoolBlock.processBuy` · **Ledger Key**: `kingofthepoolblock|processbuy|mixed-currency-pot-accounting` · **Coverage**: `2/2 runs` (`12/12` agents in Pass 2)
- **Description**: A post-graduation buy overwrites `potCurrency` from `currency0` to `currency1` while `currentPotAmount` holds `currency0`, so `claimKingPot` fails for the round winner.
- **Fix**:
```diff
--- a/src/blocks/rewards/KingOfThePoolBlock.sol
+++ b/src/blocks/rewards/KingOfThePoolBlock.sol
@@ -88,5 +88,8 @@ library KingOfThePoolLogic {
         if (potContribution > 0) {
-            state.potCurrency = cutCurrency;
+            if (state.currentPotAmount == 0) {
+                state.potCurrency = cutCurrency;
+            }
+            require(Currency.unwrap(state.potCurrency) == Currency.unwrap(cutCurrency), "CurrencyMismatch");
             state.currentPotAmount += potContribution;
         }
```

#### `SA-18` `[95]` — _deployTokenAndVest allows pre-graduation vested token dumps and unvalidated curve supply allocations
- **Location**: `LaunchpadFactory._deployTokenAndVest` · **Ledger Key**: `launchpadfactory|deploytokenandvest|pre-graduation-creator-vesting-and-supply-mismatch` · **Coverage**: `2/2 runs` (`11/12` agents in Pass 2)
- **Description**: A creator releases vested tokens during the bonding phase and sells them into the curve to take buyer quote tokens, or sets allocations above post-vesting supply.
- **Fix**:
```diff
--- a/src/launchpad/LaunchpadFactory.sol
+++ b/src/launchpad/LaunchpadFactory.sol
@@ -198,6 +198,7 @@ contract LaunchpadFactory is ILaunchpadFactory {
         if (meta.creatorVestingBps > 0 && meta.creator != address(0)) {
             vestingAmount = Math.mulDiv(meta.totalSupply, meta.creatorVestingBps, 10_000, Math.Rounding.Floor);
+            uint64 duration = meta.vestingDurationSeconds >= 30 days ? meta.vestingDurationSeconds : 180 days;
             VestingWallet vest = new VestingWallet(
                 meta.creator,
                 uint64(block.timestamp),
-                meta.vestingDurationSeconds > 0 ? meta.vestingDurationSeconds : 180 days
+                duration
             );
```

#### `SA-19` `[95]` — Launch curves call notifyPoolGraduated on immutable hookOrchestrator instead of poolKey.hooks
- **Location**: `LaunchpadFactory.launchVirtualXYK` · **Ledger Key**: `launchpadfactory|launchvirtualxyk|immutable-orchestrator-mismatch` · **Coverage**: `2/2 runs` (`12/12` agents in Pass 2)
- **Description**: The launch curves call `notifyPoolGraduated` on the immutable `hookOrchestrator` instead of `poolKey.hooks`, so any launch that uses a preset hook fails at graduation.
- **Fix**:
```diff
--- a/src/launchpad/curves/VirtualXYKLaunch.sol
+++ b/src/launchpad/curves/VirtualXYKLaunch.sol
@@ -197,3 +197,3 @@ contract VirtualXYKLaunch is IVirtualXYKLaunch, IUnlockCallback, ReentrancyGuard
         poolManager.initialize(poolKey, graduationSqrtPriceX96);
-        hookOrchestrator.notifyPoolGraduated(poolId);
+        IHookRigOrchestrator(address(poolKey.hooks)).notifyPoolGraduated(poolId);
```

#### `SA-20` `[95]` — placeOrder collects no ETH when inputCurrency is address zero and lets callers drain contract ETH
- **Location**: `LimitOrdersBlock.placeLimitOrder` · **Ledger Key**: `limitordersblock|placelimitorder|unfunded-native-limit-order-drain` · **Coverage**: `2/2 runs` (`12/12` agents in Pass 2)
- **Description**: `placeOrder` accepts a native ETH order without ETH payment, so any caller can place and cancel an order to take all ETH.
- **Fix**:
```diff
--- a/src/blocks/trading/LimitOrdersBlock.sol
+++ b/src/blocks/trading/LimitOrdersBlock.sol
@@ -61,4 +61,7 @@ library LimitOrdersLogic {
         Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
         if (!inputCurrency.isAddressZero()) {
+            require(msg.value == 0, "UnexpectedETH");
             IERC20(Currency.unwrap(inputCurrency)).safeTransferFrom(msg.sender, address(this), inputAmount);
+        } else {
+            require(msg.value == inputAmount, "InsufficientETH");
         }
```

#### `SA-21` `[95]` — processCrossedTicks truncates toward zero, skips ticks past 16 steps, and never resets bucket.filled
- **Location**: `LimitOrdersBlock.processCrossedTicks` · **Ledger Key**: `limitordersblock|processcrossedticks|signed-tick-division-and-sticky-bucket` · **Coverage**: `2/2 runs` (`11/12` agents in Pass 2)
- **Description**: A swap in `LimitOrdersBlock` fills uncrossed ticks near zero and skips ticks past 16 steps, because `processCrossedTicks` truncates toward zero and overwrites `lastTicks`.
- **Fix**:
```diff
--- a/src/blocks/trading/LimitOrdersBlock.sol
+++ b/src/blocks/trading/LimitOrdersBlock.sol
@@ -91,6 +91,9 @@ library LimitOrdersLogic {
         bucket.totalInputAmount -= order.inputAmount;
+        if (bucket.totalInputAmount == 0) {
+            bucket.filled = false;
+        }
@@ -137,8 +140,9 @@ library LimitOrdersLogic {
         bool movedUp = postSwapTick > prevTick;
         uint256 stepsChecked;
+        int24 lastInspectedTick = prevTick;
         if (movedUp) {
-            int24 aligned = (prevTick / step) * step;
-            for (int24 t = aligned; t <= postSwapTick && stepsChecked < MAX_TICK_FILLS_PER_SWAP; t += step) {
+            int24 aligned = prevTick >= 0 ? ((prevTick / step) + 1) * step : (prevTick / step) * step;
+            for (int24 t = aligned; t <= postSwapTick && stepsChecked < MAX_TICK_FILLS_PER_SWAP; t += step) {
                 stepsChecked++;
+                lastInspectedTick = t;
```

#### `SA-22` `[95]` — MEVProtectionLogic.enforceAfterSwap writes lastSwapBlock and lastSwapZeroForOne without reading them
- **Location**: `MEVProtectionBlock.enforceAfterSwap` · **Ledger Key**: `mevprotectionblock|enforceafterswap|unread-sandwich-tracking-state` · **Coverage**: `2/2 runs` (`9/12` agents in Pass 2)
- **Description**: An attacker can split a large swap or execute a same-block sandwich in `MEVProtectionBlock`, because `enforceAfterSwap` writes `lastSwapBlock` and `lastSwapZeroForOne` but never reads them.
- **Fix**:
```diff
--- a/src/blocks/protection/MEVProtectionBlock.sol
+++ b/src/blocks/protection/MEVProtectionBlock.sol
@@ -45,4 +45,7 @@ library MEVProtectionLogic {
         if (uint24(delta) > state.maxTickDeltaPerSwap) {
             revert ExcessiveSwapPriceImpact(preSwapTick, postSwapTick, state.maxTickDeltaPerSwap);
         }
+        if (state.lastSwapBlock == uint32(block.number) && state.lastSwapZeroForOne != zeroForOne) {
+            revert ExcessiveSwapPriceImpact(preSwapTick, postSwapTick, state.maxTickDeltaPerSwap);
+        }
         state.lastSwapBlock = uint32(block.number);
```

#### `SA-23` `[95]` — NativeTickLaunch.unlockCallback passes bands[i].tokenAmount directly as liquidityDelta
- **Location**: `NativeTickLaunch.unlockCallback` · **Ledger Key**: `nativeticklaunch|unlockcallback|token-amount-used-as-liquidity-delta` · **Coverage**: `2/2 runs` (`12/12` agents in Pass 2)
- **Description**: The callback passes the raw `tokenAmount` directly as `liquidityDelta`, so `PoolManager` deposits the wrong token amount and leaves supply inside the curve contract.
- **Fix**:
```diff
--- a/src/launchpad/curves/NativeTickLaunch.sol
+++ b/src/launchpad/curves/NativeTickLaunch.sol
@@ -74,8 +74,10 @@ contract NativeTickLaunch is INativeTickLaunch, IUnlockCallback, ReentrancyGuard
         for (uint256 i = 0; i < len; i++) {
+            uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(bands[i].tickLower);
+            uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(bands[i].tickUpper);
+            uint128 liq = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLowerX96, sqrtPriceUpperX96, bands[i].tokenAmount);
             (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
                 poolKey,
                 ModifyLiquidityParams({
                     tickLower: bands[i].tickLower,
                     tickUpper: bands[i].tickUpper,
-                    liquidityDelta: int256(uint256(bands[i].tokenAmount)),
+                    liquidityDelta: int256(uint256(liq)),
                     salt: bytes32(i)
                 }),
```

#### `SA-24` `[95]` — updateCheckpoint truncates elapsed * MAX_ORACLE_TICK_DELTA_PER_SEC to int24 and wraps negative
- **Location**: `OracleBlock.updateCheckpoint` · **Ledger Key**: `oracleblock|updatecheckpoint|int24-truncation-overflow` · **Coverage**: `2/2 runs` (`11/12` agents in Pass 2)
- **Description**: After 83,887 seconds without a checkpoint, `int24(maxChange)` overflows and makes every swap, deposit, and withdrawal fail forever.
- **Fix**:
```diff
--- a/src/blocks/trading/OracleBlock.sol
+++ b/src/blocks/trading/OracleBlock.sol
@@ -34,9 +34,9 @@ library OracleLogic {
-        int24 diff = currentTick - obs.lastTick;
-        int24 maxChange = int24(int256(uint256(elapsed)) * int256(MAX_ORACLE_TICK_DELTA_PER_SEC));
+        int256 diff = int256(currentTick) - int256(obs.lastTick);
+        int256 maxChange = int256(uint256(elapsed)) * int256(uint256(MAX_ORACLE_TICK_DELTA_PER_SEC));
         if (diff > maxChange) {
-            currentTick = obs.lastTick + maxChange;
+            currentTick = int24(int256(obs.lastTick) + maxChange);
         } else if (diff < -maxChange) {
-            currentTick = obs.lastTick - maxChange;
+            currentTick = int24(int256(obs.lastTick) - maxChange);
         }
```

#### `SA-25` `[95]` — SteppedTrancheLaunch.buy prices the full order at the current tranche price and skips higher tranches
- **Location**: `SteppedTrancheLaunch.buy` · **Ledger Key**: `steppedtranchelaunch|buy|single-tranche-bulk-buy-pricing` · **Coverage**: `2/2 runs` (`11/12` agents in Pass 2)
- **Description**: `buy` prices the full order at the current tranche price, so one buyer can buy the whole supply at the lowest price.
- **Fix**:
```diff
--- a/src/launchpad/curves/SteppedTrancheLaunch.sol
+++ b/src/launchpad/curves/SteppedTrancheLaunch.sol
@@ -128,8 +128,13 @@ contract SteppedTrancheLaunch is ISteppedTrancheLaunch, IUnlockCallback, Reentr
-        uint256 priceQ96 = currentMarginalPriceQ96();
-        tokensOut = Math.mulDiv(netQuoteForTokens, uint256(1) << 96, priceQ96, Math.Rounding.Floor);
-
-        uint256 remainingTokens = trancheConfig.curveTokenAllocation - curveTokensSold;
-        if (tokensOut > remainingTokens) {
-            tokensOut = remainingTokens;
+        uint256 trSize = trancheConfig.curveTokenAllocation / trancheConfig.numTranches;
+        uint256 trIdx = currentTrancheIndex();
+        uint256 priceQ96 = uint256(trancheConfig.basePriceQ96) + trIdx * uint256(trancheConfig.stepPriceIncrementQ96);
+        uint256 trCap = (trIdx + 1 == trancheConfig.numTranches)
+            ? trancheConfig.curveTokenAllocation - curveTokensSold
+            : ((trIdx + 1) * trSize) - curveTokensSold;
+        tokensOut = Math.mulDiv(netQuoteForTokens, uint256(1) << 96, priceQ96, Math.Rounding.Floor);
+        if (tokensOut > trCap) {
+            tokensOut = trCap;
         }
```

#### `SA-26` `[95]` — SteppedTrancheLaunch.initializeCurve does not cap antiSnipeSurchargeBps or surchargeToKingPotBps at 10_000
- **Location**: `SteppedTrancheLaunch.initializeCurve` · **Ledger Key**: `steppedtranchelaunch|initializecurve|unbounded-surcharge-bps` · **Coverage**: `2/2 runs` (`10/12` agents in Pass 2)
- **Description**: A creator sets `antiSnipeSurchargeBps` or `surchargeToKingPotBps` above `10_000`, so surcharge subtraction underflows in `buy` or `_graduateToV4` and locks buyer funds.
- **Fix**:
```diff
--- a/src/launchpad/curves/SteppedTrancheLaunch.sol
+++ b/src/launchpad/curves/SteppedTrancheLaunch.sol
@@ -66,4 +66,6 @@ contract SteppedTrancheLaunch is ISteppedTrancheLaunch, IUnlockCallback, Reentr
         if (_config.numTranches == 0 || _config.curveTokenAllocation == 0) {
             revert InvalidTrancheParameters();
         }
+        require(_config.antiSnipeSurchargeBps < 10_000 && _config.surchargeToKingPotBps <= 10_000, "InvalidSurchargeBps");
         poolKey = _key;
```

#### `SA-27` `[95]` — SteppedTrancheLaunch.sell caps redemptions at basePriceQ96 and locks higher-tranche quote deposits in stalled launches
- **Location**: `SteppedTrancheLaunch.sell` · **Ledger Key**: `steppedtranchelaunch|sell|base-price-redemption-locks-step-quote` · **Coverage**: `1/2 runs (Pass 2)` (`10/12` agents in Pass 2)
- **Description**: A buyer in a higher tranche who calls `sell` receives only `basePriceQ96` per token, so the contract locks the step price premium.
- **Fix**:
```diff
--- a/src/launchpad/curves/SteppedTrancheLaunch.sol
+++ b/src/launchpad/curves/SteppedTrancheLaunch.sol
@@ -177,8 +177,7 @@ contract SteppedTrancheLaunch is ITokenLaunchpad, IUnlockCallback, ReentrancyGua
         if (curveTokensSold == 0 || realQuoteRaised == 0) revert ZeroInput();
-        uint256 baseRedemption =
-            Math.mulDiv(tokenAmountIn, uint256(trancheConfig.basePriceQ96), uint256(1) << 96, Math.Rounding.Floor);
         uint256 proRataCap = Math.mulDiv(realQuoteRaised, tokenAmountIn, curveTokensSold, Math.Rounding.Floor);
-        quoteOut = baseRedemption < proRataCap ? baseRedemption : proRataCap;
+        quoteOut = proRataCap;
```

#### `SA-28` `[95]` — SwapRewardsBlock._accrueSwapRewards uses raw unspecified currency units and inflates points on token-side swaps
- **Location**: `SwapRewardsBlock._accrueSwapRewards` · **Ledger Key**: `swaprewardsblock|accrue|unnormalized-unspecified-currency-volume` · **Coverage**: `1/2 runs (Pass 2)` (`10/12` agents in Pass 2)
- **Description**: A trader who chooses an exact-input buy or exact-output sell earns orders of magnitude more reward points than an equal quote-denominated swap.
- **Fix**:
```diff
--- a/src/HookRigOrchestrator.sol
+++ b/src/HookRigOrchestrator.sol
@@ -391,7 +391,8 @@ contract HookRigOrchestrator is
         if ((bitmap & HookPermissionMasks.BIT_SWAP_REWARDS) != 0) {
-            _accrueSwapRewards(poolId, ctx.trader, ctx.grossUnspecifiedAmount);
+            uint256 quoteVolume = ctx.unspecifiedCurrency == ctx.quoteCurrency ? ctx.grossUnspecifiedAmount : 0;
+            _accrueSwapRewards(poolId, ctx.trader, quoteVolume);
         }
```

#### `SA-29` `[95]` — submitTWAMMOrder collects no tokens and executePending never subtracts expired order sell rates
- **Location**: `TWAMMBlock.submitTWAMMOrder` · **Ledger Key**: `twammblock|submittwammorder|unfunded-unexpiring-twamm-orders` · **Coverage**: `2/2 runs` (`11/12` agents in Pass 2)
- **Description**: Any caller can call `submitTWAMMOrder` with zero token payment, so an attacker sets `sellRate0For1` to `type(uint128).max` for free and makes future orders fail.
- **Fix**:
```diff
--- a/src/blocks/trading/TWAMMBlock.sol
+++ b/src/blocks/trading/TWAMMBlock.sol
@@ -56,6 +56,8 @@ library TWAMMLogic {
         if (totalAmount == 0 || durationSeconds < MIN_TWAMM_DURATION || durationSeconds > MAX_TWAMM_DURATION) {
             revert InvalidTWAMMOrder(totalAmount, durationSeconds);
         }
+        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
+        IERC20(Currency.unwrap(inputCurrency)).safeTransferFrom(msg.sender, address(this), totalAmount);
         PoolId poolId = key.toId();
```

#### `SA-30` `[95]` — enforceSellCap adds tokensSold to balanceOf(seller) before PoolManager settles input tokens
- **Location**: `VestingSellCapBlock.enforceSellCap` · **Ledger Key**: `vestingsellcapblock|enforcesellcap|pre-settlement-balance-double-count` · **Coverage**: `2/2 runs` (`11/12` agents in Pass 2)
- **Description**: `enforceSellCap` adds `tokensSold` to `balanceOf(seller)` before the router settles the input tokens, which counts `tokensSold` twice and lets a seller exceed the daily cap.
- **Fix**:
```diff
--- a/src/blocks/token-rules/VestingSellCapBlock.sol
+++ b/src/blocks/token-rules/VestingSellCapBlock.sol
@@ -52,3 +52,3 @@ library VestingSellCapLogic {
         if (ep.epochIndex != currentEpoch || ep.startOfEpochBalance == 0) {
-            uint256 currentBal = IERC20(Currency.unwrap(projectCurrency)).balanceOf(seller) + tokensSold;
+            uint256 currentBal = IERC20(Currency.unwrap(projectCurrency)).balanceOf(seller);
             ep.epochIndex = currentEpoch;
```

#### `SA-31` `[95]` — VirtualXYKLaunch.buy caps tokensOut at remainingCurveTokens without reducing quoteUsed
- **Location**: `VirtualXYKLaunch.buy` · **Ledger Key**: `virtualxyklaunch|buy|unrefunded-quote-on-token-allocation-cap` · **Coverage**: `2/2 runs` (`12/12` agents in Pass 2)
- **Description**: `buy` caps `tokensOut` at the remaining token allocation without lowering `quoteUsed`, so the last buyer pays the full quote amount for fewer tokens.
- **Fix**:
```diff
--- a/src/launchpad/curves/VirtualXYKLaunch.sol
+++ b/src/launchpad/curves/VirtualXYKLaunch.sol
@@ -108,4 +108,8 @@ contract VirtualXYKLaunch is IVirtualXYKLaunch, IUnlockCallback, ReentrancyGuard
         uint256 remainingCurveTokens = curveConfig.curveTokenAllocation - curveTokensSold;
         if (tokensOut > remainingCurveTokens) {
             tokensOut = remainingCurveTokens;
+            newVirtualToken = virtualTokenReserve - tokensOut;
+            newVirtualQuote = Math.mulDiv(invariantK, 1, newVirtualToken, Math.Rounding.Ceil);
+            quoteUsed = newVirtualQuote - virtualQuoteReserve;
         }
```

#### `SA-32` `[95]` — _graduateToV4 overflows Math.mulDiv when tokensToSeed / quoteToSeed reaches 2^64
- **Location**: `VirtualXYKLaunch._graduateToV4` · **Ledger Key**: `virtualxyklaunch|graduatetov4|sqrt-price-muldiv-overflow` · **Coverage**: `2/2 runs` (`12/12` agents in Pass 2)
- **Description**: `_graduateToV4` overflows `Math.mulDiv` when `tokensToSeed / quoteToSeed` reaches `2^64` on low-decimal quote tokens, so graduation reverts.
- **Fix**:
```diff
--- a/src/launchpad/curves/VirtualXYKLaunch.sol
+++ b/src/launchpad/curves/VirtualXYKLaunch.sol
@@ -191,2 +191,4 @@ contract VirtualXYKLaunch is IVirtualXYKLaunch, IUnlockCallback, ReentrancyGuard
-        uint256 ratioX192 = Math.mulDiv(tokensToSeed, uint256(1) << 192, quoteToSeed, Math.Rounding.Floor);
-        uint160 graduationSqrtPriceX96 = uint160(Math.sqrt(ratioX192));
+        uint160 graduationSqrtPriceX96 = uint160(
+            Math.mulDiv(Math.sqrt(tokensToSeed), uint256(1) << 96, Math.sqrt(quoteToSeed), Math.Rounding.Floor)
+        );
```

#### `SA-33` `[95]` — VirtualXYKLaunch.sell increases virtualTokenReserve above invariantK when quoteOut clamps at realQuoteRaised
- **Location**: `VirtualXYKLaunch.sell` · **Ledger Key**: `virtualxyklaunch|sell|invariant-k-desync-on-clamped-sell` · **Coverage**: `1/2 runs (Pass 2)` (`3/12` agents in Pass 2)
- **Description**: A seller whose payout hits the `realQuoteRaised` cap inflates `virtualTokenReserve` above `invariantK` and buys back the excess tokens for one wei.
- **Fix**:
```diff
--- a/src/launchpad/curves/VirtualXYKLaunch.sol
+++ b/src/launchpad/curves/VirtualXYKLaunch.sol
@@ -160,6 +160,7 @@ contract VirtualXYKLaunch is ITokenLaunchpad, IUnlockCallback, ReentrancyGuard {
         virtualQuoteReserve -= quoteOut;
         virtualTokenReserve = newVirtualToken;
         realQuoteRaised -= quoteOut;
+        invariantK = virtualQuoteReserve * virtualTokenReserve;
```

#### `SA-34` `[95]` — enforceAfterBuy reads token.balanceOf(recipient) before PoolManager settles swap outputs
- **Location**: `WalletCapBlock._enforceWalletCapAfterBuy` · **Ledger Key**: `walletcapblock|enforcewalletcapafterbuy|flash-accounting-wallet-cap-bypass` · **Coverage**: `2/2 runs` (`11/12` agents in Pass 2)
- **Description**: `enforceAfterBuy` reads `token.balanceOf` before `PoolManager` settles tokens, so a buyer who batches swaps in one `unlockCallback` can buy more tokens than `maxAllowed`.
- **Fix**:
```diff
--- a/src/blocks/token-rules/WalletCapBlock.sol
+++ b/src/blocks/token-rules/WalletCapBlock.sol
@@ -57,4 +57,5 @@ library WalletCapLogic {
         uint256 maxAllowed = Math.mulDiv(supply, maxBps, 10_000, Math.Rounding.Floor);
-        uint256 postBalance = token.balanceOf(recipient) + netProjectTokensBought;
+        st.cumulativeBoughtInBlock[block.number][recipient] += netProjectTokensBought;
+        uint256 postBalance = token.balanceOf(recipient) + st.cumulativeBoughtInBlock[block.number][recipient];
         if (postBalance > maxAllowed) {
```

#### `SA-35` `[90]` — AutoBurnLogic.execute calls ERC20Burnable.burn without fallback and bricks exact-input buys on standard ERC-20 tokens
- **Location**: `AutoBurnBlock._executeAutoBurn` · **Ledger Key**: `autoburnblock|execute|non-burnable-token-buy-dos` · **Coverage**: `1/2 runs (Pass 2)` (`2/12` agents in Pass 2)
- **Description**: `AutoBurnLogic.execute` calls `ERC20Burnable.burn` with no fallback, so enabling `useTokenBurnCall` on a standard ERC-20 token makes every exact-input buy revert.
- **Fix**:
```diff
--- a/src/blocks/token-rules/AutoBurnBlock.sol
+++ b/src/blocks/token-rules/AutoBurnBlock.sol
@@ -35,7 +35,9 @@ library AutoBurnLogic {
         if (configs[poolId].useTokenBurnCall && !currency.isAddressZero()) {
             poolManager.take(currency, address(this), burnAmount);
-            ERC20Burnable(Currency.unwrap(currency)).burn(burnAmount);
+            try ERC20Burnable(Currency.unwrap(currency)).burn(burnAmount) {} catch {
+                IERC20(Currency.unwrap(currency)).transfer(DEAD_ADDRESS, burnAmount);
+            }
         } else {
```

#### `SA-36` `[85]` — HoodiSwapRouter.swap retains excess msg.value on exact-output ETH swaps and leaves it drainable by the next caller
- **Location**: `HoodiSwapRouter.swap` · **Ledger Key**: `hoodiswaprouter|swap|unrefunded-native-eth-and-reentrant-sender` · **Coverage**: `1/2 runs (Pass 2)` (`1/12` agents in Pass 2)
- **Description**: `HoodiSwapRouter.swap` retains any excess `msg.value` above `-delta.amount0()`, so an attacker can drain the leftover ETH in a later swap.
- **Fix**:
```diff
--- a/script/HoodiIntegration.s.sol
+++ b/script/HoodiIntegration.s.sol
@@ -62,6 +62,9 @@ contract HoodiSwapRouter is IUnlockCallback, IMsgSender {
         _currentSender = msg.sender;
         bytes memory res = manager.unlock(abi.encode(CallbackData(msg.sender, key, params, hookData)));
         _currentSender = address(0);
+        if (address(this).balance > 0) {
+            payable(msg.sender).transfer(address(this).balance);
+        }
         return abi.decode(res, (BalanceDelta));
     }
```

