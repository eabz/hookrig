// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

import {ITokenLaunchpad} from "../interfaces/ITokenLaunchpad.sol";
import {IHookRigOrchestrator} from "../interfaces/IHookRigOrchestrator.sol";
import {HookPermissionMasks} from "../libraries/HookPermissionMasks.sol";
import {HookRigToken} from "./HookRigToken.sol";
import {VirtualXYKLaunch} from "./curves/VirtualXYKLaunch.sol";
import {SteppedTrancheLaunch} from "./curves/SteppedTrancheLaunch.sol";
import {NativeTickLaunch} from "./curves/NativeTickLaunch.sol";

interface ILaunchCurveState {
    function launchState() external view returns (ITokenLaunchpad.LaunchState);
}

/// @notice Creator vesting wallet that prevents releasing tokens while the launchpad bonding curve is still active.
contract LaunchpadVestingWallet is VestingWallet {
    address public immutable curve;

    error CurveNotGraduatedYet();

    constructor(address beneficiary, uint64 startTimestamp, uint64 durationSeconds, address _curve)
        VestingWallet(beneficiary, startTimestamp, durationSeconds)
    {
        curve = _curve;
    }

    function vestedAmount(address token, uint64 timestamp) public view override returns (uint256) {
        if (curve != address(0) && ILaunchCurveState(curve).launchState() != ITokenLaunchpad.LaunchState.Graduated) {
            return 0;
        }
        return super.vestedAmount(token, timestamp);
    }

    function release(address token) public override {
        if (curve != address(0) && ILaunchCurveState(curve).launchState() != ITokenLaunchpad.LaunchState.Graduated) {
            revert CurveNotGraduatedYet();
        }
        super.release(token);
    }
}

