// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Actor} from "./Actor.sol";
import {Clamp} from "./utils/Clamp.sol";
import {DecimalPrinter} from "./utils/DecimalPrinter.sol";
import {Deployer} from "./utils/Deployer.sol";
import {vm} from "./utils/Hevm.sol";
import {Logger} from "./utils/Logger.sol";
import {Math} from "./utils/Math.sol";
import {StringUtils} from "./utils/StringUtils.sol";
import {EnumerableSet} from "./utils/EnumerableSet.sol";
import {LaunchpadDeployer} from "./utils/LaunchpadDeployer.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IHookRigBlock} from "../../src/interfaces/IHookRigBlock.sol";
import {IHookRigOrchestrator} from "../../src/interfaces/IHookRigOrchestrator.sol";
import {ITokenLaunchpad} from "../../src/interfaces/ITokenLaunchpad.sol";
import {HookRigOrchestrator} from "../../src/HookRigOrchestrator.sol";
import {HookPermissionMasks} from "../../src/libraries/HookPermissionMasks.sol";
import {LaunchpadFactory} from "../../src/launchpad/LaunchpadFactory.sol";
import {VirtualXYKLaunch} from "../../src/launchpad/curves/VirtualXYKLaunch.sol";
import {SteppedTrancheLaunch} from "../../src/launchpad/curves/SteppedTrancheLaunch.sol";
import {HookRigTestRouter, MockBurnableERC20} from "../utils/HookRigTestBase.sol";
import {HookRigOrchestratorHarness} from "./harness/HookRigOrchestratorHarness.sol";

