# Entry Point Map

> HookRig | 37 entry points | 17 permissionless | 15 role-gated | 5 admin-only

---

## Protocol Flow Paths

### Setup (Owner)

`HookRigOrchestrator(constructor)` → `setLaunchpadFactory()` → `setTrustedRouter()`  ◄── hook address mined to permission flags

### Standard Pool (Anyone)

`registerPoolStack()` → `PoolManager.initialize()` → `_afterInitialize` anchors oracle/TWAMM/limit/dynamic/arb
                       ├─→ `PoolManager.modifyLiquidity()` (LP)  ◄── AccessControl if enabled
                       └─→ `PoolManager.swap()` (Trader)  ◄── liquidity in range
`PoolManager.initialize()` (without registration) → `registerPoolStack()`  ◄── allowed: no initialized check

### Trader Payouts

`[swap above]` → `withdrawClaim()`  ◄── caller is tax/fee/referral recipient with poolClaims > 0
`[swap above]` → [roundDeadline passes] → `finalizeExpiredKingRound()` → `claimKingPot()`  ◄── caller == round.winner
`registerReferrer()` → `[swap above]`  ◄── referral cut credited on referee swaps

### Trading Blocks

`placeLimitOrder()` → `[swap crosses tick]` → `claimLimitOrder()`
                 └─→ `cancelLimitOrder()`  ◄── bucket not yet filled
`submitTWAMMOrder()` → [time passes] → `[swap / addLiquidity]` advances virtual volume

### Launchpad (Creator / Buyers)

`[owner setup above]` → `LaunchpadFactory.launchVirtualXYK|launchSteppedTranche()` → `registerPoolStack()` (factory) → `initializeCurve()`
                       → `Curve.buy()` / `Curve.sell()` → [target reached] → `_graduateToV4()` → `PoolManager.initialize()` → `notifyPoolGraduated()` → `unlockCallback` seeds LP → (Stepped) `seedKingPotFromLaunchCurve()`
`LaunchpadFactory.launchNativeTick()` → `initializeAndSeedNativeTicks()` → `PoolManager.initialize()` → `notifyPoolGraduated()` → seed bands

### Managers

`[registerPoolStack with managedFee.manager]` → `setManagedPoolFee()`
`[registerPoolStack with accessControl.manager]` → `setAllowlistAccount()` / `setAccessMerkleRoot()`

---

## Permissionless

### `HookRigOrchestrator.registerPoolStack()` (non-launchpad branch)

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (any PoolKey, before or after pool initialization) |
| Parameters | key (user-controlled), config (user-controlled; poolAdmin, recipients, managers, bps) |
| Call chain | `→ _configurePoolStackInternal() → DynamicFeeLogic.stage() / ManagedFeeLogic.stage() / ... / AutoBuybackLogic.init()` |
| State modified | `_poolMeta[poolId]`, every enabled block's per-pool config |
| Value flow | None |
| Reentrancy guard | no |

### `PoolManager.swap()` → `HookRigOrchestrator.beforeSwap/afterSwap`

| Aspect | Detail |
|--------|--------|
| Visibility | external (PoolManager-routed; hook callback `onlyPoolManager`) |
| Caller | Trader via router |
| Parameters | key, params (user-controlled), hookData (user-controlled → `_resolveUser`, merkle proof) |
| Call chain | `→ AccessControlLogic.verifyAccess() → OracleLogic.updateCheckpoint() → TWAMMLogic.executePending() → FeeAggregator._resolveBeforeSwapFee()` ; `→ MEVProtectionLogic.enforceAfterSwap() → CircuitBreakerLogic.checkAndAdvance() → AfterSwapDeltaAggregator._executeAfterSwapDeltaWaterfall() → WalletCapLogic / VestingSellCapLogic / SwapRewardsLogic / LimitOrdersLogic.processCrossedTicks()` |
| State modified | poolClaims, `_kingStates`, `_autoBuybackStates.reserveByCurrency`, `totalAutoBurnedByPool`, `totalLPRewardsDonated`, fee/arb/MEV/CB/oracle/TWAMM/limit state, swap points |
| Value flow | Hook withholds ≤25% of unspecified amount → ERC-6909 mint / take-to-burn / donate |
| Reentrancy guard | no (PoolManager lock) |

### `PoolManager.modifyLiquidity()` → `beforeAddLiquidity / beforeRemoveLiquidity`

