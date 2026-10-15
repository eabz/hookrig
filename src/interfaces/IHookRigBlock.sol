// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IHookRigBlock
/// @notice Canonical taxonomy, block identifiers, trust ratings, and parameter structs for all HookRig blocks.
interface IHookRigBlock {
    /// @notice The 5 functional groups of HookRig building blocks.
    enum BlockGroup {
        Fees,
        ProtectionAndAccess,
        TokenRules,
        RewardsAndIncome,
        Trading
    }

    /// @notice Explicit trust classification for each block.
    enum TrustLevel {
        Low, // Purely algorithmic / permissionless once initialized
        Medium // Parameterized or manager-adjustable within immutable hard caps
    }

    /// @notice Canonical IDs for the 17 core blocks + 5 expansion blocks.
    enum BlockId {
        // Group 1: Fees
        DynamicFee, // 0
        ManagedFee, // 1
        MarketHoursFee, // 2
        // Group 2: Protection & Access
        AntiSnipe, // 3
        MEVProtection, // 4
        ArbRecapture, // 5
        AccessControl, // 6
        // Group 3: Token Rules
        WalletCap, // 7
        BuySellTax, // 8
        AutoBurn, // 9
        // Group 4: Rewards & Income
        FeeSharing, // 10
        LPRewards, // 11
        SwapRewards, // 12
        KingOfThePool, // 13
        // Group 5: Trading
        LimitOrders, // 14
        TWAMM, // 15
        Oracle, // 16
        // Expansion Blocks (17..21)
        JITGuard, // 17
        CircuitBreaker, // 18
        ReferralSplit, // 19
        VestingSellCap, // 20
        AutoBuyback // 21
    }

    /// @notice Canonical IDs for the 12 curated presets + Blank custom stack.
    enum PresetId {
        Blank, // 0: Custom user-composed block bitmap
        FairLaunch, // 1: Dynamic fee + Anti-snipe + Wallet cap + Auto burn + LP rewards
        KingOfThePoolLaunch, // 2: Dynamic fee + Anti-snipe + Arb recapture + LP rewards + King of the Pool
        WeeklyKingWithBuyRewards, // 3: KingOfThePoolLaunch + Swap rewards (168h round)
        CreatorEconomyToken, // 4: Dynamic fee + Anti-snipe + Buy/sell tax + Fee sharing + LP rewards
        CharityToken, // 5: Dynamic fee + Anti-snipe + Fee sharing + LP rewards + Auto burn
        TreasuryBackedToken, // 6: Dynamic fee + Anti-snipe + Arb recapture + Sell tax + LP rewards + Auto burn
        StockQuotedToken, // 7: Market-hours fee + Anti-snipe + Arb recapture + LP rewards + Auto burn
        DeepLiquidityExistingToken, // 8: Dynamic fee + Arb recapture + LP rewards
        TraderFirstPool, // 9: Dynamic fee + Anti-snipe + Arb recapture
        StablePairProjectFee, // 10: Arb recapture + Buy/sell tax (1.875% each way) + LP rewards
        PrivatePool, // 11: Access control + MEV protection + Oracle
        ProTradingPool // 12: Dynamic fee + Limit orders + TWAMM + Oracle
    }

    struct DynamicFeeParams {
        uint24 baseFee;
        uint24 maxFee;
        int24 volatilityTickThreshold;
    }

    struct ManagedFeeParams {
        uint24 startingFee;
        uint24 feeCap;
        address manager;
    }

    struct MarketHoursFeeParams {
        uint24 openFee;
        uint24 closedFee;
        uint8 openHourUtc; // 0..23
        uint8 closeHourUtc; // 0..23
        bool weekendClosed;
    }

    struct AntiSnipeParams {
        uint24 launchFee;
        uint24 normalFee;
        uint32 decayBlocks;
    }

    struct MEVProtectionParams {
        int24 maxTickDeltaPerSwap;
        uint32 minLPHoldBlocks;
        uint16 jitExitPenaltyBps;
    }

