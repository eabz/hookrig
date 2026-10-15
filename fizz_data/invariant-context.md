# Invariant Context — HookRig (fizz Step 9a)

## Protocol in one paragraph
HookRig is a single Uniswap v4 hook (`HookRigOrchestrator`) that composes up to 22 per-pool "blocks" chosen by a `uint32` bitmap fixed at `registerPoolStack` (one-shot, permissionless for non-launchpad keys). `beforeSwap` resolves an override LP fee (max of dynamic/managed/market-hours/anti-snipe, ≤ MAX_LP_FEE). `afterSwap` runs a single-pass waterfall (`AfterSwapDeltaAggregator._executeAfterSwapDeltaWaterfall`) that withholds ≤ 25% of the swap's unspecified amount via `afterSwapReturnDelta` and settles each slice: ERC-6909 mint into the hook (tax/fee-share/referral claims via `poolClaims`, King pot, Auto-buyback reserve), `take` to burn (AutoBurn), or `donate` to in-range LPs (Arb recapture, LP rewards, triggered buyback). Claims are pull-based: `withdrawClaim` / `claimKingPot` burn the hook's ERC-6909 and `take` the underlying. Per-pool ledgers (`poolClaims[pool][currency][acct]`) are backed by ONE hook-wide ERC-6909 balance per currency in PoolManager. A launchpad (`LaunchpadFactory`) deploys `HookRigToken` (always currency1) + a curve clone: `VirtualXYKLaunch` (virtual constant product), `SteppedTrancheLaunch` (tranche price + anti-snipe surcharge, part seeded into the King pot at graduation via `seedKingPotFromLaunchCurve`), `NativeTickLaunch` (block-0 v4 pool, single-sided bands). Curves graduate by initializing the v4 pool and seeding full-range LP that is never removed.