/// @title LaunchpadFactory
/// @notice Unified Token Launchpad Factory for HookRig using EIP-1167 Minimal Proxies (`Clones`):
///         - Deploys `HookRigToken` via CREATE2 with deterministic address sorting (`tokenAddress > quoteAddress`)
///           so the launched project token is always `currency1` (`zeroForOne == true` is always a Buy).
///         - Clones audited implementation contracts for `VirtualXYKLaunch`, `SteppedTrancheLaunch`, and `NativeTickLaunch`.
contract LaunchpadFactory is ITokenLaunchpad {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using Clones for address;

    uint16 public constant MAX_CREATOR_VESTING_BPS = 1000; // 10.00%

    IPoolManager public immutable poolManager;
    IHookRigOrchestrator public immutable defaultOrchestrator;
    address public immutable virtualXYKImplementation;
    address public immutable steppedTrancheImplementation;
    address public immutable nativeTickImplementation;

    uint256 public totalLaunches;
    mapping(address token => address curve) public tokenToCurve;
    mapping(address token => address vestingWallet) public tokenToCreatorVesting;

    error CreatorVestingExceedsCap(uint16 requestedBps);
    error SaltDoesNotSortTokenAsCurrency1(address predictedToken, address quoteAsset);
    error PostGraduationWalletCapBelowCurveCap(uint16 poolWalletCapBps, uint16 curveWalletCapBps);
    error InsufficientCurveTokenSupply(uint256 requiredSupply, uint256 availableSupply);
    error InvalidCurveConfiguration();
    error UnsupportedHookContract(address hookContract);
    error UnsafeLaunchStack(uint32 bitmap);

    /// @notice Highest AntiSnipe launch fee a launchpad pool may use (25%, the aggregate cut budget). The fee
    ///         restarts at graduation and sits outside that budget, so a higher fee would trap curve holders.
    uint24 public constant MAX_LAUNCH_ANTI_SNIPE_FEE = 250_000;

    constructor(
        IPoolManager _poolManager,
        IHookRigOrchestrator _defaultOrchestrator,
        address _virtualXYKImpl,
        address _steppedTrancheImpl,
        address _nativeTickImpl
    ) {
        poolManager = _poolManager;
        defaultOrchestrator = _defaultOrchestrator;
        virtualXYKImplementation = _virtualXYKImpl;
        steppedTrancheImplementation = _steppedTrancheImpl;
        nativeTickImplementation = _nativeTickImpl;
    }

    /// @notice Launches a token on Curve Model #1 (`VirtualXYKLaunch` — Pump.fun-style bonding curve).
    function launchVirtualXYK(
        LaunchTokenMetadata calldata meta,
        Currency quoteCurrency,
        int24 tickSpacing,
        IHookRigOrchestrator hookContract,
        IHookRigOrchestrator.PoolStackConfig memory stackConfig,
        VirtualXYKConfig calldata curveConfig,
        bytes32 salt
    ) external returns (address token, address curve, PoolKey memory key) {
        hookContract = _resolveHook(hookContract);

        _validateWalletCapAlignment(stackConfig, curveConfig.maxWalletBpsDuringCurve);
        if (
            curveConfig.virtualQuoteReserve == 0 || curveConfig.virtualTokenReserve < curveConfig.curveTokenAllocation
                || curveConfig.graduationQuoteTarget == 0 || curveConfig.curveTokenAllocation == 0
                || curveConfig.lpTokenReserve == 0
        ) {
            revert InvalidCurveConfiguration();
        }
        uint256 availableSupply = _computeAvailableCurveSupply(meta);
        uint256 requiredSupply = uint256(curveConfig.curveTokenAllocation) + uint256(curveConfig.lpTokenReserve);
        if (requiredSupply > availableSupply) {
            revert InsufficientCurveTokenSupply(requiredSupply, availableSupply);
        }

        curve = virtualXYKImplementation.clone();
        (token, key) = _deploySortedTokenAndRegisterPool(
            meta, quoteCurrency, tickSpacing, hookContract, stackConfig, curve, salt, LaunchCurveType.VirtualXYK
        );
        VirtualXYKLaunch(payable(curve)).initializeCurve(key, token, curveConfig);
    }

    /// @notice Launches a token on Curve Model #2 (`SteppedTrancheLaunch` — Anti-bundle fair accumulation curve).
    function launchSteppedTranche(
        LaunchTokenMetadata calldata meta,
        Currency quoteCurrency,
        int24 tickSpacing,
        IHookRigOrchestrator hookContract,
        IHookRigOrchestrator.PoolStackConfig memory stackConfig,
        SteppedTrancheConfig calldata trancheConfig,
        bytes32 salt
    ) external returns (address token, address curve, PoolKey memory key) {
        hookContract = _resolveHook(hookContract);

        _validateWalletCapAlignment(stackConfig, trancheConfig.maxWalletBps);
        if (
            trancheConfig.numTranches == 0 || trancheConfig.basePriceQ96 == 0
                || trancheConfig.graduationQuoteTarget == 0 || trancheConfig.curveTokenAllocation == 0
                || trancheConfig.lpTokenReserve == 0 || trancheConfig.antiSnipeSurchargeBps >= 10_000
                || trancheConfig.surchargeToKingPotBps > 10_000 || trancheConfig.antiSnipeBlocks > 50_400
        ) {
            revert InvalidCurveConfiguration();
        }
        uint256 availableSupply = _computeAvailableCurveSupply(meta);
        uint256 requiredSupply = uint256(trancheConfig.curveTokenAllocation) + uint256(trancheConfig.lpTokenReserve);
        if (requiredSupply > availableSupply) {
            revert InsufficientCurveTokenSupply(requiredSupply, availableSupply);
        }
        uint256 trancheTokens = uint256(trancheConfig.curveTokenAllocation) / uint256(trancheConfig.numTranches);
        uint256 maxTargetForTranche =
            Math.mulDiv(trancheTokens, uint256(trancheConfig.basePriceQ96) + 1, uint256(1) << 96, Math.Rounding.Ceil);
        uint256 maxTargetForSupply = Math.mulDiv(
            availableSupply / 3, uint256(trancheConfig.basePriceQ96) + 1, uint256(1) << 96, Math.Rounding.Ceil
        );
        if (
            trancheConfig.graduationQuoteTarget > maxTargetForTranche
                || trancheConfig.graduationQuoteTarget > maxTargetForSupply
        ) {
            revert InvalidCurveConfiguration();
        }

        curve = steppedTrancheImplementation.clone();
        (token, key) = _deploySortedTokenAndRegisterPool(
            meta, quoteCurrency, tickSpacing, hookContract, stackConfig, curve, salt, LaunchCurveType.SteppedTranche
        );
        SteppedTrancheLaunch(payable(curve)).initializeCurve(key, token, trancheConfig);
    }

    /// @notice Launches a token on Curve Model #3 (`NativeTickLaunch` — Direct Block-0 single-sided v4 tick curve).
    function launchNativeTick(
        LaunchTokenMetadata calldata meta,
        Currency quoteCurrency,
        IHookRigOrchestrator hookContract,
        IHookRigOrchestrator.PoolStackConfig memory stackConfig,
        NativeTickConfig calldata nativeConfig,
        bytes32 salt
    ) external returns (address token, address curve, PoolKey memory key) {
        hookContract = _resolveHook(hookContract);
        _validateWalletCapAlignment(stackConfig, 0);
        if (
            nativeConfig.bands.length == 0 || nativeConfig.initialSqrtPriceX96 < TickMath.MIN_SQRT_PRICE
                || nativeConfig.initialSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE
        ) {
            revert InvalidCurveConfiguration();
        }

        int24 spacing = nativeConfig.tickSpacing > 0 ? nativeConfig.tickSpacing : int24(60);
        if (spacing > TickMath.MAX_TICK_SPACING) {
            revert InvalidCurveConfiguration();
        }
        int24 startingTick = TickMath.getTickAtSqrtPrice(nativeConfig.initialSqrtPriceX96);

        uint256 availableSupply = _computeAvailableCurveSupply(meta);
        uint256 totalBandTokens = 0;
        for (uint256 i = 0; i < nativeConfig.bands.length; i++) {
            NativeTickBand calldata band = nativeConfig.bands[i];
            if (band.tokenAmount == 0) continue;
            if (
                band.tickLower >= band.tickUpper || band.tickLower < TickMath.MIN_TICK
                    || band.tickUpper > TickMath.MAX_TICK || band.tickLower % spacing != 0
                    || band.tickUpper % spacing != 0 || band.tickUpper > startingTick
            ) {
                revert InvalidCurveConfiguration();
            }
            uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(band.tickLower);
            uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(band.tickUpper);
            uint128 liq =
                LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLowerX96, sqrtPriceUpperX96, band.tokenAmount);
            if (liq == 0) {
                revert InvalidCurveConfiguration();
            }
            totalBandTokens += band.tokenAmount;
        }
        if (totalBandTokens == 0) {
            revert InvalidCurveConfiguration();
        }
        if (totalBandTokens > availableSupply) {
            revert InsufficientCurveTokenSupply(totalBandTokens, availableSupply);
        }

        curve = nativeTickImplementation.clone();
        (token, key) = _deploySortedTokenAndRegisterPool(
            meta,
            quoteCurrency,
            nativeConfig.tickSpacing,
            hookContract,
            stackConfig,
            curve,
            salt,
            LaunchCurveType.NativeTick
        );
        NativeTickLaunch(curve).initializeAndSeedNativeTicks(key, token, nativeConfig);
    }

    /// @dev Curves graduate into the hook they are given, so only the audited default orchestrator is accepted:
    ///      a creator-written hook could block buyer sells after graduation.
    function _resolveHook(IHookRigOrchestrator hookContract) internal view returns (IHookRigOrchestrator) {
        if (address(hookContract) == address(0)) return defaultOrchestrator;
        if (hookContract != defaultOrchestrator) revert UnsupportedHookContract(address(hookContract));
        return hookContract;
    }

    /// @dev Resolves a zero `creator` to `msg.sender` so `poolAdmin` is never stranded on the stateless factory.
    function _resolveCreator(address creator) internal view returns (address) {
        return creator != address(0) ? creator : msg.sender;
    }

    /// @dev Rejects launch stacks that let a creator trap curve buyers after graduation: AccessControl (only
    ///      allowlisted traders could sell) and an AntiSnipe launch fee above the aggregate cut budget.
    function _validateLaunchStack(IHookRigOrchestrator.PoolStackConfig memory stackConfig) internal pure {
        uint32 resolvedBitmap =
            HookPermissionMasks.getPresetBitmap(stackConfig.presetId) | stackConfig.enabledBlocksBitmap;
        if (
            (resolvedBitmap & HookPermissionMasks.BIT_ACCESS_CONTROL) != 0
                || ((resolvedBitmap & HookPermissionMasks.BIT_ANTI_SNIPE) != 0
                    && stackConfig.antiSnipe.launchFee > MAX_LAUNCH_ANTI_SNIPE_FEE)
        ) {
            revert UnsafeLaunchStack(resolvedBitmap);
        }
    }

    function _validateWalletCapAlignment(
        IHookRigOrchestrator.PoolStackConfig memory stackConfig,
        uint16 curveWalletCapBps
    ) internal pure {
        uint32 resolvedBitmap = HookPermissionMasks.getPresetBitmap(stackConfig.presetId)
        | stackConfig.enabledBlocksBitmap;
        if ((resolvedBitmap & HookPermissionMasks.BIT_WALLET_CAP) != 0) {
            if (stackConfig.walletCap.maxWalletBps == 0) {
                stackConfig.walletCap.maxWalletBps = curveWalletCapBps > 0 ? curveWalletCapBps : 200;
            } else if (curveWalletCapBps > stackConfig.walletCap.maxWalletBps) {
                revert PostGraduationWalletCapBelowCurveCap(stackConfig.walletCap.maxWalletBps, curveWalletCapBps);
            }
        }
    }

    function _computeAvailableCurveSupply(LaunchTokenMetadata calldata meta) internal view returns (uint256) {
        if (meta.creatorVestingBps > MAX_CREATOR_VESTING_BPS) {
            revert CreatorVestingExceedsCap(meta.creatorVestingBps);
        }
        address creator = _resolveCreator(meta.creator);
        uint256 vestingAmount = (meta.creatorVestingBps > 0 && creator != address(0))
            ? Math.mulDiv(meta.totalSupply, meta.creatorVestingBps, 10_000, Math.Rounding.Floor)
            : 0;
        return meta.totalSupply - vestingAmount;
    }

    /// @notice Helper to mine a CREATE2 salt off-chain or on-chain so `deployedToken > Currency.unwrap(quoteCurrency)`.
    ///         The prediction is for a launch sent by the caller (`msg.sender`).
    function predictTokenAddress(LaunchTokenMetadata calldata meta, bytes32 salt)
        public
        view
        returns (address predicted)
    {
        return predictTokenAddressFor(meta, salt, msg.sender);
    }

    /// @notice Predicts the token address of a launch that `deployer` sends with `salt`.
    function predictTokenAddressFor(LaunchTokenMetadata calldata meta, bytes32 salt, address deployer)
        public
        view
        returns (address predicted)
    {
        bytes memory bytecode = abi.encodePacked(
            type(HookRigToken).creationCode,
            abi.encode(meta.name, meta.symbol, meta.totalSupply, address(this), meta.creator)
        );
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), _deployerSalt(deployer, salt), keccak256(bytecode))
        );
        predicted = address(uint160(uint256(hash)));
    }

    /// @dev Binds the CREATE2 salt to the launch sender, so a copied pending launch cannot take the address.
    function _deployerSalt(address deployer, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(deployer, salt));
    }

    function _deploySortedTokenAndRegisterPool(
        LaunchTokenMetadata calldata meta,
        Currency quoteCurrency,
        int24 tickSpacing,
        IHookRigOrchestrator hookContract,
        IHookRigOrchestrator.PoolStackConfig memory stackConfig,
        address curve,
        bytes32 salt,
        LaunchCurveType curveType
    ) internal returns (address token, PoolKey memory key) {
        if (tickSpacing > TickMath.MAX_TICK_SPACING) revert InvalidCurveConfiguration();
        _validateLaunchStack(stackConfig);
        token = _deployTokenAndVest(meta, Currency.unwrap(quoteCurrency), curve, salt);
        address creator = _resolveCreator(meta.creator);

        // Because `token > quoteAddr`, `currency0` is always `quoteCurrency` and `currency1` is always `token`
        stackConfig.isToken0ProjectToken = false;
        stackConfig.authorizedCurve = curve;
        if (stackConfig.poolAdmin == address(0)) {
            stackConfig.poolAdmin = creator;
        }

        key = PoolKey({
            currency0: quoteCurrency,
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing > 0 ? tickSpacing : int24(60),
            hooks: IHooks(address(hookContract))
        });

        hookContract.registerPoolStack(key, stackConfig);

        tokenToCurve[token] = curve;
        totalLaunches++;

        emit TokenLaunched(token, curve, curveType, key.toId(), stackConfig.presetId, creator);
    }

    function _deployTokenAndVest(LaunchTokenMetadata calldata meta, address quoteAddr, address curve, bytes32 salt)
        internal
        returns (address token)
    {
        HookRigToken deployed = new HookRigToken{salt: _deployerSalt(msg.sender, salt)}(
            meta.name, meta.symbol, meta.totalSupply, address(this), meta.creator
        );
        token = address(deployed);

        if (uint160(token) <= uint160(quoteAddr)) {
            revert SaltDoesNotSortTokenAsCurrency1(token, quoteAddr);
        }

        // Handle optional creator vesting slice via LaunchpadVestingWallet (min 30 days — SA-18)
        address creator = _resolveCreator(meta.creator);
        uint256 vestingAmount = 0;
        if (meta.creatorVestingBps > 0 && creator != address(0)) {
            vestingAmount = Math.mulDiv(meta.totalSupply, meta.creatorVestingBps, 10_000, Math.Rounding.Floor);
            uint64 duration = meta.vestingDurationSeconds >= 30 days ? meta.vestingDurationSeconds : 180 days;
            LaunchpadVestingWallet vest =
                new LaunchpadVestingWallet(creator, uint64(block.timestamp + 1 hours), duration, curve);
            tokenToCreatorVesting[token] = address(vest);
            IERC20(token).safeTransfer(address(vest), vestingAmount);
        }

        // Transfer remaining supply to the LaunchCurve contract
        uint256 curveAndLpSupply = meta.totalSupply - vestingAmount;
        IERC20(token).safeTransfer(curve, curveAndLpSupply);
    }
}
