// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHookRigBlock} from "../interfaces/IHookRigBlock.sol";

/// @title HookPermissionMasks
/// @notice Bitmask definitions for the 17 core blocks, 5 expansion blocks, and 12 curated presets.
library HookPermissionMasks {
    // -------------------------------------------------------------------------
    // Block Bit Flags (1 << uint8(BlockId))
    // -------------------------------------------------------------------------
    // Group 1: Fees
    uint32 internal constant BIT_DYNAMIC_FEE = 1 << 0;
    uint32 internal constant BIT_MANAGED_FEE = 1 << 1;
    uint32 internal constant BIT_MARKET_HOURS_FEE = 1 << 2;

    // Group 2: Protection & Access
    uint32 internal constant BIT_ANTI_SNIPE = 1 << 3;
    uint32 internal constant BIT_MEV_PROTECTION = 1 << 4;
    uint32 internal constant BIT_ARB_RECAPTURE = 1 << 5;
    uint32 internal constant BIT_ACCESS_CONTROL = 1 << 6;

    // Group 3: Token Rules
    uint32 internal constant BIT_WALLET_CAP = 1 << 7;
    uint32 internal constant BIT_BUY_SELL_TAX = 1 << 8;
    uint32 internal constant BIT_AUTO_BURN = 1 << 9;

    // Group 4: Rewards & Income
    uint32 internal constant BIT_FEE_SHARING = 1 << 10;
    uint32 internal constant BIT_LP_REWARDS = 1 << 11;
    uint32 internal constant BIT_SWAP_REWARDS = 1 << 12;
    uint32 internal constant BIT_KING_OF_THE_POOL = 1 << 13;

    // Group 5: Trading
    uint32 internal constant BIT_LIMIT_ORDERS = 1 << 14;
    uint32 internal constant BIT_TWAMM = 1 << 15;
    uint32 internal constant BIT_ORACLE = 1 << 16;

    // Expansion Blocks
    uint32 internal constant BIT_JIT_GUARD = 1 << 17;
    uint32 internal constant BIT_CIRCUIT_BREAKER = 1 << 18;
    uint32 internal constant BIT_REFERRAL_SPLIT = 1 << 19;
    uint32 internal constant BIT_VESTING_SELL_CAP = 1 << 20;
    uint32 internal constant BIT_AUTO_BUYBACK = 1 << 21;

    // Category Masks
    uint32 internal constant BASE_FEE_ENGINES_MASK = BIT_DYNAMIC_FEE | BIT_MANAGED_FEE | BIT_MARKET_HOURS_FEE;

    uint32 internal constant FEE_BLOCKS_MASK = BASE_FEE_ENGINES_MASK | BIT_ANTI_SNIPE;

    uint32 internal constant AFTER_SWAP_RETURN_DELTA_BLOCKS_MASK = BIT_ARB_RECAPTURE | BIT_BUY_SELL_TAX | BIT_AUTO_BURN
        | BIT_FEE_SHARING | BIT_LP_REWARDS | BIT_KING_OF_THE_POOL | BIT_REFERRAL_SPLIT | BIT_AUTO_BUYBACK;

    /// @notice Blocks that queue LP donations; they need `beforeSwap` (flush) and `beforeAddLiquidity` (add-block guard).
    uint32 internal constant LP_DONATION_BLOCKS_MASK = BIT_ARB_RECAPTURE | BIT_LP_REWARDS | BIT_AUTO_BUYBACK;

    /// @notice Per-wallet cap blocks; they need `beforeAddLiquidity` to reject one-sided range orders.
    uint32 internal constant WALLET_RULE_BLOCKS_MASK = BIT_WALLET_CAP | BIT_VESTING_SELL_CAP;

    uint32 internal constant ALL_BLOCKS_MASK = (uint32(1) << 22) - 1;

    // -------------------------------------------------------------------------
    // The 12 Curated Preset Block Bitmaps (matching docs/01-explanation-and-catalog.md)
    // -------------------------------------------------------------------------

    // 1. Fair launch: Dynamic fee + Anti-snipe + Wallet cap + Auto burn + LP rewards
    uint32 internal constant PRESET_FAIR_LAUNCH =
        BIT_DYNAMIC_FEE | BIT_ANTI_SNIPE | BIT_WALLET_CAP | BIT_AUTO_BURN | BIT_LP_REWARDS;

    // 2. King of the Pool launch: Dynamic fee + Anti-snipe + Arb recapture + LP rewards + King of the Pool
    uint32 internal constant PRESET_KING_OF_THE_POOL_LAUNCH =
        BIT_DYNAMIC_FEE | BIT_ANTI_SNIPE | BIT_ARB_RECAPTURE | BIT_LP_REWARDS | BIT_KING_OF_THE_POOL;

    // 3. Weekly King with buy rewards: King of the Pool launch + Swap rewards (168h round)
    uint32 internal constant PRESET_WEEKLY_KING_BUY_REWARDS = PRESET_KING_OF_THE_POOL_LAUNCH | BIT_SWAP_REWARDS;

    // 4. Creator economy token: Dynamic fee + Anti-snipe + Buy and sell tax + Fee sharing + LP rewards
    uint32 internal constant PRESET_CREATOR_ECONOMY =
        BIT_DYNAMIC_FEE | BIT_ANTI_SNIPE | BIT_BUY_SELL_TAX | BIT_FEE_SHARING | BIT_LP_REWARDS;

    // 5. Charity token: Dynamic fee + Anti-snipe + Fee sharing + LP rewards + Auto burn
    uint32 internal constant PRESET_CHARITY_TOKEN =
        BIT_DYNAMIC_FEE | BIT_ANTI_SNIPE | BIT_FEE_SHARING | BIT_LP_REWARDS | BIT_AUTO_BURN;

    // 6. Treasury-backed token: Dynamic fee + Anti-snipe + Arb recapture + Buy/sell tax (sell only) + LP rewards + Auto burn
    uint32 internal constant PRESET_TREASURY_BACKED =
        BIT_DYNAMIC_FEE | BIT_ANTI_SNIPE | BIT_ARB_RECAPTURE | BIT_BUY_SELL_TAX | BIT_LP_REWARDS | BIT_AUTO_BURN;

    // 7. Stock-quoted token: Market-hours fee + Anti-snipe + Arb recapture + LP rewards + Auto burn
    uint32 internal constant PRESET_STOCK_QUOTED =
        BIT_MARKET_HOURS_FEE | BIT_ANTI_SNIPE | BIT_ARB_RECAPTURE | BIT_LP_REWARDS | BIT_AUTO_BURN;

    // 8. Deep liquidity for a token that already trades: Dynamic fee + Arb recapture + LP rewards
    uint32 internal constant PRESET_DEEP_LIQUIDITY = BIT_DYNAMIC_FEE | BIT_ARB_RECAPTURE | BIT_LP_REWARDS;

    // 9. Trader-first pools: Dynamic fee + Anti-snipe + Arb recapture
    uint32 internal constant PRESET_TRADER_FIRST = BIT_DYNAMIC_FEE | BIT_ANTI_SNIPE | BIT_ARB_RECAPTURE;

    // 10. Stable-pair project fee: Arb recapture + Buy and sell tax (1.875% each way) + LP rewards
    uint32 internal constant PRESET_STABLE_PAIR_PROJECT_FEE = BIT_ARB_RECAPTURE | BIT_BUY_SELL_TAX | BIT_LP_REWARDS;

    // 11. Private pool (ours): Access control + MEV protection + Oracle
    uint32 internal constant PRESET_PRIVATE_POOL = BIT_ACCESS_CONTROL | BIT_MEV_PROTECTION | BIT_ORACLE;

    // 12. Pro trading pool (ours): Dynamic fee + Limit orders + TWAMM + Oracle
    uint32 internal constant PRESET_PRO_TRADING_POOL = BIT_DYNAMIC_FEE | BIT_LIMIT_ORDERS | BIT_TWAMM | BIT_ORACLE;

    /// @notice Resolves a PresetId to its canonical 32-bit block bitmap.
    function getPresetBitmap(IHookRigBlock.PresetId preset) internal pure returns (uint32) {
        if (preset == IHookRigBlock.PresetId.FairLaunch) return PRESET_FAIR_LAUNCH;
        if (preset == IHookRigBlock.PresetId.KingOfThePoolLaunch) return PRESET_KING_OF_THE_POOL_LAUNCH;
        if (preset == IHookRigBlock.PresetId.WeeklyKingWithBuyRewards) return PRESET_WEEKLY_KING_BUY_REWARDS;
        if (preset == IHookRigBlock.PresetId.CreatorEconomyToken) return PRESET_CREATOR_ECONOMY;
        if (preset == IHookRigBlock.PresetId.CharityToken) return PRESET_CHARITY_TOKEN;
        if (preset == IHookRigBlock.PresetId.TreasuryBackedToken) return PRESET_TREASURY_BACKED;
        if (preset == IHookRigBlock.PresetId.StockQuotedToken) return PRESET_STOCK_QUOTED;
        if (preset == IHookRigBlock.PresetId.DeepLiquidityExistingToken) return PRESET_DEEP_LIQUIDITY;
        if (preset == IHookRigBlock.PresetId.TraderFirstPool) return PRESET_TRADER_FIRST;
        if (preset == IHookRigBlock.PresetId.StablePairProjectFee) return PRESET_STABLE_PAIR_PROJECT_FEE;
        if (preset == IHookRigBlock.PresetId.PrivatePool) return PRESET_PRIVATE_POOL;
        if (preset == IHookRigBlock.PresetId.ProTradingPool) return PRESET_PRO_TRADING_POOL;
        return 0;
    }

    /// @notice Validates Tier 3 block compatibility rules (mutual exclusions and incompatible combinations).
    function isValidTier3Bitmap(uint32 bitmap) internal pure returns (bool) {
        if (bitmap == 0 || (bitmap & ~ALL_BLOCKS_MASK) != 0) {
            return false;
        }
        // 1. At most one base fee engine (`DynamicFee`, `ManagedFee`, `MarketHoursFee`) may be active
        uint32 baseFeeBits = bitmap & BASE_FEE_ENGINES_MASK;
        if (baseFeeBits != 0 && (baseFeeBits & (baseFeeBits - 1)) != 0) {
            return false;
        }
        // 2. Dislocation & JIT protection mutual exclusions
        bool hasMev = (bitmap & BIT_MEV_PROTECTION) != 0;
        bool hasJit = (bitmap & BIT_JIT_GUARD) != 0;
        bool hasArb = (bitmap & BIT_ARB_RECAPTURE) != 0;
        bool hasCb = (bitmap & BIT_CIRCUIT_BREAKER) != 0;
        if (hasMev && (hasJit || hasArb || hasCb)) {
            return false;
        }
        if (hasArb && hasCb) {
            return false;
        }
        // 3. `WalletCap` and `VestingSellCap` are mutually exclusive
        if ((bitmap & BIT_WALLET_CAP) != 0 && (bitmap & BIT_VESTING_SELL_CAP) != 0) {
            return false;
        }
        // 4. `LimitOrders` cannot be combined with `BuySellTax`, `AutoBurn`, `WalletCap`, or `VestingSellCap`
        if (
            (bitmap & BIT_LIMIT_ORDERS) != 0
                && (bitmap & (BIT_BUY_SELL_TAX | BIT_AUTO_BURN | BIT_WALLET_CAP | BIT_VESTING_SELL_CAP)) != 0
        ) {
            return false;
        }
        // 5. `TWAMM` cannot be combined with `AntiSnipe`, `WalletCap`, `VestingSellCap`, `BuySellTax`, or `AutoBurn`
        if (
            (bitmap & BIT_TWAMM) != 0
                && (bitmap
                            & (BIT_ANTI_SNIPE
                                | BIT_WALLET_CAP
                                | BIT_VESTING_SELL_CAP
                                | BIT_BUY_SELL_TAX
                                | BIT_AUTO_BURN)) != 0
        ) {
            return false;
        }
        // 6. `AccessControl` cannot be combined with `LimitOrders`, `TWAMM`, `AntiSnipe`, or `KingOfThePool`
        if (
            (bitmap & BIT_ACCESS_CONTROL) != 0
                && (bitmap & (BIT_LIMIT_ORDERS | BIT_TWAMM | BIT_ANTI_SNIPE | BIT_KING_OF_THE_POOL)) != 0
        ) {
            return false;
        }
        return true;
    }

    /// @notice Computes the required Uniswap v4 Hooks.Permissions for any given block bitmap.
    function permissionsForBitmap(uint32 bitmap) internal pure returns (Hooks.Permissions memory perms) {
        perms.beforeInitialize = (bitmap & BIT_TWAMM) != 0;
        perms.afterInitialize = bitmap != 0;
        perms.beforeAddLiquidity =
            (bitmap
                        & (BIT_TWAMM
                            | BIT_ACCESS_CONTROL
                            | BIT_ORACLE
                            | BIT_MEV_PROTECTION
                            | BIT_JIT_GUARD
                            | LP_DONATION_BLOCKS_MASK
                            | WALLET_RULE_BLOCKS_MASK)) != 0;
        perms.beforeRemoveLiquidity =
            (bitmap & (BIT_TWAMM | BIT_ORACLE | BIT_MEV_PROTECTION | BIT_JIT_GUARD)) != 0;
        perms.beforeSwap =
            (bitmap
                        & (BIT_DYNAMIC_FEE
                            | BIT_MARKET_HOURS_FEE
                            | BIT_ANTI_SNIPE
                            | BIT_MEV_PROTECTION
                            | LP_DONATION_BLOCKS_MASK
                            | BIT_ACCESS_CONTROL
                            | BIT_TWAMM
                            | BIT_ORACLE
                            | BIT_CIRCUIT_BREAKER)) != 0;
        // Always enable `afterSwap` whenever `beforeSwap` is enabled so `TransientContext` pre-swap snapshots
        // stored in `_beforeSwap` are guaranteed to be consumed and cleared in `_afterSwap`.
        perms.afterSwap = perms.beforeSwap
            || (bitmap
                        & (AFTER_SWAP_RETURN_DELTA_BLOCKS_MASK
                            | BIT_MEV_PROTECTION
                            | BIT_WALLET_CAP
                            | BIT_VESTING_SELL_CAP
                            | BIT_SWAP_REWARDS
                            | BIT_LIMIT_ORDERS
                            | BIT_CIRCUIT_BREAKER)) != 0;
        perms.afterSwapReturnDelta = (bitmap & AFTER_SWAP_RETURN_DELTA_BLOCKS_MASK) != 0;
    }
}