## Source files (in scope)
- Core: src/HookRigOrchestrator.sol, src/base/HookRigBase.sol, src/base/AfterSwapDeltaAggregator.sol, src/base/FeeAggregator.sol
- Blocks: src/blocks/{fees,protection,token-rules,rewards,trading}/*.sol
- Launchpad: src/launchpad/LaunchpadFactory.sol, src/launchpad/HookRigToken.sol, src/launchpad/curves/{VirtualXYKLaunch,SteppedTrancheLaunch,NativeTickLaunch}.sol
- Libraries: src/libraries/{HookPermissionMasks,PoolTokenDir,TransientContext}.sol
- Out of scope: src/presets/HookRigPresets.sol, src/interfaces/*

## Prior analysis (READ THESE)
- x-ray/x-ray.md — threat model + key attack surfaces
- x-ray/invariants.md — 40 guards, 33 single-contract (I-*), 5 cross-contract (X-*), 5 economic (E-*) invariants with code citations. On-chain=No rows are the high-signal candidates: I-2, I-3, I-7, I-21, I-22, I-23, I-29, I-30, I-31, X-1..X-5, E-1, E-4, E-5.
- docs/04-security-mechanics-and-caveats.md, docs/06-attack-vectors-and-fixes.md — doc-stated guarantees (use these as SHOULD-HOLD evidence)
- fizz_data/additional-context.md — user guidance (keep the repo's existing writing conventions)

## Doc-stated guarantees (evidence for SHOULD-HOLD tagging)
- Solvency: "sum(claims) <= actual_reserves" across any swap/modifyLiquidity/donate/claim sequence (docs/04 §5 #2).
- No value extraction: "valueOut <= valueIn" for dust swaps, curve buy/sell cycles, LP deposit/withdraw cycles (docs/04 §5 #3).
- Withdrawal liveness: LPs and limit-order makers can always withdraw / cancel (docs/04 §5 #4); AccessControl never runs on beforeRemoveLiquidity.
- Aggregate cut ≤ 25% of output (`MAX_AGGREGATE_AFTER_SWAP_BPS = 2500`); cuts round DOWN so sum of parts ≤ total (docs/03, docs/04 1B).
- Per-pool isolation: "No block in hookrig ever uses global state"; claims double-keyed per pool (docs/02 4.2, docs/06 AV-01).
- Bitmap locked at registration (docs/06 AV-07). Anti-snipe "can never be re-triggered after block N" (docs/04 §4). King pot contributions only in project currency; mismatched seeds to admin claims (docs/06 FF-03).
- Fee caps: dynamic/managed/market-hours ≤ 5%; tax ≤ 10%; burn/share/LP/king/buyback ≤ 5%; referral ≤ 3%; anti-snipe launch fee ≤ 80% (code).
- Hard ceilings: JIT hold ≤ 7200 blocks, circuit-breaker window ≤ 86_400 s.

## Harness facts (test/fizz) — properties must be writable against these
- Base.sol deploys: PoolManager, HookRigOrchestrator (CREATE2-mined hook address), LaunchpadFactory (+3 curve impls), `trustedRouter` (trusted; user = msg.sender via IMsgSender), `plainRouter` (untrusted; user = hookData[0:32] or router), MockBurnableERC20 `token0` (quote) and `token1` (project).
- `poolKeys[]` (+ parallel `poolCurves[]`): 0 POOL_MULTI (20 blocks incl. tax→actors[1], fee share→actors[2]+TREASURY, King, buyback, referral, limit orders, TWAMM, oracle, MEV/JIT, circuit breaker, wallet cap, vesting cap, managed fee manager actors[1]); 1 POOL_PRIVATE (AccessControl swap+add, allowlist {admin, actors[0]}, manager actors[2], JIT 5 blocks); 2 POOL_UNREGISTERED (initialized, no stack — target of fuzzed retro-registration); 3 VirtualXYK launch pool; 4 SteppedTranche launch pool (surchargeToKingPotBps 5000). More pools/launches can be appended at runtime (fuzzed `registerPoolStack` on fresh keys, `launchpadFactory_secondary`).
- `nativeOrderKey`: never-initialized key with native currency0 for native-input limit orders.
- `claimants[]` = actors (3) + admin (harness, also poolAdmin of launches and POOL_MULTI) + TREASURY. `trackedCurrencies[]` = token0, token1, every launch token. `xykCurves[]`, `trancheCurves[]`, `launchTokens[]`.
- `trackedOrders[]` (HookRigOrchestratorHandler): limit orders placed by the harness with key/maker/closed.
- Handlers: PoolManagerHandler (`pool_swap*` with routeMode 0 trusted / 1 honest hookData / 2 spoofed hookData / 3 empty; `pool_addLiquidity_clamped`, `pool_removeLiquidity_*`, `pool_donate_clamped`), HookRigOrchestratorHandler (limit orders, withdrawClaim (any claimant), claimKingPot, finalize, referral, donateETH/ERC20 to hook, secondary: registerPoolStack (fuzzed config, presets, fresh keys), access setters, managed fee, TWAMM, setTrustedRouter), VirtualXYKLaunchHandler / SteppedTrancheLaunchHandler (buy/sell incl. dust, full, to-graduation), HookRigTokenHandler (transfer, donate to curve), LaunchpadFactoryHandler (new launches of all 3 types).
- Coverage (Medusa, cycle 2): orchestrator 94%, aggregator 99%, curves 81–88%, blocks 80–100%.
- Readable state: `orchestrator.poolClaims(pool,c,acct)`, `getCurrentKing(pool)` (roundId, king, pot, deadline), `totalLPRewardsDonated`, `totalAutoBurnedByPool`, `swapRewardPoints`, `totalPoolSwapPoints`, `traderReferrer`, `isAccountAllowlisted`, `getPoolEnabledBlocks`, `getOracleTickCumulative`, `poolManager.balanceOf(hook, currency.toId())`, StateLibrary slot0/liquidity/positions; curves: `realQuoteRaised`, `curveTokensSold`, `virtualQuoteReserve`, `virtualTokenReserve`, `invariantK`, `totalSurchargeCollected`, `launchState`, configs. NOT readable without a harness: `_kingStates.potCurrency`, `_settledKingRounds`, `_autoBuybackStates.reserveByCurrency`, `_limitOrders`, `_limitOrderBuckets`, `_twammStates`, `_poolMeta` (except bitmap), `_walletSellEpochs`, `_lpAddedBlock`, `_antiSnipeStates`.

## Extracted structure
- AGGREGATE_VARIABLES: `poolClaims` (per pool/currency/account) vs hook ERC-6909 balance; `_kingStates.currentPotAmount` + `_settledKingRounds.amount`; `reserveByCurrency`; `totalLPRewardsDonated`; `totalAutoBurnedByPool`; `totalPoolSwapPoints` vs Σ `swapRewardPoints`; `LimitOrderBucket.totalInputAmount` vs Σ order inputs; TWAMM `sellRate0For1/1For0` + `accruedVirtualVolume*`; curves `realQuoteRaised`, `curveTokensSold`, `totalSurchargeCollected`, `virtualQuoteReserve/TokenReserve`; factory `totalLaunches`.
- PAIRED_OPERATIONS: credit claim ↔ withdrawClaim; King contribution/seed ↔ roll ↔ claimKingPot; buyback accumulate ↔ trigger/deploy; placeLimitOrder ↔ cancel/claim; addLiquidity ↔ removeLiquidity; curve buy ↔ sell; register ↔ (none — one-shot); allowlist add ↔ remove; setTrustedRouter true ↔ false.
- CONVERSION_FUNCTIONS: `_boundedCut` (bps of gross, Floor); FeeSharing split (Floor); curve buy/sell (`Math.mulDiv` Ceil reserves, Floor outputs); Stepped `tokensOut = net * 2^96 / priceQ96` (Floor), surcharge Ceil, sell `min(base redemption, pro-rata)`; graduation `sqrt(tokens/quote)`; DynamicFee EMA; AntiSnipe linear decay; Oracle tick truncation.
- ACCESS_CONTROL: `onlyOwner` (setLaunchpadFactory, setTrustedRouter); `onlyPoolManager` callbacks + unlockCallback; launchpadFactory-only launchpad registration; authorizedCurve/factory-only `notifyPoolGraduated` / `seedKingPotFromLaunchCurve`; manager-only `setManagedPoolFee`, `setAllowlistAccount`, `setAccessMerkleRoot`; maker-only limit cancel/claim; winner-only `claimKingPot`; factory-only curve initialize. Identity for blocks comes from `_resolveUser` (trusted router → `msgSender()`, else hookData[0:32], else router).

## Known high-signal leads from x-ray (verify, do not assume)
1. King pot currency mixing: seed in quote (`currency0`) into empty pot, then a buy contribution in project token overwrites `potCurrency` and adds to the same amount (I-3/X-5).
2. hookData-spoofed identity feeds AccessControl / JIT posKey / WalletCap / VestingSellCap (X-3/E-4).
3. Permissionless first-come and post-initialization `registerPoolStack` (X-4/E-5).
4. Native limit orders recorded without receiving ETH (I-21).
5. TWAMM rates never expire (I-22); Anti-snipe clock re-armable (I-23).
6. Global ERC-6909 solvency across pools (E-1).
