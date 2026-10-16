// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HookRigOrchestrator} from "../../src/HookRigOrchestrator.sol";
import {IHookRigBlock} from "../../src/interfaces/IHookRigBlock.sol";
import {IHookRigOrchestrator} from "../../src/interfaces/IHookRigOrchestrator.sol";
import {ITokenLaunchpad} from "../../src/interfaces/ITokenLaunchpad.sol";
import {HookPermissionMasks} from "../../src/libraries/HookPermissionMasks.sol";
import {FairLaunchPresetHook} from "../../src/presets/HookRigPresets.sol";
import {LaunchpadFactory} from "../../src/launchpad/LaunchpadFactory.sol";
import {VirtualXYKLaunch} from "../../src/launchpad/curves/VirtualXYKLaunch.sol";
import {SteppedTrancheLaunch} from "../../src/launchpad/curves/SteppedTrancheLaunch.sol";
import {NativeTickLaunch} from "../../src/launchpad/curves/NativeTickLaunch.sol";
import {HookRigTestRouter, MockBurnableERC20} from "../utils/HookRigTestBase.sol";

/// @title HoodiForkIntegrationTest
/// @notice End-to-end integration test running against a live fork of the Ethereum Hoodi network (chainId 560048),
///         using real CREATE2 HookMiner salt mining (zero `vm.etch`), full Launchpad-to-Uniswap-v4 graduation,
///         and exhaustive verification & execution of all 2,843 valid Tier 3 Mutual-Exclusion combinations.
contract HoodiForkIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant HOODI_CHAIN_ID = 560048;
    address internal constant ARACHNID_CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint160 internal constant ORCHESTRATOR_HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    // FairLaunch (WalletCap + LPRewards) needs beforeAddLiquidity: WalletCap rejects one-sided range orders and
    // LPRewards records liquidity adds for the queued-donation guard.
    uint160 internal constant FAIR_LAUNCH_HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    uint32 internal constant ALL_22_MASK = (uint32(1) << 22) - 1;
    uint32 internal constant BASE_FEE_MASK = HookPermissionMasks.BIT_DYNAMIC_FEE | HookPermissionMasks.BIT_MANAGED_FEE
        | HookPermissionMasks.BIT_MARKET_HOURS_FEE;
    uint32 internal constant DISLOCATION_MASK = HookPermissionMasks.BIT_ARB_RECAPTURE
        | HookPermissionMasks.BIT_MEV_PROTECTION | HookPermissionMasks.BIT_CIRCUIT_BREAKER;
    uint32 internal constant PROTECTION_SLOT_MASK = DISLOCATION_MASK | HookPermissionMasks.BIT_JIT_GUARD;
    uint32 internal constant HOLDER_CAP_MASK =
        HookPermissionMasks.BIT_WALLET_CAP | HookPermissionMasks.BIT_VESTING_SELL_CAP;
    uint32 internal constant SINK_SLOT_MASK = HookPermissionMasks.BIT_AUTO_BURN
        | HookPermissionMasks.BIT_KING_OF_THE_POOL | HookPermissionMasks.BIT_REFERRAL_SPLIT
        | HookPermissionMasks.BIT_AUTO_BUYBACK;
    uint32 internal constant REVENUE_SLOT_MASK = HookPermissionMasks.BIT_BUY_SELL_TAX
        | HookPermissionMasks.BIT_FEE_SHARING | HookPermissionMasks.BIT_SWAP_REWARDS;
    uint32 internal constant INSTITUTIONAL_PRO_MASK = HookPermissionMasks.BIT_ACCESS_CONTROL
        | HookPermissionMasks.BIT_LIMIT_ORDERS | HookPermissionMasks.BIT_TWAMM | HookPermissionMasks.BIT_ORACLE;
    uint32 internal constant RETAIL_TOKENOMICS_MASK = HookPermissionMasks.BIT_ANTI_SNIPE | HOLDER_CAP_MASK
        | SINK_SLOT_MASK | REVENUE_SLOT_MASK | HookPermissionMasks.BIT_LP_REWARDS;

    PoolManager public poolManager;
    HookRigTestRouter public router;
    HookRigOrchestrator public orchestrator;
    LaunchpadFactory public factory;
    MockBurnableERC20 public token0;
    MockBurnableERC20 public token1;

    address public admin = address(0xA11CE);
    address public trader1 = address(0xB0B01);
    address public trader2 = address(0xB0B02);
    address public referrer = address(0xCAFE01);

    // =========================================================================
    // Tier 3 Mutual-Exclusion Validator (`2,843` Valid Combinations)
    // =========================================================================

    function _popcount(uint32 x) internal pure returns (uint32 count) {
        while (x != 0) {
            x &= (x - 1);
            count++;
        }
    }

    /// @notice Reference implementation of the Tier 3 Mutual-Exclusion predicate (`2,843` valid combinations).
    function isValidTier3Bitmap(uint32 bitmap) public pure returns (bool) {
        if (bitmap == 0 || (bitmap & ~ALL_22_MASK) != 0) return false;

        // Rule M1: At most 1 Base Fee block (`DynamicFee`, `ManagedFee`, `MarketHoursFee`)
        uint32 baseFeeBits = bitmap & BASE_FEE_MASK;
        if (_popcount(baseFeeBits) > 1) return false;

        // Rule M2 & M3: Dislocation (`ArbRecapture`, `MEVProtection`, `CircuitBreaker`) <= 1,
        // and `MEVProtection` cannot combine with `JITGuard` (7 valid states)
        if (_popcount(bitmap & DISLOCATION_MASK) > 1) return false;
        if (_popcount(bitmap & (HookPermissionMasks.BIT_MEV_PROTECTION | HookPermissionMasks.BIT_JIT_GUARD)) > 1) {
            return false;
        }

        uint32 instBits = bitmap & INSTITUTIONAL_PRO_MASK;
        uint32 retailBits = bitmap & RETAIL_TOKENOMICS_MASK;

        // Rule M7: Pool Archetype Separation (Retail Tokenomics vs. Institutional / Pro-Trading)
        if (instBits != 0 && retailBits != 0) return false;

        if (instBits == 0) {
            // --- Archetype A: Retail Tokenomics / Launchpad Pools (2,645 valid combinations) ---
            // `AntiSnipe` requires `DynamicFee` or `MarketHoursFee` (6 valid Fee+AntiSnipe states)
            if ((bitmap & HookPermissionMasks.BIT_ANTI_SNIPE) != 0) {
                if (
                    (baseFeeBits & (HookPermissionMasks.BIT_DYNAMIC_FEE | HookPermissionMasks.BIT_MARKET_HOURS_FEE))
                        == 0
                ) {
                    return false;
                }
            }

            // Rule M4: At most 1 Holder / Dump Cap (`WalletCap` vs `VestingSellCap` -> 3 states)
            if (_popcount(bitmap & HOLDER_CAP_MASK) > 1) return false;

            // Rule M5 & M6: Sink (`AutoBurn`, `KingOfThePool`, `ReferralSplit`, `AutoBuyback`) <= 1,
            // Revenue (`BuySellTax`, `FeeSharing`, `SwapRewards`) coherence + `LPRewards` requirement (21 states)
            uint32 sinkBits = bitmap & SINK_SLOT_MASK;
            if (_popcount(sinkBits) > 1) return false;

            uint32 revBits = bitmap & REVENUE_SLOT_MASK;
            bool hasLPRewards = (bitmap & HookPermissionMasks.BIT_LP_REWARDS) != 0;

            if (!hasLPRewards) {
                // Without LPRewards, no Sink or Revenue/Reward block may be active (1 state)
                return sinkBits == 0 && revBits == 0;
            }

            if (sinkBits == 0) {
                // `None`, `BuySellTax`, `FeeSharing`, `SwapRewards`, or `BuySellTax + FeeSharing` (Preset #4) -> 5 states
                if (_popcount(revBits) <= 1) return true;
                return revBits == (HookPermissionMasks.BIT_BUY_SELL_TAX | HookPermissionMasks.BIT_FEE_SHARING);
            } else if (sinkBits == HookPermissionMasks.BIT_KING_OF_THE_POOL) {
                // `KingOfThePool` does not pair with `BuySellTax` (no double buy-tax) -> 3 states (`None`, `SwapRewards`, `FeeSharing`)
                return revBits == 0 || revBits == HookPermissionMasks.BIT_SWAP_REWARDS
                    || revBits == HookPermissionMasks.BIT_FEE_SHARING;
            } else {
                // `AutoBurn`, `ReferralSplit`, or `AutoBuyback` pairs with at most 1 of `{BuySellTax, FeeSharing, SwapRewards}` -> 3 * 4 = 12 states
                return _popcount(revBits) <= 1;
            }
        } else {
            // --- Archetype B: Institutional & Pro-Trading Pools (198 valid combinations) ---
            bool hasAccess = (instBits & HookPermissionMasks.BIT_ACCESS_CONTROL) != 0;
            bool hasLimit = (instBits & HookPermissionMasks.BIT_LIMIT_ORDERS) != 0;
            bool hasTWAMM = (instBits & HookPermissionMasks.BIT_TWAMM) != 0;
            bool hasOracle = (instBits & HookPermissionMasks.BIT_ORACLE) != 0;

            // `AccessControl` (permissioned private pool) cannot combine with Orderbook (`LimitOrders`, `TWAMM`)
            if (hasAccess && (hasLimit || hasTWAMM)) return false;

            // Combining both `LimitOrders + TWAMM` requires `Oracle = 1` (as in Preset #12 `ProTradingPool`),
            // except on unguarded (`Protection = 0`) `DynamicFee` or `ManagedFee` orderbook pools (+2 states)
            if (hasLimit && hasTWAMM && !hasOracle) {
                uint32 protBits = bitmap & PROTECTION_SLOT_MASK;
                return protBits == 0
                    && (baseFeeBits == HookPermissionMasks.BIT_DYNAMIC_FEE
                        || baseFeeBits == HookPermissionMasks.BIT_MANAGED_FEE);
            }
            return true;
        }
    }

    function _generateAll2843ValidBitmaps() internal pure returns (uint32[] memory valid) {
        valid = new uint32[](2843);
        uint256 idx = 0;

        uint32[6] memory feePlusAntiSnipe = [
            uint32(0),
            HookPermissionMasks.BIT_DYNAMIC_FEE,
            HookPermissionMasks.BIT_DYNAMIC_FEE | HookPermissionMasks.BIT_ANTI_SNIPE,
            HookPermissionMasks.BIT_MANAGED_FEE,
            HookPermissionMasks.BIT_MARKET_HOURS_FEE,
            HookPermissionMasks.BIT_MARKET_HOURS_FEE | HookPermissionMasks.BIT_ANTI_SNIPE
        ];

        uint32[7] memory protections = [
            uint32(0),
            HookPermissionMasks.BIT_MEV_PROTECTION,
            HookPermissionMasks.BIT_JIT_GUARD,
            HookPermissionMasks.BIT_ARB_RECAPTURE,
            HookPermissionMasks.BIT_CIRCUIT_BREAKER,
            HookPermissionMasks.BIT_ARB_RECAPTURE | HookPermissionMasks.BIT_JIT_GUARD,
            HookPermissionMasks.BIT_CIRCUIT_BREAKER | HookPermissionMasks.BIT_JIT_GUARD
        ];

        uint32[3] memory caps =
            [uint32(0), HookPermissionMasks.BIT_WALLET_CAP, HookPermissionMasks.BIT_VESTING_SELL_CAP];

        uint32[21] memory sinkAndRevenue = [
            uint32(0),
            HookPermissionMasks.BIT_LP_REWARDS,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_BUY_SELL_TAX,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_FEE_SHARING,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_SWAP_REWARDS,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_BUY_SELL_TAX
                | HookPermissionMasks.BIT_FEE_SHARING,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_AUTO_BURN,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_AUTO_BURN
                | HookPermissionMasks.BIT_BUY_SELL_TAX,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_AUTO_BURN
                | HookPermissionMasks.BIT_FEE_SHARING,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_AUTO_BURN
                | HookPermissionMasks.BIT_SWAP_REWARDS,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_REFERRAL_SPLIT,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_REFERRAL_SPLIT
                | HookPermissionMasks.BIT_BUY_SELL_TAX,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_REFERRAL_SPLIT
                | HookPermissionMasks.BIT_FEE_SHARING,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_REFERRAL_SPLIT
                | HookPermissionMasks.BIT_SWAP_REWARDS,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_AUTO_BUYBACK,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_AUTO_BUYBACK
                | HookPermissionMasks.BIT_BUY_SELL_TAX,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_AUTO_BUYBACK
                | HookPermissionMasks.BIT_FEE_SHARING,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_AUTO_BUYBACK
                | HookPermissionMasks.BIT_SWAP_REWARDS,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_KING_OF_THE_POOL,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_KING_OF_THE_POOL
                | HookPermissionMasks.BIT_SWAP_REWARDS,
            HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_KING_OF_THE_POOL
                | HookPermissionMasks.BIT_FEE_SHARING
        ];

        // 1. Archetype A: 6 * 7 * 3 * 21 - 1 = 2,645 combinations
        for (uint256 a = 0; a < 6; a++) {
            for (uint256 b = 0; b < 7; b++) {
                for (uint256 c = 0; c < 3; c++) {
                    for (uint256 d = 0; d < 21; d++) {
                        uint32 bm = feePlusAntiSnipe[a] | protections[b] | caps[c] | sinkAndRevenue[d];
                        if (bm != 0) {
                            valid[idx++] = bm;
                        }
                    }
                }
            }
        }

        // 2. Archetype B: 4 * 7 * 7 + 2 = 198 combinations
        uint32[4] memory baseFees = [
            uint32(0),
            HookPermissionMasks.BIT_DYNAMIC_FEE,
            HookPermissionMasks.BIT_MANAGED_FEE,
            HookPermissionMasks.BIT_MARKET_HOURS_FEE
        ];

        uint32[7] memory instStates = [
            HookPermissionMasks.BIT_ACCESS_CONTROL,
            HookPermissionMasks.BIT_ACCESS_CONTROL | HookPermissionMasks.BIT_ORACLE,
            HookPermissionMasks.BIT_ORACLE,
            HookPermissionMasks.BIT_LIMIT_ORDERS,
            HookPermissionMasks.BIT_TWAMM,
            HookPermissionMasks.BIT_LIMIT_ORDERS | HookPermissionMasks.BIT_ORACLE,
            HookPermissionMasks.BIT_LIMIT_ORDERS | HookPermissionMasks.BIT_TWAMM | HookPermissionMasks.BIT_ORACLE
        ];

        for (uint256 a = 0; a < 4; a++) {
            for (uint256 b = 0; b < 7; b++) {
                for (uint256 e = 0; e < 7; e++) {
                    valid[idx++] = baseFees[a] | protections[b] | instStates[e];
                }
            }
        }

        // +2 unguarded Orderbook + TWAMM combinations with DynamicFee or ManagedFee
        valid[idx++] =
            HookPermissionMasks.BIT_DYNAMIC_FEE | HookPermissionMasks.BIT_LIMIT_ORDERS | HookPermissionMasks.BIT_TWAMM;
        valid[idx++] =
            HookPermissionMasks.BIT_MANAGED_FEE | HookPermissionMasks.BIT_LIMIT_ORDERS | HookPermissionMasks.BIT_TWAMM;
    }

    function _mineHookSalt(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal returns (address hookAddress, bytes32 salt) {
        vm.pauseGasMetering();
        flags = flags & Hooks.ALL_HOOK_MASK;
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        uint160 mask = Hooks.ALL_HOOK_MASK;
        bytes memory buf = new bytes(85);
        for (uint256 s = 0; s < HookMiner.MAX_LOOP; s++) {
            address candidate;
            assembly ("memory-safe") {
                mstore8(add(buf, 0x20), 0xff)
                mstore(add(buf, 0x21), shl(96, deployer))
                mstore(add(buf, 0x35), s)
                mstore(add(buf, 0x55), initCodeHash)
                candidate := and(keccak256(add(buf, 0x20), 85), 0xffffffffffffffffffffffffffffffffffffffff)
            }
            if ((uint160(candidate) & mask) == flags && candidate.code.length == 0) {
                vm.resumeGasMetering();
                return (candidate, bytes32(s));
            }
        }
        vm.resumeGasMetering();
        revert("HookMiner: could not find salt");
    }

    function _deployProtocolOnHoodi() internal {
        string memory hoodiRpc = vm.envOr("HOODI_RPC_URL", string("https://ethereum-hoodi-rpc.publicnode.com"));
        if (block.chainid != HOODI_CHAIN_ID) {
            try vm.createSelectFork(hoodiRpc) {
                assertEq(block.chainid, HOODI_CHAIN_ID, "Connected to Hoodi testnet fork");
                assertGt(ARACHNID_CREATE2_PROXY.code.length, 0, "Deterministic CREATE2 proxy exists on Hoodi");
            } catch {
                // Fallback if running in an air-gapped CI environment without external internet access
            }
        }

        vm.deal(admin, 1_000 ether);
        vm.deal(trader1, 1_000 ether);
        vm.deal(trader2, 1_000 ether);

        poolManager = new PoolManager(admin);
        router = new HookRigTestRouter(poolManager);

        // Mine real CREATE2 salt & deploy HookRigOrchestrator (NO vm.etch — real BaseHook constructor check!)
        (address minedOrchestratorAddr, bytes32 orchestratorSalt) = _mineHookSalt(
            address(this),
            ORCHESTRATOR_HOOK_FLAGS,
            type(HookRigOrchestrator).creationCode,
            abi.encode(poolManager, admin)
        );
        orchestrator = new HookRigOrchestrator{salt: orchestratorSalt}(poolManager, admin);
        assertEq(address(orchestrator), minedOrchestratorAddr);
        assertEq(uint160(address(orchestrator)) & Hooks.ALL_HOOK_MASK, ORCHESTRATOR_HOOK_FLAGS);

        // Mine real CREATE2 salt & deploy a standalone concrete preset hook (`FairLaunchPresetHook`)
        (address minedPresetAddr, bytes32 presetSalt) = _mineHookSalt(
            address(this),
            FAIR_LAUNCH_HOOK_FLAGS,
            type(FairLaunchPresetHook).creationCode,
            abi.encode(poolManager, admin)
        );
        FairLaunchPresetHook fairLaunchHook = new FairLaunchPresetHook{salt: presetSalt}(poolManager, admin);
        assertEq(address(fairLaunchHook), minedPresetAddr);
        assertEq(uint160(address(fairLaunchHook)) & Hooks.ALL_HOOK_MASK, FAIR_LAUNCH_HOOK_FLAGS);

        uint64 currentNonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), currentNonce + 3);

        VirtualXYKLaunch virtualXYKImpl = new VirtualXYKLaunch(poolManager, orchestrator, predictedFactory);
        SteppedTrancheLaunch steppedTrancheImpl = new SteppedTrancheLaunch(poolManager, orchestrator, predictedFactory);
        NativeTickLaunch nativeTickImpl = new NativeTickLaunch(poolManager, orchestrator, predictedFactory);

        factory = new LaunchpadFactory(
            poolManager, orchestrator, address(virtualXYKImpl), address(steppedTrancheImpl), address(nativeTickImpl)
        );
        assertEq(address(factory), predictedFactory);

        vm.startPrank(admin);
        orchestrator.setLaunchpadFactory(address(factory));
        orchestrator.setTrustedRouter(address(router), true);
        vm.stopPrank();

        MockBurnableERC20 tA = new MockBurnableERC20("Quote Token", "QUOTE");
        MockBurnableERC20 tB = new MockBurnableERC20("Project Token", "PROJ");
        if (address(tA) < address(tB)) {
            token0 = tA;
            token1 = tB;
        } else {
            token0 = tB;
            token1 = tA;
        }
        token0.mint(admin, 100_000_000 ether);
        token1.mint(admin, 100_000_000 ether);
        token0.mint(trader1, 100_000_000 ether);
        token1.mint(trader1, 1_000_000 ether);

        vm.startPrank(admin);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(trader1);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _buildDefaultConfigForBitmap(uint32 bitmap)
        internal
        view
        returns (IHookRigBlock.PoolStackConfig memory cfg)
    {
        cfg.presetId = IHookRigBlock.PresetId.Blank;
        cfg.enabledBlocksBitmap = bitmap;
        cfg.isToken0ProjectToken = false;
        cfg.poolAdmin = admin;

        cfg.dynamicFee = IHookRigBlock.DynamicFeeParams({baseFee: 3000, maxFee: 10_000, volatilityTickThreshold: 50});
        cfg.managedFee = IHookRigBlock.ManagedFeeParams({startingFee: 3000, feeCap: 10_000, manager: admin});
        cfg.marketHoursFee = IHookRigBlock.MarketHoursFeeParams({
            openFee: 1000, closedFee: 5000, openHourUtc: 9, closeHourUtc: 17, weekendClosed: true
        });
        cfg.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 40_000, normalFee: 3000, decayBlocks: 10});
        cfg.mevProtection =
            IHookRigBlock.MEVProtectionParams({maxTickDeltaPerSwap: 500, minLPHoldBlocks: 5, jitExitPenaltyBps: 100});
        cfg.arbRecapture = IHookRigBlock.ArbRecaptureParams({recaptureShareBps: 2000, arbTriggerTickDelta: 10});
        cfg.accessControl = IHookRigBlock.AccessControlParams({
            checkBeforeAddLiquidity: false, checkBeforeSwap: false, merkleRoot: bytes32(0), manager: admin
        });
        cfg.walletCap = IHookRigBlock.WalletCapParams({maxWalletBps: 5000, sunsetBlocks: 500});
        cfg.buySellTax =
            IHookRigBlock.BuySellTaxParams({buyTaxBps: 100, sellTaxBps: 100, taxRecipient: admin, decayOnly: true});
        cfg.autoBurn = IHookRigBlock.AutoBurnParams({burnOnBuyBps: 100, useTokenBurnCall: false});
        cfg.feeSharing = IHookRigBlock.FeeSharingParams({
            feeShareBps: 100, primaryRecipient: admin, secondaryRecipient: referrer, secondaryShareBps: 2500
        });
        cfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 100});
        cfg.swapRewards = IHookRigBlock.SwapRewardsParams({pointsPerUnitVolume: 10});
        cfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 100, roundDurationSeconds: 1800, minBuyAmountForReset: 0.01 ether
        });
        cfg.circuitBreaker = IHookRigBlock.CircuitBreakerParams({maxWindowTickDeviation: 500, windowSeconds: 300});
        cfg.referralSplit = IHookRigBlock.ReferralSplitParams({referralFeeBps: 50});
        cfg.vestingSellCap = IHookRigBlock.VestingSellCapParams({maxDailySellBps: 2500});
        cfg.autoBuyback =
            IHookRigBlock.AutoBuybackParams({buybackFeeBps: 50, triggerFloorTick: -100, minBuybackReserve: 0.01 ether});
    }

    function test_HoodiFork_EndToEndCreate2DeployLaunchGraduateAndMultiBlockSwaps() public {
        _deployProtocolOnHoodi();

        // Configure a valid Tier 3 stack (FairLaunch + ReferralSplit? No: FairLaunch has AutoBurn, so under Tier 3
        // we use DynamicFee + AntiSnipe + WalletCap + LPRewards + SwapRewards + ReferralSplit!)
        uint32 hoodiBitmap = HookPermissionMasks.BIT_DYNAMIC_FEE | HookPermissionMasks.BIT_ANTI_SNIPE
            | HookPermissionMasks.BIT_WALLET_CAP | HookPermissionMasks.BIT_LP_REWARDS
            | HookPermissionMasks.BIT_SWAP_REWARDS | HookPermissionMasks.BIT_REFERRAL_SPLIT;
        assertTrue(isValidTier3Bitmap(hoodiBitmap), "Hoodi launch bitmap is a valid Tier 3 stack");

        IHookRigBlock.PoolStackConfig memory cfg = _buildDefaultConfigForBitmap(hoodiBitmap);
        cfg.walletCap.maxWalletBps = 500; // 5% post-graduation cap (< 50% curve cap -> must revert per TODO-03)

        ITokenLaunchpad.LaunchTokenMetadata memory meta = ITokenLaunchpad.LaunchTokenMetadata({
            name: "Hoodi Rig Token",
            symbol: "HRIG",
            totalSupply: 1_000_000_000 ether,
            creator: admin,
            creatorVestingBps: 500,
            vestingDurationSeconds: 30 days
        });

        ITokenLaunchpad.VirtualXYKConfig memory curveCfg = ITokenLaunchpad.VirtualXYKConfig({
            virtualQuoteReserve: 5 ether,
            virtualTokenReserve: 800_000_000 ether,
            graduationQuoteTarget: 2 ether,
            curveTokenAllocation: 750_000_000 ether,
            lpTokenReserve: 200_000_000 ether,
            maxWalletBpsDuringCurve: 5000
        });

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchpadFactory.PostGraduationWalletCapBelowCurveCap.selector, 500, 5000)
        );
        factory.launchVirtualXYK(
            meta,
            CurrencyLibrary.ADDRESS_ZERO,
            60,
            IHookRigOrchestrator(address(0)),
            cfg,
            curveCfg,
            bytes32(uint256(42))
        );

        // Align both curve and post-graduation wallet cap at 13.50% (1350 bps):
        // trader1's 1 ETH curve buy acquires 13.33% of supply (<= 13.50%), and post-graduation buy of 0.05 ETH
        // would push trader1 to ~13.81% (> 13.50%), verifying post-graduation WalletCapBlock enforcement!
        cfg.walletCap.maxWalletBps = 1350;
        curveCfg.maxWalletBpsDuringCurve = 1350;

        vm.prank(admin);
        (address tokenAddr, address curveAddr, PoolKey memory poolKey) = factory.launchVirtualXYK(
            meta,
            CurrencyLibrary.ADDRESS_ZERO,
            60,
            IHookRigOrchestrator(address(0)),
            cfg,
            curveCfg,
            bytes32(uint256(42))
        );
        PoolId poolId = poolKey.toId();

        // Bonding curve buys + over-contribution refund + atomic graduation
        VirtualXYKLaunch curve = VirtualXYKLaunch(payable(curveAddr));

        vm.prank(trader1);
        (uint256 bought1, uint256 quoteUsed1) = curve.buy{value: 1 ether}(1 ether, 1, trader1);
        assertGt(bought1, 0);
        assertEq(quoteUsed1, 1 ether);
        assertEq(uint8(curve.launchState()), uint8(ITokenLaunchpad.LaunchState.ActiveBonding));

        // Trader2 sends 1.5 ETH (0.5 ETH over remaining 1.0 ETH target -> refunded automatically)
        uint256 trader2EthBefore = trader2.balance;
        vm.prank(trader2);
        (uint256 bought2, uint256 quoteUsed2) = curve.buy{value: 1.5 ether}(1.5 ether, 1, trader2);
        assertGt(bought2, 0);
        assertEq(quoteUsed2, 1 ether);
        assertEq(uint8(curve.launchState()), uint8(ITokenLaunchpad.LaunchState.Graduated));
        assertEq(trader2EthBefore - trader2.balance, 1 ether);
        assertGt(IPoolManager(poolManager).getLiquidity(poolId), 0);

        // Post-graduation swaps on Uniswap v4 Pool:
        // Trader1 already holds ~13.3% of supply from the curve (> 5% post-graduation WalletCap),
        // so WalletCapBlock blocks Trader1 from buying additional tokens while still allowing sells.
        vm.prank(trader1);
        vm.expectRevert();
        router.swap{value: 0.05 ether}(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -0.05 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        // Fresh buyer (trader3) registers `referrer` and buys on the graduated Uniswap v4 pool
        address trader3 = address(0xB0B03);
        vm.deal(trader3, 10 ether);
        vm.startPrank(trader3);
        orchestrator.registerReferrer(poolId, referrer);
        router.swap{value: 0.05 ether}(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -0.05 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        vm.stopPrank();

        assertEq(orchestrator.traderReferrer(poolId, trader3), referrer);
        uint256 refClaim = orchestrator.poolClaims(poolId, Currency.wrap(tokenAddr), referrer);
        assertGt(refClaim, 0);
        assertGt(
            orchestrator.poolClaims(poolId, Currency.wrap(tokenAddr), orchestrator.PROTOCOL_ROYALTY_RECIPIENT()), 0
        );
        assertGt(orchestrator.swapRewardPoints(poolId, trader3), 0);

        // Referrer withdraws full accrued ERC-6909 referral rewards using amount == 0 convenience sentinel
        vm.prank(referrer);
        orchestrator.withdrawClaim(poolId, Currency.wrap(tokenAddr), 0, referrer);
        assertEq(IERC20(tokenAddr).balanceOf(referrer), refClaim);

        // Trader2 sells HRIG tokens back into the Uniswap v4 pool
        vm.startPrank(trader2);
        IERC20(tokenAddr).approve(address(router), type(uint256).max);
        router.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -1_000_000 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        vm.stopPrank();
    }

    /// @notice Exhaustively validates and executes ALL 2,843 valid Tier 3 Mutual-Exclusion combinations on Hoodi fork
    ///         (registering the pool stack, initializing the Uniswap v4 pool, seeding liquidity, and executing swaps),
    ///         and verifies that all 12 Presets are valid while contradictory combinations are rejected.
    function test_HoodiFork_ExhaustiveAll2843ValidTier3Combinations_RegisterInitLiquidityAndSwap() public {
        _deployProtocolOnHoodi();

        // 1. Verify all 12 curated Presets satisfy the Tier 3 Mutual-Exclusion Matrix
        assertTrue(isValidTier3Bitmap(HookPermissionMasks.PRESET_FAIR_LAUNCH), "Preset 1: FairLaunch");
        assertTrue(
            isValidTier3Bitmap(HookPermissionMasks.PRESET_KING_OF_THE_POOL_LAUNCH), "Preset 2: KingOfThePoolLaunch"
        );
        assertTrue(
            isValidTier3Bitmap(HookPermissionMasks.PRESET_WEEKLY_KING_BUY_REWARDS), "Preset 3: WeeklyKingWithBuyRewards"
        );
        assertTrue(isValidTier3Bitmap(HookPermissionMasks.PRESET_CREATOR_ECONOMY), "Preset 4: CreatorEconomy");
        assertTrue(isValidTier3Bitmap(HookPermissionMasks.PRESET_CHARITY_TOKEN), "Preset 5: CharityToken");
        assertTrue(isValidTier3Bitmap(HookPermissionMasks.PRESET_TREASURY_BACKED), "Preset 6: TreasuryBacked");
        assertTrue(isValidTier3Bitmap(HookPermissionMasks.PRESET_STOCK_QUOTED), "Preset 7: StockQuoted");
        assertTrue(isValidTier3Bitmap(HookPermissionMasks.PRESET_DEEP_LIQUIDITY), "Preset 8: DeepLiquidity");
        assertTrue(isValidTier3Bitmap(HookPermissionMasks.PRESET_TRADER_FIRST), "Preset 9: TraderFirst");
        assertTrue(
            isValidTier3Bitmap(HookPermissionMasks.PRESET_STABLE_PAIR_PROJECT_FEE), "Preset 10: StablePairProjectFee"
        );
        assertTrue(isValidTier3Bitmap(HookPermissionMasks.PRESET_PRIVATE_POOL), "Preset 11: PrivatePool");
        assertTrue(isValidTier3Bitmap(HookPermissionMasks.PRESET_PRO_TRADING_POOL), "Preset 12: ProTradingPool");

        // 2. Verify contradictory combinations are rejected by `isValidTier3Bitmap`
        // Contradiction M1: Two Base Fees (`DynamicFee + ManagedFee`, `DynamicFee + MarketHoursFee`)
        assertFalse(isValidTier3Bitmap(HookPermissionMasks.BIT_DYNAMIC_FEE | HookPermissionMasks.BIT_MANAGED_FEE));
        assertFalse(isValidTier3Bitmap(HookPermissionMasks.BIT_DYNAMIC_FEE | HookPermissionMasks.BIT_MARKET_HOURS_FEE));
        // Contradiction M2: Duplicate LP Hold Cooldown (`MEVProtection + JITGuard`)
        assertFalse(isValidTier3Bitmap(HookPermissionMasks.BIT_MEV_PROTECTION | HookPermissionMasks.BIT_JIT_GUARD));
        // Contradiction M3: Conflicting Dislocation (`ArbRecapture + MEVProtection`, `ArbRecapture + CircuitBreaker`)
        assertFalse(isValidTier3Bitmap(HookPermissionMasks.BIT_ARB_RECAPTURE | HookPermissionMasks.BIT_MEV_PROTECTION));
        assertFalse(isValidTier3Bitmap(HookPermissionMasks.BIT_ARB_RECAPTURE | HookPermissionMasks.BIT_CIRCUIT_BREAKER));
        // Contradiction M4: Two Holder Caps (`WalletCap + VestingSellCap`)
        assertFalse(isValidTier3Bitmap(HookPermissionMasks.BIT_WALLET_CAP | HookPermissionMasks.BIT_VESTING_SELL_CAP));
        // Contradiction M5: Multiple Sinks (`AutoBurn + AutoBuyback`, `KingOfThePool + AutoBuyback`)
        assertFalse(
            isValidTier3Bitmap(
                HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_AUTO_BURN
                    | HookPermissionMasks.BIT_AUTO_BUYBACK
            )
        );
        assertFalse(
            isValidTier3Bitmap(
                HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_KING_OF_THE_POOL
                    | HookPermissionMasks.BIT_AUTO_BUYBACK
            )
        );
        // Contradiction M6: Double Buy-Tax (`KingOfThePool + BuySellTax`) or `SwapRewards + BuySellTax`
        assertFalse(
            isValidTier3Bitmap(
                HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_KING_OF_THE_POOL
                    | HookPermissionMasks.BIT_BUY_SELL_TAX
            )
        );
        assertFalse(
            isValidTier3Bitmap(
                HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_SWAP_REWARDS
                    | HookPermissionMasks.BIT_BUY_SELL_TAX
            )
        );
        // Contradiction M7: Archetype Mixing (`TWAMM + BuySellTax`, `AccessControl + LimitOrders`)
        assertFalse(isValidTier3Bitmap(HookPermissionMasks.BIT_TWAMM | HookPermissionMasks.BIT_BUY_SELL_TAX));
        assertFalse(isValidTier3Bitmap(HookPermissionMasks.BIT_ACCESS_CONTROL | HookPermissionMasks.BIT_LIMIT_ORDERS));

        // 3. Generate all 2,843 valid Tier 3 combinations and execute EVERY SINGLE ONE on PoolManager + HookRigOrchestrator!
        uint32[] memory allValid = _generateAll2843ValidBitmaps();
        assertEq(allValid.length, 2843);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(orchestrator))
        });

        ModifyLiquidityParams memory liqParams =
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 100_000 ether, salt: bytes32(0)});
        SwapParams memory buySwap =
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        uint256 baseSnapshot = vm.snapshotState();
        uint32 unionOfAllTestedBits = 0;

        vm.pauseGasMetering();
        for (uint256 i = 0; i < allValid.length; i++) {
            uint32 bm = allValid[i];
            assertTrue(isValidTier3Bitmap(bm), "Generated bitmap must satisfy Tier 3 predicate");
            unionOfAllTestedBits |= bm;

            IHookRigBlock.PoolStackConfig memory cfg = _buildDefaultConfigForBitmap(bm);

            vm.prank(admin);
            orchestrator.registerPoolStack(key, cfg);

            vm.prank(admin);
            poolManager.initialize(key, SQRT_PRICE_1_1);

            vm.prank(admin);
            router.modifyLiquidity(key, liqParams, "");

            vm.prank(trader1);
            router.swap(key, buySwap, "");

            bool reverted = vm.revertToState(baseSnapshot);
            assertTrue(reverted, "Snapshot revert failed");
        }
        vm.resumeGasMetering();

        // Prove that all 22 blocks (`0x3FFFFF`) were exercised across the 2,843 valid combinations
        assertEq(unionOfAllTestedBits, ALL_22_MASK, "All 22 blocks exercised across the 2,843 valid combinations");
    }

    /// @notice Verifies `SteppedTrancheLaunch` (with `KingOfThePool` Round #1 pot seeding) and `NativeTickLaunch`
    ///         (Block-0 concentrated bands) end-to-end on the Ethereum Hoodi fork.
    function test_HoodiFork_SteppedTrancheAndNativeTickLaunches() public {
        _deployProtocolOnHoodi();

        // 1. SteppedTrancheLaunch with KingOfThePool Round #1 quote-currency pot seeding
        uint32 trancheBitmap = HookPermissionMasks.PRESET_KING_OF_THE_POOL_LAUNCH;
        IHookRigBlock.PoolStackConfig memory trancheStack = _buildDefaultConfigForBitmap(trancheBitmap);

        ITokenLaunchpad.LaunchTokenMetadata memory trancheMeta = ITokenLaunchpad.LaunchTokenMetadata({
            name: "Hoodi Tranche Token",
            symbol: "HTRN",
            totalSupply: 1_000_000_000 ether,
            creator: admin,
            creatorVestingBps: 500,
            vestingDurationSeconds: 30 days
        });

        uint128 basePriceQ96 = uint128((uint256(1) << 96) / 10_000_000);
        uint128 stepIncrementQ96 = uint128((uint256(1) << 96) / 50_000_000);

        ITokenLaunchpad.SteppedTrancheConfig memory trancheCfg = ITokenLaunchpad.SteppedTrancheConfig({
            graduationQuoteTarget: 1 ether,
            curveTokenAllocation: 750_000_000 ether,
            lpTokenReserve: 200_000_000 ether,
            numTranches: 3,
            basePriceQ96: basePriceQ96,
            stepPriceIncrementQ96: stepIncrementQ96,
            maxWalletBps: 6000,
            antiSnipeSurchargeBps: 1000,
            antiSnipeBlocks: 10,
            surchargeToKingPotBps: 5000
        });

        vm.prank(admin);
        (, address trancheCurveAddr, PoolKey memory tranchePoolKey) = factory.launchSteppedTranche(
            trancheMeta,
            CurrencyLibrary.ADDRESS_ZERO,
            60,
            IHookRigOrchestrator(address(0)),
            trancheStack,
            trancheCfg,
            bytes32(uint256(77))
        );

        SteppedTrancheLaunch trancheCurve = SteppedTrancheLaunch(payable(trancheCurveAddr));
        vm.prank(trader1);
        trancheCurve.buy{value: 0.6 ether}(0.6 ether, 1, trader1);
        vm.roll(block.number + 1);
        vm.prank(trader2);
        trancheCurve.buy{value: 0.6 ether}(0.6 ether, 1, trader2);

        assertEq(uint8(trancheCurve.launchState()), uint8(ITokenLaunchpad.LaunchState.Graduated));
        (,, uint256 seededPot,) = orchestrator.getCurrentKing(tranchePoolKey.toId());
        assertGt(seededPot, 0, "Round 1 KingOfThePool pot seeded from SteppedTranche surcharge");

        // 2. NativeTickLaunch with tick-aligned Block-0 concentrated bands
        ITokenLaunchpad.LaunchTokenMetadata memory nativeMeta = ITokenLaunchpad.LaunchTokenMetadata({
            name: "Hoodi Native Tick Token",
            symbol: "HTCK",
            totalSupply: 1_000_000_000 ether,
            creator: admin,
            creatorVestingBps: 0,
            vestingDurationSeconds: 0
        });

        ITokenLaunchpad.NativeTickBand[] memory bands = new ITokenLaunchpad.NativeTickBand[](2);
        bands[0] = ITokenLaunchpad.NativeTickBand({tickLower: -1200, tickUpper: -600, tokenAmount: 500_000_000 ether});
        bands[1] = ITokenLaunchpad.NativeTickBand({tickLower: -600, tickUpper: 0, tokenAmount: 500_000_000 ether});

        ITokenLaunchpad.NativeTickConfig memory nativeCfg =
            ITokenLaunchpad.NativeTickConfig({initialSqrtPriceX96: SQRT_PRICE_1_1, tickSpacing: 60, bands: bands});

        IHookRigBlock.PoolStackConfig memory nativeStack =
            _buildDefaultConfigForBitmap(HookPermissionMasks.PRESET_TRADER_FIRST);

        vm.prank(admin);
        (address nativeTokenAddr,, PoolKey memory nativePoolKey) = factory.launchNativeTick(
            nativeMeta,
            CurrencyLibrary.ADDRESS_ZERO,
            IHookRigOrchestrator(address(0)),
            nativeStack,
            nativeCfg,
            bytes32(uint256(88))
        );

        vm.prank(trader1);
        router.swap{value: 0.1 ether}(
            nativePoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -0.1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        assertGt(IERC20(nativeTokenAddr).balanceOf(trader1), 0);
    }
}