| Aspect | Detail |
|--------|--------|
| Visibility | external (PoolManager-routed) |
| Caller | LP via router |
| Parameters | params (user-controlled), hookData (user-controlled → resolved LP owner) |
| Call chain | `→ AccessControlLogic.verifyAccess() (add only) → OracleLogic.updateCheckpoint() → TWAMMLogic.executePending() → JITGuardLogic.recordAddition() / enforceOnRemove()` |
| State modified | `_lpAddedBlock`, oracle, TWAMM |
| Value flow | None through hook |
| Reentrancy guard | no |

### `PoolManager.initialize()` → `beforeInitialize / afterInitialize`

| Aspect | Detail |
|--------|--------|
| Visibility | external (PoolManager-routed) |
| Caller | Anyone (launchpad pools: curve/factory only) |
| Parameters | key, sqrtPriceX96 (user-controlled) |
| Call chain | `→ _validateTWAMMBeforeInitialize() → _initOracle() / _initTWAMM() / _initLimitOrders() / _anchorDynamicFeeTick() / _applyInitialManagedFee() → PoolManager.updateDynamicLPFee()` |
| State modified | oracle, TWAMM, limit last tick, dynamic/arb anchors |
| Value flow | None |
| Reentrancy guard | no |

### `HookRigBase.withdrawClaim()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Claim holder (tax/fee/referral recipients, poolAdmin) |
| Parameters | poolId, currency, amount, to (user-controlled) |
| Call chain | `→ _payoutERC6909Claim() → PoolManager.unlock() → unlockCallback() → PoolManager.burn() → PoolManager.take()` |
| State modified | `poolClaims[poolId][currency][msg.sender]` |
| Value flow | Hook ERC-6909 → `to` |
| Reentrancy guard | yes |

### `VirtualXYKLaunch.buy()` / `SteppedTrancheLaunch.buy()`

| Aspect | Detail |
|--------|--------|
| Visibility | external payable, nonReentrant |
| Caller | Buyer |
| Parameters | quoteAmountIn, minTokensOut, recipient (user-controlled) |
| Call chain | `→ IERC20.safeTransferFrom() → IERC20.safeTransfer(token) → _graduateToV4() → PoolManager.initialize() → HookRigOrchestrator.notifyPoolGraduated() → PoolManager.unlock() → modifyLiquidity → (Stepped) seedKingPotFromLaunchCurve()` |
| State modified | virtual reserves / realQuoteRaised / curveTokensSold / totalSurchargeCollected / launchState |
| Value flow | Quote: buyer → curve; tokens: curve → recipient; ETH refund |
| Reentrancy guard | yes |

### `VirtualXYKLaunch.sell()` / `SteppedTrancheLaunch.sell()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Token holder (any source, incl. vesting) |
| Parameters | tokenAmountIn, minQuoteOut, recipient (user-controlled) |
| Call chain | `→ IERC20.safeTransferFrom(token) → Currency.transfer(quote)` |
| State modified | virtual reserves / realQuoteRaised / curveTokensSold |
| Value flow | Tokens: seller → curve; quote: curve → recipient |
| Reentrancy guard | yes |

### `LaunchpadFactory.launchVirtualXYK() / launchSteppedTranche() / launchNativeTick()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (creator param arbitrary) |
| Parameters | meta, quoteCurrency, tickSpacing, hookContract, stackConfig, curve config, salt (user-controlled) |
| Call chain | `→ Clones.clone() → new HookRigToken{salt} → new VestingWallet → hookContract.registerPoolStack() → Curve.initializeCurve() / initializeAndSeedNativeTicks()` |
| State modified | `tokenToCurve`, `tokenToCreatorVesting`, `totalLaunches` |
| Value flow | Minted supply → vesting wallet + curve |
| Reentrancy guard | no |

### `KingOfThePoolBlock.finalizeExpiredKingRound()`

| Aspect | Detail |
|--------|--------|
| Visibility | public |
| Caller | Anyone |
| Parameters | poolId (user-controlled) |
| Call chain | `→ KingOfThePoolLogic.finalizeExpired() → _rollKingRound()` |
| State modified | `_kingStates`, `_settledKingRounds` |
| Value flow | None |
| Reentrancy guard | no |