/// @notice Base contract with state variables and setup functions
abstract contract Base is StringUtils, Clamp, Deployer, Math {
    using DecimalPrinter for uint256;
    using PoolIdLibrary for PoolKey;

    string[] internal ACTOR_LABELS = ["Alice", "Bob", "Charlie"];
    uint256 internal constant BLOCK_INTERVAL = 12 seconds;
    uint256 internal constant INITIAL_ETH_BALANCE = 1_000 ether;
    uint256 internal constant INITIAL_TOKEN_BALANCE = 100_000_000 ether;
    uint256 internal constant ADMIN_TOKEN_BALANCE = 1_000_000_000 ether;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint160 internal constant ORCHESTRATOR_HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /// @notice Non-actor fee-sharing secondary recipient (withdraws through a dedicated handler path).
    address internal constant TREASURY = address(0xFEE01);

    // Indexes into `poolKeys` for pools created in setup
    uint256 internal constant POOL_MULTI = 0; // standard pool with every economic block enabled
    uint256 internal constant POOL_PRIVATE = 1; // AccessControl + JIT guard pool
    uint256 internal constant POOL_UNREGISTERED = 2; // initialized without a stack (retro-registration target)
    uint256 internal constant POOL_XYK = 3; // VirtualXYK launch pool (live after graduation)
    uint256 internal constant POOL_TRANCHE = 4; // SteppedTranche launch pool (live after graduation)

    // ―――――――――――――――――――――――――― Ghosts ――――――――――――――――――――――――――

    /// @notice Handler kind recorded in `ghosts.lastCall` (reset to NONE by the `tracked` modifier).
    enum CallKind {
        NONE,
        SWAP,
        ADD_LIQUIDITY,
        REMOVE_LIQUIDITY,
        DONATE,
        PLACE_ORDER,
        CANCEL_ORDER,
        CLAIM_ORDER,
        WITHDRAW_CLAIM,
        CLAIM_KING,
        FINALIZE_KING,
        REGISTER_STACK,
        SET_ALLOWLIST,
        SET_MERKLE_ROOT,
        SET_MANAGED_FEE,
        SET_TRUSTED_ROUTER,
        SUBMIT_TWAMM,
        REGISTER_REFERRER,
        CURVE_BUY,
        CURVE_SELL,
        TOKEN_TRANSFER,
        LAUNCH,
        OTHER
    }

    /// @notice Curve model recorded per launch curve in `ghosts.curveKind` (native-tick launches stay CURVE_OTHER).
    uint8 internal constant CURVE_OTHER = 0;
    uint8 internal constant CURVE_XYK = 1;
    uint8 internal constant CURVE_TRANCHE = 2;

    /// @notice A TWAMM order submitted through the harness (`rate = floor(total / duration)`, `TWAMMBlock.sol:54`).
    struct TwammOrder {
        uint256 poolIdx;
        bool zeroForOne;
        uint128 rate;
        uint64 expiry;
        uint128 total;
    }

    struct Ghosts {
        // ── Call context (set by handlers before the protocol call; reset by `tracked`) ──
        CallKind lastCall;
        address lastCaller;
        uint256 lastPoolIdx;
        address lastAccount;
        bool lastCallWasWithdraw;
        uint256 trackDepth;
        // ── King of the Pool (derived from before/after snapshots in `_updateDerivedGhosts`) ──
        mapping(PoolId => mapping(uint64 => mapping(Currency => uint256))) kingAdded;
        mapping(PoolId => mapping(uint64 => Currency)) kingFundingCurrency;
        mapping(PoolId => mapping(uint64 => bool)) kingRoundFunded;
        uint256 kingMixedRounds; // additions to a round in a currency other than its funding currency
        mapping(PoolId => mapping(uint64 => bool)) kingClaimed;
        // ── Launch curves ──
        mapping(address curve => uint256) trancheBuys; // successful tranche buys (1 wei rounding slack each)
        mapping(address curve => uint8) curveKind;
        mapping(address curve => uint256) initialCurveSupply; // project tokens the curve held at launch
        mapping(address curve => uint256) tokensDonatedToCurve; // project tokens sent to the curve outside `sell`
        mapping(Currency => uint256) initialSupply; // totalSupply when the currency started being tracked
        // ── TWAMM ──
        TwammOrder[] twammOrders;
        mapping(PoolId => mapping(bool zeroForOne => uint256)) twammSubmitted;
        // ── Anti-snipe / oracle (derived) ──
        mapping(PoolId => bool) antiSnipeDecayed; // live pool whose fee has reached normalFee
        mapping(uint256 poolIdx => uint256) oracleChangedAt; // lower bound on the oracle's last checkpoint time
        mapping(uint256 poolIdx => uint256) oracleWindowStart; // `oracleChangedAt` before the latest change (GL-19)
        // ── Per-pool configuration (setup + `_registerPoolStack_clamped`) ──
        mapping(uint256 poolIdx => address) acManager;
        mapping(uint256 poolIdx => address) feeManager;
        mapping(uint256 poolIdx => uint24) feeCap;
        mapping(uint256 poolIdx => address) authorizedCurve;
        mapping(uint256 poolIdx => bool) merkleRootSet;
        mapping(uint256 poolIdx => uint8) acChecks; // AccessControl checks: bit 0 = beforeSwap, bit 1 = beforeAddLiquidity
        mapping(uint256 poolIdx => uint256) minHold;
        mapping(uint256 poolIdx => uint16) vestingMaxBps;
        mapping(uint256 poolIdx => IHookRigBlock.WalletCapParams) walletCapCfg;
        mapping(uint256 poolIdx => uint256) registeredAtBlock;
        mapping(uint256 poolIdx => uint16[4]) cfgBps; // tax buy, tax sell, fee share, referral
        // ── Liquidity / swaps ──
        mapping(uint256 poolIdx => mapping(bytes32 positionKey => uint256)) lpAddBlock;
        mapping(uint256 poolIdx => mapping(bytes32 positionKey => uint8)) lpAddRoute; // route mode + 1 (0 = unknown)
        // JIT hold keyed like the hook (`keccak256(user, tickLower, tickUpper, salt)`, user = resolved identity)
        mapping(uint256 poolIdx => mapping(bytes32 userKey => uint256)) lpUserAddBlock;
        mapping(PoolId => mapping(address => mapping(uint256 epoch => uint256))) epochStartBal;
        mapping(PoolId => mapping(address => mapping(uint256 epoch => uint256))) soldInEpoch;
        mapping(uint256 poolIdx => uint256) lastOracleTouch;
        uint256 rtNonce;
        uint256 lastSwappedPoolIdx;
    }

    Ghosts internal ghosts;

    /// @notice Limit orders placed by the harness (`_limitOrders` is internal; see also `orchestrator.limitOrder`).
    struct TrackedOrder {
        uint256 id;
        PoolKey key;
        address maker;
        bool closed;
        int24 targetTick;
        bool zeroForOne;
        uint128 inputAmount;
        Currency inputCurrency;
        uint256 paid; // maker balance decrease at placement (ETH via `maker.balance` for native input)
        int24 placeTick; // slot0 tick at placement (0 for the never-initialized `nativeOrderKey`)
        int24 minTickSeen; // updated by `pool_swap*` for open orders on the swapped pool
        int24 maxTickSeen;
        bool limitsEnabled; // pool had BIT_LIMIT_ORDERS at placement
    }

    TrackedOrder[] internal trackedOrders;

    /// @notice Creator vesting slice applied by `_launchMeta` to the next launch (set and reset by the launch handler).
    uint16 internal launchVestingBps;

    // ―――――――――――――――――――――――――― Actors ――――――――――――――――――――――――――

    address[] internal actors;
    address internal actor;
    address internal admin;

    /// @notice Every address that can hold `poolClaims` or King rounds (actors, admin/poolAdmin, TREASURY).
    address[] internal claimants;

    modifier asActor() virtual {
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    modifier asAdmin() virtual {
        vm.startPrank(admin);
        _;
        vm.stopPrank();
    }

    // ―――――――――――――――――――――――― Contracts ―――――――――――――――――――――――――

    PoolManager internal poolManager;
    /// @notice The orchestrator under test, deployed as a getter-only harness (ABI superset of HookRigOrchestrator).
    HookRigOrchestratorHarness internal orchestrator;
    LaunchpadFactory internal launchpadFactory;

    /// @notice Trusted router: the hook resolves the user through `IMsgSender.msgSender()`.
    HookRigTestRouter internal trustedRouter;
    /// @notice Untrusted router: the hook resolves the user from `hookData[0:32]` (or the router itself).
    HookRigTestRouter internal plainRouter;

    MockBurnableERC20 internal token0; // quote side of standard pools and launch curves
    MockBurnableERC20 internal token1; // project side of standard pools

    PoolKey[] internal poolKeys;
    /// @notice Launch curve backing `poolKeys[i]` (address(0) for standard pools).
    address[] internal poolCurves;
    /// @notice Never-initialized key with native `currency0`, used to place native-input limit orders.
    PoolKey internal nativeOrderKey;

    VirtualXYKLaunch[] internal xykCurves;
    SteppedTrancheLaunch[] internal trancheCurves;
    address[] internal launchTokens;
    Currency[] internal trackedCurrencies;

    // ―――――――――――――――――――――――――― Setup ―――――――――――――――――――――――――――

    function setup() internal {
        vm.warp(1_700_000_000);
        vm.roll(10_000);

        admin = address(this);
        vm.label(admin, "Admin");
        _setupCore();
        setupActors();
        _setupStandardPools();
        _setupLaunches();
        _setupGhosts();
    }

    function setupActors() internal {
        for (uint256 i; i < ACTOR_LABELS.length; i++) {
            address _actor = address(new Actor{value: INITIAL_ETH_BALANCE}());
            actors.push(_actor);
            claimants.push(_actor);
            if (ACTOR_LABELS.length > i) {
                vm.label(_actor, ACTOR_LABELS[i]);
            }
            _fundAndApprove(_actor, INITIAL_TOKEN_BALANCE);
        }
        actor = actors[0];

        claimants.push(admin);
        claimants.push(TREASURY);
        _fundAndApprove(admin, ADMIN_TOKEN_BALANCE);
    }

    /// @notice Deploys PoolManager, the mined-address orchestrator, the launchpad, routers, and base tokens.
    function _setupCore() internal {
        poolManager = new PoolManager(address(this));
        orchestrator = _deployOrchestrator();

        LaunchpadDeployer launchpadDeployer =
            new LaunchpadDeployer(poolManager, IHookRigOrchestrator(address(orchestrator)));
        launchpadFactory = launchpadDeployer.factory();

        trustedRouter = new HookRigTestRouter(poolManager);
        plainRouter = new HookRigTestRouter(poolManager);

        orchestrator.setLaunchpadFactory(address(launchpadFactory));
        orchestrator.setTrustedRouter(address(trustedRouter), true);

        MockBurnableERC20 tA = new MockBurnableERC20("Quote Token", "QUOTE");
        MockBurnableERC20 tB = new MockBurnableERC20("Project Token", "PROJ");
        (token0, token1) = address(tA) < address(tB) ? (tA, tB) : (tB, tA);
        trackedCurrencies.push(Currency.wrap(address(token0)));
        trackedCurrencies.push(Currency.wrap(address(token1)));

        vm.label(address(poolManager), "PoolManager");
        vm.label(address(orchestrator), "HookRigOrchestrator");
        vm.label(address(launchpadFactory), "LaunchpadFactory");
        vm.label(address(trustedRouter), "TrustedRouter");
        vm.label(address(plainRouter), "PlainRouter");
        vm.label(address(token0), "Token0");
        vm.label(address(token1), "Token1");
    }

    /// @notice Pools 0..2: multi-block, private, and an initialized-but-unregistered pool.
    function _setupStandardPools() internal {
        // POOL_MULTI — every fee, protection, token-rule, reward, and trading block that can coexist with swaps
        PoolKey memory multiKey = _standardKey(LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        orchestrator.registerPoolStack(multiKey, _multiBlockConfig());
        poolManager.initialize(multiKey, SQRT_PRICE_1_1);
        poolKeys.push(multiKey);
        poolCurves.push(address(0));
        _seedLiquidity(multiKey, -6000, 6000, 10_000_000 ether);

        // POOL_PRIVATE — allowlist-gated swaps/adds plus JIT guard; manager = actors[2]
        PoolKey memory privateKey = _standardKey(3000, 10);
        IHookRigBlock.PoolStackConfig memory privateCfg;
        privateCfg.enabledBlocksBitmap = HookPermissionMasks.BIT_ACCESS_CONTROL | HookPermissionMasks.BIT_JIT_GUARD
            | HookPermissionMasks.BIT_SWAP_REWARDS;
        privateCfg.accessControl = IHookRigBlock.AccessControlParams({
            checkBeforeAddLiquidity: true, checkBeforeSwap: true, merkleRoot: bytes32(0), manager: actors[2]
        });
        privateCfg.mevProtection =
            IHookRigBlock.MEVProtectionParams({maxTickDeltaPerSwap: 0, minLPHoldBlocks: 5, jitExitPenaltyBps: 0});
        privateCfg.swapRewards = IHookRigBlock.SwapRewardsParams({pointsPerUnitVolume: 1e18});
        orchestrator.registerPoolStack(privateKey, privateCfg);
        PoolId privateId = privateKey.toId();
        vm.startPrank(actors[2]);
        orchestrator.setAllowlistAccount(privateId, admin, true);
        orchestrator.setAllowlistAccount(privateId, actors[0], true);
        vm.stopPrank();
        poolManager.initialize(privateKey, SQRT_PRICE_1_1);
        poolKeys.push(privateKey);
        poolCurves.push(address(0));
        _seedLiquidity(privateKey, -6000, 6000, 10_000_000 ether);

        // POOL_UNREGISTERED — initialized without registration; any actor may later register a stack on it
        PoolKey memory unregisteredKey = _standardKey(LPFeeLibrary.DYNAMIC_FEE_FLAG, 30);
        poolManager.initialize(unregisteredKey, SQRT_PRICE_1_1);
        poolKeys.push(unregisteredKey);
        poolCurves.push(address(0));
        _seedLiquidity(unregisteredKey, -6000, 6000, 10_000_000 ether);

        nativeOrderKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(orchestrator))
        });
    }

    /// @notice Pools 3..4: one VirtualXYK launch and one SteppedTranche launch quoted in token0.
    function _setupLaunches() internal {
        IHookRigBlock.PoolStackConfig memory xykStack;
        xykStack.enabledBlocksBitmap = HookPermissionMasks.BIT_ANTI_SNIPE | HookPermissionMasks.BIT_BUY_SELL_TAX
            | HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_KING_OF_THE_POOL;
        xykStack.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 50_000, normalFee: 3000, decayBlocks: 20});
        xykStack.buySellTax = IHookRigBlock.BuySellTaxParams({
            buyTaxBps: 100, sellTaxBps: 100, taxRecipient: actors[1], decayOnly: true
        });
        xykStack.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 100});
        xykStack.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 200, roundDurationSeconds: 600, minBuyAmountForReset: 1 ether
        });
        _launchVirtualXYK(xykStack, _defaultXYKConfig());

        IHookRigBlock.PoolStackConfig memory trancheStack;
        trancheStack.enabledBlocksBitmap = HookPermissionMasks.BIT_KING_OF_THE_POOL;
        trancheStack.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 200, roundDurationSeconds: 600, minBuyAmountForReset: 1 ether
        });
        _launchSteppedTranche(trancheStack, _defaultTrancheConfig());
    }

    /// @notice Seeds the per-pool configuration ghosts for the setup pools (fuzz registrations add their own).
    function _setupGhosts() internal {
        // token0/token1 are minted to actors and admin during setup, so their baseline supply is taken here
        ghosts.initialSupply[Currency.wrap(address(token0))] = token0.totalSupply();
        ghosts.initialSupply[Currency.wrap(address(token1))] = token1.totalSupply();

        ghosts.feeManager[POOL_MULTI] = actors[1];
        ghosts.feeCap[POOL_MULTI] = 10_000;
        ghosts.minHold[POOL_MULTI] = 2;
        ghosts.vestingMaxBps[POOL_MULTI] = 2000;
        ghosts.walletCapCfg[POOL_MULTI] = IHookRigBlock.WalletCapParams({maxWalletBps: 5000, sunsetBlocks: 0});
        ghosts.cfgBps[POOL_MULTI] = [uint16(200), 200, 200, 100];
        ghosts.registeredAtBlock[POOL_MULTI] = block.number;
        ghosts.oracleChangedAt[POOL_MULTI] = block.timestamp; // oracle initialized in setup
        ghosts.lastOracleTouch[POOL_MULTI] = block.timestamp; // oracle checkpoint time = initialization (SP-20)

        ghosts.acManager[POOL_PRIVATE] = actors[2];
        ghosts.minHold[POOL_PRIVATE] = 5;
        ghosts.acChecks[POOL_PRIVATE] = 3; // checkBeforeSwap + checkBeforeAddLiquidity
        ghosts.registeredAtBlock[POOL_PRIVATE] = block.number;

        ghosts.cfgBps[POOL_XYK] = [uint16(100), 100, 0, 0];
    }

    function _multiBlockConfig() internal view returns (IHookRigBlock.PoolStackConfig memory cfg) {
        cfg.enabledBlocksBitmap = HookPermissionMasks.BIT_DYNAMIC_FEE | HookPermissionMasks.BIT_MANAGED_FEE
            | HookPermissionMasks.BIT_ANTI_SNIPE | HookPermissionMasks.BIT_MEV_PROTECTION
            | HookPermissionMasks.BIT_ARB_RECAPTURE | HookPermissionMasks.BIT_WALLET_CAP
            | HookPermissionMasks.BIT_BUY_SELL_TAX | HookPermissionMasks.BIT_AUTO_BURN
            | HookPermissionMasks.BIT_FEE_SHARING | HookPermissionMasks.BIT_LP_REWARDS
            | HookPermissionMasks.BIT_SWAP_REWARDS | HookPermissionMasks.BIT_KING_OF_THE_POOL
            | HookPermissionMasks.BIT_LIMIT_ORDERS | HookPermissionMasks.BIT_TWAMM | HookPermissionMasks.BIT_ORACLE
            | HookPermissionMasks.BIT_JIT_GUARD | HookPermissionMasks.BIT_CIRCUIT_BREAKER
            | HookPermissionMasks.BIT_REFERRAL_SPLIT | HookPermissionMasks.BIT_VESTING_SELL_CAP
            | HookPermissionMasks.BIT_AUTO_BUYBACK;

        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 3000, maxFee: 30_000, volatilityTickThreshold: 40});
        cfg.managedFee = IHookRigBlock.ManagedFeeParams({startingFee: 3000, feeCap: 10_000, manager: actors[1]});
        cfg.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 50_000, normalFee: 3000, decayBlocks: 50});
        cfg.mevProtection =
            IHookRigBlock.MEVProtectionParams({maxTickDeltaPerSwap: 3000, minLPHoldBlocks: 2, jitExitPenaltyBps: 0});
        cfg.arbRecapture = IHookRigBlock.ArbRecaptureParams({recaptureShareBps: 1000, arbTriggerTickDelta: 20});
        cfg.walletCap = IHookRigBlock.WalletCapParams({maxWalletBps: 5000, sunsetBlocks: 0});
        cfg.buySellTax =
            IHookRigBlock.BuySellTaxParams({buyTaxBps: 200, sellTaxBps: 200, taxRecipient: actors[1], decayOnly: true});
        cfg.autoBurn = IHookRigBlock.AutoBurnParams({burnOnBuyBps: 100, useTokenBurnCall: true});
        cfg.feeSharing = IHookRigBlock.FeeSharingParams({
            feeShareBps: 200, primaryRecipient: actors[2], secondaryRecipient: TREASURY, secondaryShareBps: 2500
        });
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 100});
        cfg.swapRewards = IHookRigBlock.SwapRewardsParams({pointsPerUnitVolume: 1e18});
        cfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 200, roundDurationSeconds: 600, minBuyAmountForReset: 10 ether
        });
        cfg.circuitBreaker = IHookRigBlock.CircuitBreakerParams({maxWindowTickDeviation: 3000, windowSeconds: 300});
        cfg.referralSplit = IHookRigBlock.ReferralSplitParams({referralFeeBps: 100});
        cfg.vestingSellCap = IHookRigBlock.VestingSellCapParams({maxDailySellBps: 2000});
        cfg.autoBuyback = IHookRigBlock.AutoBuybackParams({
            buybackFeeBps: 100, triggerFloorTick: -100, minBuybackReserve: 1 ether
        });
        cfg.poolAdmin = admin;
    }

    function _defaultXYKConfig() internal pure returns (ITokenLaunchpad.VirtualXYKConfig memory) {
        return ITokenLaunchpad.VirtualXYKConfig({
            virtualQuoteReserve: 30 ether,
            virtualTokenReserve: 800_000_000 ether,
            graduationQuoteTarget: 50 ether,
            curveTokenAllocation: 800_000_000 ether,
            lpTokenReserve: 200_000_000 ether,
            maxWalletBpsDuringCurve: 0
        });
    }

    function _defaultTrancheConfig() internal pure returns (ITokenLaunchpad.SteppedTrancheConfig memory) {
        return ITokenLaunchpad.SteppedTrancheConfig({
            numTranches: 4,
            basePriceQ96: uint128((uint256(1) << 96) / 10_000_000),
            stepPriceIncrementQ96: uint128((uint256(1) << 96) / 50_000_000),
            graduationQuoteTarget: 20 ether,
            curveTokenAllocation: 800_000_000 ether,
            lpTokenReserve: 200_000_000 ether,
            maxWalletBps: 5000,
            antiSnipeSurchargeBps: 1000,
            antiSnipeBlocks: 10,
            surchargeToKingPotBps: 5000
        });
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    /// @notice CREATE2-mines a salt so the orchestrator address carries exactly its 7 hook permission bits.
    /// @dev Replaces Foundry's `deployCodeTo`, which Medusa/Echidna do not support; reuses one buffer to avoid
    ///      quadratic memory growth across ~2^14 iterations. Deploys the getter-only harness, whose hook
    ///      permissions are identical, so the mined address is valid for it as well.
    function _deployOrchestrator() internal returns (HookRigOrchestratorHarness orc) {
        bytes32 initHash = keccak256(
            abi.encodePacked(type(HookRigOrchestratorHarness).creationCode, abi.encode(poolManager, admin))
        );
        bytes memory buf = abi.encodePacked(bytes1(0xff), address(this), bytes32(0), initHash);
        for (uint256 salt; salt < 1_000_000; salt++) {
            assembly ("memory-safe") {
                mstore(add(buf, 53), salt)
            }
            address predicted = address(uint160(uint256(keccak256(buf))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == ORCHESTRATOR_HOOK_FLAGS) {
                orc = new HookRigOrchestratorHarness{salt: bytes32(salt)}(poolManager, admin);
                require(address(orc) == predicted, "Base: hook mining mismatch");
                return orc;
            }
        }
        revert("Base: hook salt not found");
    }

    function _launchVirtualXYK(
        IHookRigBlock.PoolStackConfig memory stack,
        ITokenLaunchpad.VirtualXYKConfig memory curveCfg
    ) internal returns (VirtualXYKLaunch curve) {
        ITokenLaunchpad.LaunchTokenMetadata memory meta = _launchMeta("XYK Launch", "XYK");
        bytes32 salt = _mineLaunchSalt(meta);
        (address token, address curveAddr, PoolKey memory key) = launchpadFactory.launchVirtualXYK(
            meta, Currency.wrap(address(token0)), 60, IHookRigOrchestrator(address(0)), stack, curveCfg, salt
        );
        curve = VirtualXYKLaunch(payable(curveAddr));
        xykCurves.push(curve);
        ghosts.curveKind[curveAddr] = CURVE_XYK;
        _registerLaunch(token, curveAddr, key);
    }

    function _launchSteppedTranche(
        IHookRigBlock.PoolStackConfig memory stack,
        ITokenLaunchpad.SteppedTrancheConfig memory trancheCfg
    ) internal returns (SteppedTrancheLaunch curve) {
        ITokenLaunchpad.LaunchTokenMetadata memory meta = _launchMeta("Tranche Launch", "TRN");
        bytes32 salt = _mineLaunchSalt(meta);
        (address token, address curveAddr, PoolKey memory key) = launchpadFactory.launchSteppedTranche(
            meta, Currency.wrap(address(token0)), 60, IHookRigOrchestrator(address(0)), stack, trancheCfg, salt
        );
        curve = SteppedTrancheLaunch(payable(curveAddr));
        trancheCurves.push(curve);
        ghosts.curveKind[curveAddr] = CURVE_TRANCHE;
        _registerLaunch(token, curveAddr, key);
    }

    function _launchMeta(string memory name, string memory symbol)
        internal
        view
        returns (ITokenLaunchpad.LaunchTokenMetadata memory)
    {
        return ITokenLaunchpad.LaunchTokenMetadata({
            name: name,
            symbol: symbol,
            totalSupply: 1_000_000_000 ether,
            creator: admin,
            creatorVestingBps: launchVestingBps,
            vestingDurationSeconds: launchVestingBps > 0 ? 1 days : 0
        });
    }

    /// @notice Finds the first salt (offset by launch count) whose token sorts above token0, so token is currency1.
    function _mineLaunchSalt(ITokenLaunchpad.LaunchTokenMetadata memory meta) internal view returns (bytes32) {
        uint256 start = launchpadFactory.totalLaunches() * 10_000 + 1;
        for (uint256 i = start; i < start + 10_000; i++) {
            address predicted = launchpadFactory.predictTokenAddress(meta, bytes32(i));
            if (uint160(predicted) > uint160(address(token0)) && predicted.code.length == 0) {
                return bytes32(i);
            }
        }
        revert("Base: launch salt not found");
    }

    /// @notice Tracks a new launch and gives every actor and the admin allowances for its token and curve.
    function _registerLaunch(address token, address curve, PoolKey memory key) internal {
        ghosts.authorizedCurve[poolKeys.length] = curve;
        ghosts.registeredAtBlock[poolKeys.length] = block.number;
        ghosts.initialCurveSupply[curve] = MockBurnableERC20(token).balanceOf(curve);
        ghosts.initialSupply[Currency.wrap(token)] = MockBurnableERC20(token).totalSupply();
        launchTokens.push(token);
        poolKeys.push(key);
        poolCurves.push(curve);
        trackedCurrencies.push(Currency.wrap(token));
        vm.label(token, string.concat("LaunchToken", toString(launchTokens.length)));
        vm.label(curve, string.concat("LaunchCurve", toString(launchTokens.length)));
        for (uint256 i; i < actors.length; i++) {
            _approveLaunch(actors[i], token, curve);
        }
        _approveLaunch(admin, token, curve);
    }

    function _approveLaunch(address account, address token, address curve) internal {
        vm.startPrank(account);
        token0.approve(curve, type(uint256).max);
        MockBurnableERC20(token).approve(curve, type(uint256).max);
        MockBurnableERC20(token).approve(address(trustedRouter), type(uint256).max);
        MockBurnableERC20(token).approve(address(plainRouter), type(uint256).max);
        MockBurnableERC20(token).approve(address(orchestrator), type(uint256).max);
        vm.stopPrank();
    }

    function _fundAndApprove(address account, uint256 amount) internal {
        token0.mint(account, amount);
        token1.mint(account, amount);
        vm.startPrank(account);
        token0.approve(address(trustedRouter), type(uint256).max);
        token1.approve(address(trustedRouter), type(uint256).max);
        token0.approve(address(plainRouter), type(uint256).max);
        token1.approve(address(plainRouter), type(uint256).max);
        token0.approve(address(orchestrator), type(uint256).max);
        token1.approve(address(orchestrator), type(uint256).max);
        vm.stopPrank();
    }

    function _standardKey(uint24 fee, int24 tickSpacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(orchestrator))
        });
    }

    function _seedLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) internal {
        trustedRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)
            }),
            ""
        );
    }

    /// @notice Maps a seed to a known pool index.
    function _poolIdx(uint256 seed) internal view returns (uint256) {
        return seed % poolKeys.length;
    }

    /// @notice A pool is live once PoolManager has initialized it (launch pools only after graduation).
    function _isPoolLive(uint256 idx) internal view returns (bool) {
        address curve = poolCurves[idx];
        return curve == address(0) || _launchState(curve) == uint8(ITokenLaunchpad.LaunchState.Graduated);
    }

    function _launchState(address curve) internal view returns (uint8 state) {
        (bool ok, bytes memory data) = curve.staticcall(abi.encodeWithSignature("launchState()"));
        if (ok && data.length >= 32) state = abi.decode(data, (uint8));
    }

    /// @notice Balance of `account` in `currency` (native via `account.balance`); 0 if the token call fails.
    function _currencyBalance(Currency currency, address account) internal view returns (uint256 bal) {
        if (currency.isAddressZero()) return account.balance;
        (bool ok, bytes memory data) =
            Currency.unwrap(currency).staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        if (ok && data.length >= 32) bal = abi.decode(data, (uint256));
    }

    /// @notice Index of `currency` in `trackedCurrencies`, or `type(uint256).max` when untracked.
    function _currencyIdx(Currency currency) internal view returns (uint256) {
        for (uint256 i; i < trackedCurrencies.length; i++) {
            if (trackedCurrencies[i] == currency) return i;
        }
        return type(uint256).max;
    }

    /// @notice Per-actor position salt so positions opened through a shared router stay separate in PoolManager.
    function _positionSalt(address owner) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(owner)));
    }

    // Maps an arbitrary address to an actor address
    function toActor(address addy) internal view returns (address) {
        return actors[uint256(uint160(addy)) % actors.length];
    }

    // Maps an arbitrary address to an actor address that is different from the current actor
    function toActorNotCurrent(address addy) internal view returns (address) {
        address _actor = actors[uint256(uint160(addy)) % actors.length];
        if (_actor == actor) {
            _actor = actors[(uint256(uint160(addy)) + 1) % actors.length];
        }
        return _actor;
    }

    // Sums the native token balances of all actors
    function sumActorsBalances() internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            sumOfBalances += actors[i].balance;
        }
    }

    // Sums the ERC-20 token balances of all actors for a given token
    function sumActorsERC20Balances(address _token) internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            bytes memory data = abi.encodeWithSignature("balanceOf(address)", actors[i]);
            (bool success, bytes memory result) = _token.staticcall(data);
            require(success, "sumActorsERC20Balances: failed to get balance");
            sumOfBalances += abi.decode(result, (uint256));
        }
    }

    function skipBlocks(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * BLOCK_INTERVAL);
    }

    function skipTime(uint256 time) internal {
        uint256 blocks = (time + BLOCK_INTERVAL - 1) / BLOCK_INTERVAL;
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + time);
    }
}