    struct ArbRecaptureParams {
        uint16 recaptureShareBps; // Share of measured arb spread paid to LPs (<= 8000)
        int24 arbTriggerTickDelta;
    }

    struct AccessControlParams {
        bool checkBeforeAddLiquidity;
        bool checkBeforeSwap;
        bytes32 merkleRoot;
        address manager;
    }

    struct WalletCapParams {
        uint16 maxWalletBps; // Max % of token totalSupply (in bps, e.g. 200 = 2%)
        uint32 sunsetBlocks; // 0 = permanent, >0 = disabled after N blocks
    }

    struct BuySellTaxParams {
        uint16 buyTaxBps; // <= 1000 (10%)
        uint16 sellTaxBps; // <= 1000 (10%)
        address taxRecipient;
        bool decayOnly; // If true, tax can only be lowered, never raised
    }

    struct AutoBurnParams {
        uint16 burnOnBuyBps; // <= 500 (5%)
        bool useTokenBurnCall; // true = ERC20Burnable.burn, false = transfer to 0xdead
    }

    struct FeeSharingParams {
        uint16 feeShareBps; // <= 500 (5%)
        address primaryRecipient;
        address secondaryRecipient;
        uint16 secondaryShareBps; // Portion of feeShareBps sent to secondaryRecipient (0..10000)
    }

    struct LPRewardsParams {
        uint16 extraBuyFeeBps; // <= 500 (5%), donated to active in-range LPs
    }

    struct SwapRewardsParams {
        uint128 pointsPerUnitVolume;
    }

    struct KingOfThePoolParams {
        uint16 potFeeOnBuyBps; // <= 500 (5%)
        uint32 roundDurationSeconds; // e.g., 168 hours = 604800 seconds
        uint128 minBuyAmountForReset; // Anti-dust griefing floor
    }

    // -------------------------------------------------------------------------
    // Recommended Expansion Block Parameter Structs (Blocks #18..#22)
    // -------------------------------------------------------------------------

    struct CircuitBreakerParams {
        int24 maxWindowTickDeviation; // Max allowed +/- tick movement per rolling window
        uint32 windowSeconds; // Rolling window duration in seconds (default 300s)
    }

    struct ReferralSplitParams {
        uint16 referralFeeBps; // <= 300 (3.00% hard cap credited to referrer)
    }

    struct VestingSellCapParams {
        uint16 maxDailySellBps; // Max % of wallet balance sellable per 24h epoch (in bps, e.g. 1000 = 10%)
    }

    struct AutoBuybackParams {
        uint16 buybackFeeBps; // <= 500 (5.00% hard cap accumulated into pool buyback reserve)
        int24 triggerFloorTick; // Spot tick at or below which accumulated reserves defend the floor
        uint128 minBuybackReserve; // Minimum accumulated reserve required to trigger floor defense
    }

    /// @notice Unified configuration bundle passed when initializing a pool in HookRig.
    struct PoolStackConfig {
        PresetId presetId;
        uint32 enabledBlocksBitmap;
        bool isToken0ProjectToken;
        address poolAdmin;
        address authorizedCurve;
        DynamicFeeParams dynamicFee;
        ManagedFeeParams managedFee;
        MarketHoursFeeParams marketHoursFee;
        AntiSnipeParams antiSnipe;
        MEVProtectionParams mevProtection;
        ArbRecaptureParams arbRecapture;
        AccessControlParams accessControl;
        WalletCapParams walletCap;
        BuySellTaxParams buySellTax;
        AutoBurnParams autoBurn;
        FeeSharingParams feeSharing;
        LPRewardsParams lpRewards;
        SwapRewardsParams swapRewards;
        KingOfThePoolParams kingOfThePool;
        CircuitBreakerParams circuitBreaker;
        ReferralSplitParams referralSplit;
        VestingSellCapParams vestingSellCap;
        AutoBuybackParams autoBuyback;
    }
}
