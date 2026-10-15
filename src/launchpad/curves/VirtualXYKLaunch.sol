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
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ITokenLaunchpad} from "../../interfaces/ITokenLaunchpad.sol";
import {IHookRigOrchestrator} from "../../interfaces/IHookRigOrchestrator.sol";

/// @title VirtualXYKLaunch
/// @notice Curve Model #1: Pump.fun-style virtual constant-product bonding curve `(X_0 + x_real) * Y_virtual = k`
///         that atomically graduates into a Uniswap v4 pool wired to a HookRig stack.
/// @dev Enforces directional Floor/Ceil rounding, cap-and-refund at graduation, spot-price continuity, and irreversible LP lock.
contract VirtualXYKLaunch is ITokenLaunchpad, IUnlockCallback, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;

    IPoolManager public immutable poolManager;
    IHookRigOrchestrator public immutable hookOrchestrator;
    address public immutable factory;

    PoolKey public poolKey;
    PoolId public poolId;
    address public projectToken;
    Currency public quoteCurrency;

    LaunchState public launchState;
    VirtualXYKConfig public curveConfig;

    uint256 public realQuoteRaised;
    uint256 public curveTokensSold;
    uint256 public virtualQuoteReserve;
    uint256 public virtualTokenReserve;
    uint256 public invariantK;

    error AlreadyInitialized();
    error CurveNotActive();
    error SlippageExceeded(uint256 actual, uint256 minimumRequired);
    error ZeroAmount();
    error WalletCapExceededOnCurve(address buyer, uint256 newBalance, uint256 maxAllowed);
    error OnlyPoolManagerUnlock();

    constructor(IPoolManager _poolManager, IHookRigOrchestrator _hookOrchestrator, address _factory) {
        poolManager = _poolManager;
        hookOrchestrator = _hookOrchestrator;
        factory = _factory;
    }

    receive() external payable {}

    function initializeCurve(PoolKey calldata _poolKey, address _projectToken, VirtualXYKConfig calldata _config)
        external
    {
        if (launchState != LaunchState.Uninitialized || msg.sender != factory) revert AlreadyInitialized();

        poolKey = _poolKey;
        poolId = _poolKey.toId();
        projectToken = _projectToken;
        quoteCurrency = _poolKey.currency0;
        curveConfig = _config;

        virtualQuoteReserve = _config.virtualQuoteReserve;
        virtualTokenReserve = _config.virtualTokenReserve;
        invariantK = uint256(_config.virtualQuoteReserve) * uint256(_config.virtualTokenReserve);
        launchState = LaunchState.ActiveBonding;
    }

    /// @notice Buys tokens along the virtual XYK curve; caps at graduation target, refunds excess quote, and auto-graduates.
    function buy(uint256 quoteAmountIn, uint256 minTokensOut, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut, uint256 quoteUsed)
    {
        if (launchState != LaunchState.ActiveBonding) revert CurveNotActive();
        if (quoteAmountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) recipient = msg.sender;

        uint256 remainingToTarget = curveConfig.graduationQuoteTarget - realQuoteRaised;
        quoteUsed = quoteAmountIn > remainingToTarget ? remainingToTarget : quoteAmountIn;

        // Virtual XYK math: newY = ceil(k / (X_virtual + quoteUsed)), tokensOut = floor(Y_virtual - newY)
        uint256 newVirtualQuote = virtualQuoteReserve + quoteUsed;
        uint256 newVirtualToken = Math.mulDiv(invariantK, 1, newVirtualQuote, Math.Rounding.Ceil);
        tokensOut = virtualTokenReserve > newVirtualToken ? virtualTokenReserve - newVirtualToken : 0;

        uint256 remainingCurveTokens = curveConfig.curveTokenAllocation - curveTokensSold;
        if (tokensOut > remainingCurveTokens) {
            tokensOut = remainingCurveTokens;
            newVirtualToken = virtualTokenReserve - tokensOut;
            newVirtualQuote = Math.mulDiv(invariantK, 1, newVirtualToken, Math.Rounding.Ceil);
            quoteUsed = newVirtualQuote > virtualQuoteReserve ? newVirtualQuote - virtualQuoteReserve : 0;
        }
        if (tokensOut < minTokensOut) {
            revert SlippageExceeded(tokensOut, minTokensOut);
        }

        // Collect exact quoteUsed from buyer
        if (quoteCurrency.isAddressZero()) {
            require(msg.value >= quoteUsed, "Insufficient ETH");
        } else {
            require(msg.value == 0, "Unexpected ETH");
            IERC20(Currency.unwrap(quoteCurrency)).safeTransferFrom(msg.sender, address(this), quoteUsed);
        }

        virtualQuoteReserve = newVirtualQuote;
        virtualTokenReserve -= tokensOut;
        realQuoteRaised += quoteUsed;
        curveTokensSold += tokensOut;

        // Enforce optional per-wallet cap during the bonding phase
        if (curveConfig.maxWalletBpsDuringCurve > 0) {
            uint256 supply = IERC20(projectToken).totalSupply();
            uint256 maxWallet = Math.mulDiv(supply, curveConfig.maxWalletBpsDuringCurve, 10_000, Math.Rounding.Floor);
            uint256 postBal = IERC20(projectToken).balanceOf(recipient) + tokensOut;
            if (postBal > maxWallet) {
                revert WalletCapExceededOnCurve(recipient, postBal, maxWallet);
            }
        }

        IERC20(projectToken).safeTransfer(recipient, tokensOut);

        // Refund any excess ETH above quoteUsed
        if (quoteCurrency.isAddressZero() && msg.value > quoteUsed) {
            quoteCurrency.transfer(msg.sender, msg.value - quoteUsed);
        }

        emit CurveBuy(recipient, quoteUsed, tokensOut, 0, realQuoteRaised);

        // Atomic graduation when target is reached
        if (realQuoteRaised >= curveConfig.graduationQuoteTarget || curveTokensSold >= curveConfig.curveTokenAllocation)
        {
            _graduateToV4();
        }
    }

    /// @notice Sells tokens back into the virtual XYK curve prior to graduation.
    function sell(uint256 tokenAmountIn, uint256 minQuoteOut, address recipient)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        if (launchState != LaunchState.ActiveBonding) revert CurveNotActive();
        if (tokenAmountIn == 0 || tokenAmountIn > curveTokensSold) revert ZeroAmount();
        if (recipient == address(0)) recipient = msg.sender;

        IERC20(projectToken).safeTransferFrom(msg.sender, address(this), tokenAmountIn);

        uint256 newVirtualToken = virtualTokenReserve + tokenAmountIn;
        uint256 newVirtualQuote = Math.mulDiv(invariantK, 1, newVirtualToken, Math.Rounding.Ceil);
        quoteOut = virtualQuoteReserve > newVirtualQuote ? virtualQuoteReserve - newVirtualQuote : 0;
        bool clamped = false;
        if (quoteOut > realQuoteRaised) {
            quoteOut = realQuoteRaised;
            clamped = true;
        }
        if (quoteOut < minQuoteOut) {
            revert SlippageExceeded(quoteOut, minQuoteOut);
        }

        virtualTokenReserve = newVirtualToken;
        virtualQuoteReserve -= quoteOut;
        realQuoteRaised -= quoteOut;
        curveTokensSold -= tokenAmountIn;
        if (clamped) {
            invariantK = virtualQuoteReserve * virtualTokenReserve;
        }

        quoteCurrency.transfer(recipient, quoteOut);

        emit CurveSell(msg.sender, tokenAmountIn, quoteOut, realQuoteRaised);
    }

    function _graduateToV4() internal {
        launchState = LaunchState.Graduated;

        uint256 quoteToSeed = realQuoteRaised;
        uint256 continuousLpTokens =
            Math.mulDiv(virtualTokenReserve, quoteToSeed, virtualQuoteReserve, Math.Rounding.Floor);
        uint256 availableTokens = IERC20(projectToken).balanceOf(address(this));
        if (continuousLpTokens > availableTokens) {
            continuousLpTokens = availableTokens;
        }
        if (continuousLpTokens == 0) {
            continuousLpTokens = curveConfig.lpTokenReserve;
        }
        curveConfig.lpTokenReserve = uint128(continuousLpTokens);
        uint256 tokensToSeed = continuousLpTokens;

        // Spot-price continuous sqrtPriceX96 = sqrt(tokensToSeed / quoteToSeed) * 2^96
        uint160 graduationSqrtPriceX96;
        if (tokensToSeed <= type(uint64).max) {
            uint256 ratioX192 = Math.mulDiv(tokensToSeed, uint256(1) << 192, quoteToSeed, Math.Rounding.Floor);
            graduationSqrtPriceX96 = uint160(Math.sqrt(ratioX192));
        } else if (tokensToSeed <= type(uint96).max) {
            uint256 ratioX160 = Math.mulDiv(tokensToSeed, uint256(1) << 160, quoteToSeed, Math.Rounding.Floor);
            graduationSqrtPriceX96 = uint160(Math.sqrt(ratioX160) << 16);
        } else {
            uint256 ratioX128 = Math.mulDiv(tokensToSeed, uint256(1) << 128, quoteToSeed, Math.Rounding.Floor);
            graduationSqrtPriceX96 = uint160(Math.sqrt(ratioX128) << 32);
        }
        if (graduationSqrtPriceX96 <= TickMath.MIN_SQRT_PRICE) {
            graduationSqrtPriceX96 = TickMath.MIN_SQRT_PRICE + 1;
        }
        if (graduationSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            graduationSqrtPriceX96 = TickMath.MAX_SQRT_PRICE - 1;
        }

        // Initialize the canonical Uniswap v4 pool and reset the Anti-Snipe graduation clock
        poolManager.initialize(poolKey, graduationSqrtPriceX96);
        IHookRigOrchestrator(address(poolKey.hooks)).notifyPoolGraduated(poolId);

        // Seed permanent full-range liquidity inside PoolManager.unlock
        poolManager.unlock(abi.encode(quoteToSeed, tokensToSeed));

        emit CurveGraduated(poolId, projectToken, quoteToSeed, tokensToSeed, graduationSqrtPriceX96);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManagerUnlock();
        (uint256 quoteToSeed, uint256 tokensToSeed) = abi.decode(data, (uint256, uint256));

        int24 spacing = poolKey.tickSpacing;
        int24 tickLower = (TickMath.MIN_TICK / spacing) * spacing;
        int24 tickUpper = (TickMath.MAX_TICK / spacing) * spacing;

        uint256 liquidityEstimate = (Math.sqrt(quoteToSeed * tokensToSeed) * 9999) / 10_000;
        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(liquidityEstimate), salt: bytes32(0)
            }),
            ""
        );

        if (callerDelta.amount0() < 0) {
            poolKey.currency0.settle(poolManager, address(this), uint256(uint128(-callerDelta.amount0())), false);
        }
        if (callerDelta.amount1() < 0) {
            poolKey.currency1.settle(poolManager, address(this), uint256(uint128(-callerDelta.amount1())), false);
        }

        uint256 remQuote = poolKey.currency0.isAddressZero()
            ? address(this).balance
            : IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(this));
        uint256 remToken = IERC20(projectToken).balanceOf(address(this));
        if (remQuote > 0 || remToken > 0) {
            BalanceDelta donateDelta = poolManager.donate(poolKey, remQuote, remToken, "");
            if (donateDelta.amount0() < 0) {
                poolKey.currency0.settle(poolManager, address(this), uint256(uint128(-donateDelta.amount0())), false);
            }
            if (donateDelta.amount1() < 0) {
                poolKey.currency1.settle(poolManager, address(this), uint256(uint128(-donateDelta.amount1())), false);
            }
        }

        return "";
    }
}
