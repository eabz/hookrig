// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {ITokenLaunchpad} from "../../interfaces/ITokenLaunchpad.sol";
import {IHookRigOrchestrator} from "../../interfaces/IHookRigOrchestrator.sol";

/// @title NativeTickLaunch
/// @notice Curve Model #3: Zero-migration direct Uniswap v4 launch.
///         Initializes the Uniswap v4 pool at Block 0 and seeds single-sided concentrated tick ranges (`Band 1..K`)
///         with the chosen HookRig preset/stack active from the very first trade.
contract NativeTickLaunch is ITokenLaunchpad, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;

    IPoolManager public immutable poolManager;
    IHookRigOrchestrator public immutable hookOrchestrator;
    address public immutable factory;

    PoolKey public poolKey;
    PoolId public poolId;
    address public projectToken;
    LaunchState public launchState;

    error AlreadyLaunched();
    error OnlyPoolManagerUnlock();

    constructor(IPoolManager _poolManager, IHookRigOrchestrator _hookOrchestrator, address _factory) {
        poolManager = _poolManager;
        hookOrchestrator = _hookOrchestrator;
        factory = _factory;
    }

    function initializeAndSeedNativeTicks(
        PoolKey calldata _poolKey,
        address _projectToken,
        NativeTickConfig calldata _config
    ) external {
        if (launchState != LaunchState.Uninitialized || msg.sender != factory) {
            revert AlreadyLaunched();
        }

        poolKey = _poolKey;
        poolId = _poolKey.toId();
        projectToken = _projectToken;
        launchState = LaunchState.Graduated;

        poolManager.initialize(_poolKey, _config.initialSqrtPriceX96);
        IHookRigOrchestrator(address(_poolKey.hooks)).notifyPoolGraduated(poolId);

        if (_config.bands.length > 0) {
            poolManager.unlock(abi.encode(_config.bands));
        }

        emit CurveGraduated(poolId, _projectToken, 0, 0, _config.initialSqrtPriceX96);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManagerUnlock();
        NativeTickBand[] memory bands = abi.decode(data, (NativeTickBand[]));

        for (uint256 i = 0; i < bands.length; i++) {
            if (bands[i].tokenAmount == 0) continue;
            uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(bands[i].tickLower);
            uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(bands[i].tickUpper);
            uint128 liq =
                LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLowerX96, sqrtPriceUpperX96, bands[i].tokenAmount);
            if (liq == 0) continue;
            (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
                poolKey,
                ModifyLiquidityParams({
                    tickLower: bands[i].tickLower,
                    tickUpper: bands[i].tickUpper,
                    liquidityDelta: int256(uint256(liq)),
                    salt: bytes32(i)
                }),
                ""
            );

            if (callerDelta.amount0() < 0) {
                poolKey.currency0.settle(poolManager, address(this), uint256(uint128(-callerDelta.amount0())), false);
            }
            if (callerDelta.amount1() < 0) {
                poolKey.currency1.settle(poolManager, address(this), uint256(uint128(-callerDelta.amount1())), false);
            }
        }

        return "";
    }
}
