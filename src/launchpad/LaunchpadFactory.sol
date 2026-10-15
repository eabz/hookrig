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

        // Because `token > quoteAddr`, `currency0` is always `quoteCurrency` and `currency1` is always `token`
        stackConfig.isToken0ProjectToken = false;
        stackConfig.authorizedCurve = curve;
        if (stackConfig.poolAdmin == address(0)) {
            stackConfig.poolAdmin = meta.creator;
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

        emit TokenLaunched(token, curve, curveType, key.toId(), stackConfig.presetId, meta.creator);
    }

    function _deployTokenAndVest(LaunchTokenMetadata calldata meta, address quoteAddr, address curve, bytes32 salt)
        internal
        returns (address token)
    {
        if (meta.creatorVestingBps > MAX_CREATOR_VESTING_BPS) {
            revert CreatorVestingExceedsCap(meta.creatorVestingBps);
        }

        HookRigToken deployed =
            new HookRigToken{salt: salt}(meta.name, meta.symbol, meta.totalSupply, address(this), meta.creator);
        token = address(deployed);

        if (uint160(token) <= uint160(quoteAddr)) {
            revert SaltDoesNotSortTokenAsCurrency1(token, quoteAddr);
        }

        // Handle optional creator vesting slice via OpenZeppelin VestingWallet
        uint256 vestingAmount = 0;
        if (meta.creatorVestingBps > 0 && meta.creator != address(0)) {
            vestingAmount = Math.mulDiv(meta.totalSupply, meta.creatorVestingBps, 10_000, Math.Rounding.Floor);
            VestingWallet vest = new VestingWallet(
                meta.creator,
                uint64(block.timestamp),
                meta.vestingDurationSeconds > 0 ? meta.vestingDurationSeconds : 180 days
            );
            tokenToCreatorVesting[token] = address(vest);
            IERC20(token).safeTransfer(address(vest), vestingAmount);
        }

        // Transfer remaining supply to the LaunchCurve contract
        uint256 curveAndLpSupply = meta.totalSupply - vestingAmount;
        IERC20(token).safeTransfer(curve, curveAndLpSupply);
    }
}
