// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
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
        if (address(hookContract) == address(0)) hookContract = defaultOrchestrator;

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
        if (address(hookContract) == address(0)) hookContract = defaultOrchestrator;

        _validateWalletCapAlignment(stackConfig, trancheConfig.maxWalletBps);
        if (
            trancheConfig.numTranches == 0 || trancheConfig.basePriceQ96 == 0
                || trancheConfig.graduationQuoteTarget == 0 || trancheConfig.curveTokenAllocation == 0
                || trancheConfig.lpTokenReserve == 0 || trancheConfig.antiSnipeSurchargeBps >= 10_000
                || trancheConfig.surchargeToKingPotBps > 10_000
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
        if (address(hookContract) == address(0)) hookContract = defaultOrchestrator;
        if (nativeConfig.bands.length == 0) {
            revert InvalidCurveConfiguration();
        }

        uint256 availableSupply = _computeAvailableCurveSupply(meta);
        uint256 totalBandTokens = 0;
        for (uint256 i = 0; i < nativeConfig.bands.length; i++) {
            totalBandTokens += nativeConfig.bands[i].tokenAmount;
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

    function _validateWalletCapAlignment(
        IHookRigOrchestrator.PoolStackConfig memory stackConfig,
        uint16 curveWalletCapBps
    ) internal pure {
        uint32 resolvedBitmap = HookPermissionMasks.getPresetBitmap(stackConfig.presetId)
        | stackConfig.enabledBlocksBitmap;
        if ((resolvedBitmap & HookPermissionMasks.BIT_WALLET_CAP) != 0) {
            uint16 effectivePoolCapBps =
                stackConfig.walletCap.maxWalletBps > 0 ? stackConfig.walletCap.maxWalletBps : 200;
            if (curveWalletCapBps > 0 && effectivePoolCapBps < curveWalletCapBps) {
                revert PostGraduationWalletCapBelowCurveCap(stackConfig.walletCap.maxWalletBps, curveWalletCapBps);
            }
            if (stackConfig.walletCap.maxWalletBps == 0) {
                stackConfig.walletCap.maxWalletBps = 200;
            }
        }
    }

    function _computeAvailableCurveSupply(LaunchTokenMetadata calldata meta) internal pure returns (uint256) {
        if (meta.creatorVestingBps > MAX_CREATOR_VESTING_BPS) {
            revert CreatorVestingExceedsCap(meta.creatorVestingBps);
        }
        uint256 vestingAmount = (meta.creatorVestingBps > 0 && meta.creator != address(0))
            ? Math.mulDiv(meta.totalSupply, meta.creatorVestingBps, 10_000, Math.Rounding.Floor)
            : 0;
        return meta.totalSupply - vestingAmount;
    }

    /// @notice Helper to mine a CREATE2 salt off-chain or on-chain so `deployedToken > Currency.unwrap(quoteCurrency)`.
    function predictTokenAddress(LaunchTokenMetadata calldata meta, bytes32 salt)
        public
        view
        returns (address predicted)
    {
        bytes memory bytecode = abi.encodePacked(
            type(HookRigToken).creationCode,
            abi.encode(meta.name, meta.symbol, meta.totalSupply, address(this), meta.creator)
        );
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));
        predicted = address(uint160(uint256(hash)));
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
        token = _deployTokenAndVest(meta, Currency.unwrap(quoteCurrency), curve, salt);
        address creator = meta.creator;

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
        HookRigToken deployed =
            new HookRigToken{salt: salt}(meta.name, meta.symbol, meta.totalSupply, address(this), meta.creator);
        token = address(deployed);

        if (uint160(token) <= uint160(quoteAddr)) {
            revert SaltDoesNotSortTokenAsCurrency1(token, quoteAddr);
        }

        // Handle optional creator vesting slice via OpenZeppelin VestingWallet (min 30 days — SA-18)
        uint256 vestingAmount = 0;
        if (meta.creatorVestingBps > 0 && meta.creator != address(0)) {
            vestingAmount = Math.mulDiv(meta.totalSupply, meta.creatorVestingBps, 10_000, Math.Rounding.Floor);
            uint64 duration = meta.vestingDurationSeconds >= 30 days ? meta.vestingDurationSeconds : 180 days;
            VestingWallet vest = new VestingWallet(meta.creator, uint64(block.timestamp + 1 hours), duration);
            tokenToCreatorVesting[token] = address(vest);
            IERC20(token).safeTransfer(address(vest), vestingAmount);
        }

        // Transfer remaining supply to the LaunchCurve contract
        uint256 curveAndLpSupply = meta.totalSupply - vestingAmount;
        IERC20(token).safeTransfer(curve, curveAndLpSupply);
    }
}
