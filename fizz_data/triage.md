# Campaign Triage — Medusa, 2 × 600 s (2026-10-15)

40 shrunk failures replayed deterministically in Foundry (throwaway replay test) → 13 distinct properties. All root causes are in `src/`; no harness bugs found.

| Property | Guarantee | Verdict | Root cause | Shrunk sequence |
|---|---|---|---|---|
| GL-19 / SP-21 | SHOULD-HOLD | **Confirmed bug** | `OracleLogic.updateCheckpoint` (`OracleBlock.sol`): `int24(int256(elapsed) * 100)` truncates once `elapsed > 83_886 s`; tick goes below MIN_TICK (-8.28M) or `lastTick + maxChange` overflows → panic 0x11. Called from beforeSwap/beforeAdd/beforeRemoveLiquidity, so after ~23.3 h idle LP exits (and swaps) revert. | warp ≥ 84k s → `pool_addLiquidity_clamped` / `pool_removeLiquidity_full` |
| SP-03 | SHOULD-HOLD | **Confirmed bug** | `LimitOrdersLogic.placeOrder` (`LimitOrdersBlock.sol:63`) skips the transfer for native input on a non-payable entry yet records `inputAmount`; cancel/claim pay ETH out of the hook. | 1 call: `placeLimitOrder_clamped(nativeKey)` / `limitOrderRoundTrip` |
| SP-15 | SHOULD-HOLD | **Confirmed bug** | `HookRigBase._resolveUser` trusts `hookData[0:32]` from untrusted routers; AccessControl checks the spoofed address. | `setCurrentActor` → `pool_swap_*` (routeMode 2) on POOL_PRIVATE |
| GL-11 | SHOULD-HOLD | **Confirmed bug** | Curves graduate at `lpTokenReserve / quoteToSeed`, not the curve's final marginal price (docs/04 §5 #5 says exact). | 1 call: `*_buy_toGraduation` |
| GL-17 | SHOULD-HOLD | **Confirmed bug** | `TWAMMLogic`: sell rates are only `+=`, `expirationTimestamp` never read; streams forever. | `secondary(TWAMM)` → time passes |
| SP-11 | SHOULD-HOLD | **Confirmed (low)** | `_boundedCut` floors on exact-output swaps; docs/04 says Ceil on added input cost (1 wei under-charge). | `buy_toGraduation` → `pool_swap_dust` exact-output sell |
| GL-03 / GL-02 | SHOULD-HOLD | **Confirmed bug** (pass 2) | `HookRigOrchestrator.seedKingPotFromLaunchCurve:431-436` seeds `currency0` into an empty pot; `KingOfThePoolBlock.processBuy:87-88` then overwrites `potCurrency` with the project token and adds to the same amount → round mixes currencies; the hook's ERC-6909 balance in the project currency no longer covers claims + pots + reserves (cross-pool exposure via the shared balance). | `steppedTrancheLaunch_buy_toGraduation` → `pool_swap_fullBalance` (exact-in buy) |
| GL-15 | EXPLORATORY | Lead (pass 2) | `SteppedTrancheLaunch.buy:128-129` prices the whole order at the entry tranche, so one large buy pays the base price across every tranche it crosses. | `steppedTrancheLaunch_buy_toGraduation` |
| SP-19 | EXPLORATORY | Lead (strong) | `registerPoolStack` permissionless and allowed after initialization — third party configures a live pool. | 1 call: `secondary(register on POOL_UNREGISTERED)` |
| SP-30 | EXPLORATORY | Lead (strong) | `submitTWAMMOrder` escrows nothing; one free `type(uint128).max` order overflows `sellRate` → all later submissions revert. | 1 call |
| GL-23 | EXPLORATORY | Lead | `LaunchpadFactory` never checks `curveTokenAllocation + lpTokenReserve ≤ totalSupply − vesting`; with creator vesting the curve cannot cover its allocation + LP reserve. | `launchpadFactory_secondary` (vesting launch) |
| SP-27 | EXPLORATORY | Lead | SteppedTranche buy: `tokensOut` capped / priced at entry tranche without refunding quote — buyer charged for undelivered tokens. | `launchpadFactory_secondary` → `steppedTrancheLaunch_buy` |
| SP-28 | EXPLORATORY | Lead (design) | `claimOrder` returns the input token; filled limit orders never execute. | long sequence → `claimLimitOrder_clamped` |
| GL-26 | EXPLORATORY | Lead (design) | Unsold curve allocation (~300M XYK / ~600M tranche tokens) stays locked forever in graduated curves. | 1 call: `*_buy_toGraduation` |

## Pass 2 (shrinkLimit 100, warm corpus, known-bug handlers excluded)
82 failure files total (42 new) → added GL-03, GL-02, GL-15. One GL-02 sequence (3 calls) did not reproduce outside Medusa; GL-02 reproduces deterministically in a 22-call sequence with the King-mixing root cause. `steppedTrancheLaunch_buySellRoundTrip` failed on SP-27 (inside its buy), not SP-05 — no curve round-trip profit was found.

## Not surfaced by either campaign
SP-02 (King payout), SP-16 (JIT identity switch), SP-17 / SP-18 / SP-25 (attribution bypass/grief). SP-16 fired deterministically in the implementer's probe; it is reproduced in Step 11 as a targeted sequence (labelled as such), not a campaign finding.
