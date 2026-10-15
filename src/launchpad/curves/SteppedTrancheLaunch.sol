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

/// @title SteppedTrancheLaunch
/// @notice Curve Model #2: Anti-bundle stepped tranche curve with active `WalletCap` and `AntiSnipe` surcharges
///         during bonding. Surcharges seed extra graduation LP depth and Round #1 `KingOfThePool` jackpot.
contract SteppedTrancheLaunch is ITokenLaunchpad, IUnlockCallback, ReentrancyGuardTransient {
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
    SteppedTrancheConfig public trancheConfig;
    uint32 public launchCreationBlock;

    uint256 public realQuoteRaised;
    uint256 public curveTokensSold;
    uint256 public totalSurchargeCollected;

    error AlreadyInitialized();
    error CurveNotActive();
    error SlippageExceeded(uint256 actual, uint256 minimumRequired);
    error WalletCapExceededOnTranche(address buyer, uint256 newBalance, uint256 maxAllowed);
    error OnlyPoolManagerUnlock();

    constructor(IPoolManager _poolManager, IHookRigOrchestrator _hookOrchestrator, address _factory) {
        poolManager = _poolManager;
        hookOrchestrator = _hookOrchestrator;
        factory = _factory;
    }

    receive() external payable {}

    function initializeCurve(PoolKey calldata _poolKey, address _projectToken, SteppedTrancheConfig calldata _config)
        external
    {
        if (launchState != LaunchState.Uninitialized || msg.sender != factory) revert AlreadyInitialized();

        poolKey = _poolKey;
        poolId = _poolKey.toId();
        projectToken = _projectToken;
        quoteCurrency = _poolKey.currency0;
        trancheConfig = _config;
        launchCreationBlock = uint32(block.number);
        launchState = LaunchState.ActiveBonding;
    }

    function currentTrancheIndex() public view returns (uint8) {
        if (trancheConfig.numTranches <= 1 || trancheConfig.curveTokenAllocation == 0) return 0;
        uint256 idx = (curveTokensSold * trancheConfig.numTranches) / trancheConfig.curveTokenAllocation;
        if (idx >= trancheConfig.numTranches) idx = trancheConfig.numTranches - 1;
        return uint8(idx);
    }

    function currentMarginalPriceQ96() public view returns (uint256) {
        uint8 idx = currentTrancheIndex();
        return uint256(trancheConfig.basePriceQ96) + uint256(idx) * uint256(trancheConfig.stepPriceIncrementQ96);
    }

    function currentAntiSnipeSurchargeBps() public view returns (uint16) {
        if (trancheConfig.antiSnipeSurchargeBps == 0 || trancheConfig.antiSnipeBlocks == 0) return 0;
        uint256 elapsed = block.number > launchCreationBlock ? block.number - launchCreationBlock : 0;
        if (elapsed >= trancheConfig.antiSnipeBlocks) return 0;
        uint256 remaining = trancheConfig.antiSnipeBlocks - elapsed;
        return uint16(
            Math.mulDiv(
                trancheConfig.antiSnipeSurchargeBps, remaining, trancheConfig.antiSnipeBlocks, Math.Rounding.Ceil
            )
        );
    }

    function buy(uint256 quoteAmountIn, uint256 minTokensOut, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut, uint256 surcharge)
    {
        if (launchState != LaunchState.ActiveBonding) revert CurveNotActive();
        if (recipient == address(0)) recipient = msg.sender;

        if (quoteCurrency.isAddressZero()) {
            require(msg.value >= quoteAmountIn, "Insufficient ETH");
        } else {
            IERC20(Currency.unwrap(quoteCurrency)).safeTransferFrom(msg.sender, address(this), quoteAmountIn);
        }

        uint16 surchargeBps = currentAntiSnipeSurchargeBps();
        surcharge = Math.mulDiv(quoteAmountIn, surchargeBps, 10_000, Math.Rounding.Ceil);
        uint256 netQuoteForTokens = quoteAmountIn - surcharge;

        uint256 priceQ96 = currentMarginalPriceQ96();
        tokensOut = Math.mulDiv(netQuoteForTokens, uint256(1) << 96, priceQ96, Math.Rounding.Floor);

        uint256 remainingTokens = trancheConfig.curveTokenAllocation - curveTokensSold;
        if (tokensOut > remainingTokens) {
            tokensOut = remainingTokens;
        }
        if (tokensOut < minTokensOut) {
            revert SlippageExceeded(tokensOut, minTokensOut);
        }

        realQuoteRaised += netQuoteForTokens;
        totalSurchargeCollected += surcharge;
        curveTokensSold += tokensOut;

        if (trancheConfig.maxWalletBps > 0) {
            uint256 supply = IERC20(projectToken).totalSupply();
            uint256 maxWallet = Math.mulDiv(supply, trancheConfig.maxWalletBps, 10_000, Math.Rounding.Floor);
            uint256 postBal = IERC20(projectToken).balanceOf(recipient) + tokensOut;
            if (postBal > maxWallet) {
                revert WalletCapExceededOnTranche(recipient, postBal, maxWallet);
            }
        }

        IERC20(projectToken).safeTransfer(recipient, tokensOut);

        emit CurveBuy(recipient, quoteAmountIn, tokensOut, surcharge, realQuoteRaised);

        if (
            realQuoteRaised >= trancheConfig.graduationQuoteTarget
                || curveTokensSold >= trancheConfig.curveTokenAllocation
        ) {
            _graduateToV4();
        }
    }

    function _graduateToV4() internal {
        launchState = LaunchState.Graduated;

        uint256 kingPotSeed =
            Math.mulDiv(totalSurchargeCollected, trancheConfig.surchargeToKingPotBps, 10_000, Math.Rounding.Floor);
        uint256 extraLpQuote = totalSurchargeCollected - kingPotSeed;
        uint256 quoteToSeed = realQuoteRaised + extraLpQuote;
        uint256 tokensToSeed = trancheConfig.lpTokenReserve;

        uint256 ratioX192 = Math.mulDiv(tokensToSeed, uint256(1) << 192, quoteToSeed, Math.Rounding.Floor);
        uint160 graduationSqrtPriceX96 = uint160(Math.sqrt(ratioX192));
        if (graduationSqrtPriceX96 < TickMath.MIN_SQRT_PRICE) {
            graduationSqrtPriceX96 = TickMath.MIN_SQRT_PRICE + 1;
        }
        if (graduationSqrtPriceX96 > TickMath.MAX_SQRT_PRICE) {
            graduationSqrtPriceX96 = TickMath.MAX_SQRT_PRICE - 1;
        }

        poolManager.initialize(poolKey, graduationSqrtPriceX96);
        hookOrchestrator.notifyPoolGraduated(poolId);

        poolManager.unlock(abi.encode(quoteToSeed, tokensToSeed, kingPotSeed));

        emit CurveGraduated(poolId, projectToken, quoteToSeed, tokensToSeed, graduationSqrtPriceX96);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManagerUnlock();
        (uint256 quoteToSeed, uint256 tokensToSeed, uint256 kingPotSeed) = abi.decode(data, (uint256, uint256, uint256));

        int24 spacing = poolKey.tickSpacing;
        int24 tickLower = (TickMath.MIN_TICK / spacing) * spacing;
        int24 tickUpper = (TickMath.MAX_TICK / spacing) * spacing;

        uint256 liquidityEstimate = Math.sqrt(quoteToSeed * tokensToSeed);
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

        if (kingPotSeed > 0) {
            poolKey.currency0.settle(poolManager, address(this), kingPotSeed, false);
            poolManager.mint(address(hookOrchestrator), poolKey.currency0.toId(), kingPotSeed);
        }

        return "";
    }
}