### `ReferralSplitBlock.registerReferrer()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Trader |
| Parameters | poolId, referrer (user-controlled) |
| Call chain | `→ ReferralSplitLogic.register()` |
| State modified | `traderReferrer[poolId][msg.sender]` (first-touch) |
| Value flow | None |
| Reentrancy guard | no |

### `LimitOrdersBlock.placeLimitOrder()`

| Aspect | Detail |
|--------|--------|
| Visibility | external (not payable) |
| Caller | Maker |
| Parameters | key (user-controlled, any PoolKey), targetTick, zeroForOne, inputAmount (user-controlled) |
| Call chain | `→ LimitOrdersLogic.placeOrder() → IERC20.safeTransferFrom()` (skipped for native) |
| State modified | `_limitOrders`, `_limitOrderBuckets`, `nextLimitOrderId` |
| Value flow | ERC-20: maker → hook; native: none |
| Reentrancy guard | no |

### `TWAMMBlock.submitTWAMMOrder()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone (any PoolKey) |
| Parameters | key, zeroForOne, totalAmount, durationSeconds (user-controlled) |
| Call chain | `→ TWAMMLogic.submitOrder() → executePending()` |
| State modified | `_twammStates` sell rates, `_twammOrders`, `nextTWAMMOrderId` |
| Value flow | None (no escrow) |
| Reentrancy guard | no |

---

## Role-Gated

| Role | Contract | Function | Gate | State Modified |
|------|----------|----------|------|----------------|
| Round winner | HookRigOrchestrator | `claimKingPot()` | `msg.sender == round.winner` (`KingOfThePoolBlock.sol:120`), nonReentrant | `_settledKingRounds.claimed`; pays ERC-6909 → `to` |
| Order maker | LimitOrdersBlock | `cancelLimitOrder()` | `order.maker == msg.sender`, bucket unfilled | order, bucket; escrow → maker |
| Order maker | LimitOrdersBlock | `claimLimitOrder()` | `order.maker == msg.sender`, bucket filled | order, bucket; escrow (input token) → maker |
| Fee manager | ManagedFeeBlock | `setManagedPoolFee()` | `caller == state.manager` | `currentFee`; `PoolManager.updateDynamicLPFee` |
| Access manager | AccessControlBlock | `setAllowlistAccount()` | `msg.sender == manager` | `isAccountAllowlisted` |
| Access manager | AccessControlBlock | `setAccessMerkleRoot()` | `msg.sender == manager` | `merkleRoot` |
| Curve / factory | HookRigOrchestrator | `notifyPoolGraduated()` | `authorizedCurve` or `launchpadFactory` | `launchpadGraduated`, Anti-snipe `startBlock` |
| Curve / factory | HookRigOrchestrator | `seedKingPotFromLaunchCurve()` | `authorizedCurve` or `launchpadFactory` | King pot or `poolClaims[admin]` (no token transfer) |
| Factory | HookRigOrchestrator | `registerPoolStack()` (launchpad branch) | `msg.sender == launchpadFactory` | `_poolMeta` incl. `authorizedCurve` |
| Factory | VirtualXYKLaunch / SteppedTrancheLaunch | `initializeCurve()` | `msg.sender == factory`, Uninitialized | curve config, reserves |
| Factory | NativeTickLaunch | `initializeAndSeedNativeTicks()` | `msg.sender == factory`, Uninitialized | pool init, LP bands |
| PoolManager | HookRigBase | `unlockCallback()` | `onlyPoolManager` | ERC-6909 burn + take |
| PoolManager | VirtualXYKLaunch / SteppedTrancheLaunch / NativeTickLaunch | `unlockCallback()` | `msg.sender == poolManager` | graduation LP seed, King seed mint |
| Pending owner | HookRigOrchestrator | `acceptOwnership()` | Ownable2Step pending owner | `owner` |

---

## Admin-Only

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| HookRigOrchestrator | `setLaunchpadFactory()` | `_factory` | `launchpadFactory` (gates launchpad registration, graduation, pot seeding) |
| HookRigOrchestrator | `setTrustedRouter()` | `router`, `trusted` | `isTrustedRouter` (identity source for `_resolveUser`) |
| HookRigOrchestrator | `transferOwnership()` | `newOwner` | `pendingOwner` |
| HookRigOrchestrator | `renounceOwnership()` | — | `owner` |
| HookRigOrchestrator | (owner fallback) | — | `owner()` receives seeded claims when `poolAdmin == 0` (`HookRigOrchestrator.sol:438`) |
