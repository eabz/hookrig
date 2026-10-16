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
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

/// @title SteppedTrancheLaunch
/// @notice Curve Model #2: Anti-bundle stepped tranche curve with active `WalletCap` and `AntiSnipe` surcharges
///         during bonding. Surcharges seed extra graduation LP depth and Round #1 `KingOfThePool` jackpot.
///         Includes pre-graduation `sell()` so stalled launches can never freeze buyer capital.
contract SteppedTrancheLaunch is ITokenLaunchpad, IUnlockCallback, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;

    uint32 public constant MAX_ANTI_SNIPE_BLOCKS = 50_400;

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
    /// @notice Tranche price paid by the latest curve buy; graduation opens the pool at this price.
    uint256 public lastFillPriceQ96;
    mapping(address => uint256) public buyerSurcharges;
    mapping(address => uint256) public cumulativeTokensBought;
    mapping(address => uint256) public cumulativeTokensSoldByBuyer;
    bool public stalledRefundActive;

    error AlreadyInitialized();
    error CurveNotActive();
    error ZeroAmount();
    error InvalidTrancheConfiguration();
    error SlippageExceeded(uint256 actual, uint256 minimumRequired);
    error WalletCapExceededOnTranche(address buyer, uint256 newBalance, uint256 maxAllowed);
    error OnlyPoolManagerUnlock();
    error UnsupportedFeeOnTransferQuoteToken();

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
        if (_config.antiSnipeBlocks > MAX_ANTI_SNIPE_BLOCKS) {
            revert InvalidTrancheConfiguration();
        }
        if (
            _config.numTranches == 0 || _config.curveTokenAllocation == 0 || _config.graduationQuoteTarget == 0
                || _config.basePriceQ96 == 0 || _config.antiSnipeSurchargeBps >= 10_000
                || _config.surchargeToKingPotBps > 10_000
        ) {
            revert ZeroAmount();
        }

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
        if (launchState != LaunchState.ActiveBonding || stalledRefundActive) revert CurveNotActive();
        if (quoteAmountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) recipient = msg.sender;

        uint16 surchargeBps = currentAntiSnipeSurchargeBps();
        uint256 remainingQuoteToTarget = trancheConfig.graduationQuoteTarget - realQuoteRaised;
        uint256 maxGrossInput = Math.mulDiv(remainingQuoteToTarget, 10_000, 10_000 - surchargeBps, Math.Rounding.Ceil);
        uint256 quoteUsed = quoteAmountIn > maxGrossInput && maxGrossInput > 0 ? maxGrossInput : quoteAmountIn;

        surcharge = Math.mulDiv(quoteUsed, surchargeBps, 10_000, Math.Rounding.Ceil);
        uint256 netQuoteForTokens = quoteUsed - surcharge;

        {
            uint256 priceQ96 = currentMarginalPriceQ96();
            lastFillPriceQ96 = priceQ96;
            uint256 remainingTokens = trancheConfig.curveTokenAllocation - curveTokensSold;
            tokensOut = Math.mulDiv(netQuoteForTokens, uint256(1) << 96, priceQ96, Math.Rounding.Floor);
            if (tokensOut > remainingTokens) {
                tokensOut = remainingTokens;
                netQuoteForTokens = Math.mulDiv(tokensOut, priceQ96, uint256(1) << 96, Math.Rounding.Ceil);
                quoteUsed = Math.mulDiv(netQuoteForTokens, 10_000, 10_000 - surchargeBps, Math.Rounding.Ceil);
                surcharge = Math.mulDiv(quoteUsed, surchargeBps, 10_000, Math.Rounding.Ceil);
                netQuoteForTokens = quoteUsed > surcharge ? quoteUsed - surcharge : 0;
            }
        }
        if (tokensOut == 0 && realQuoteRaised + netQuoteForTokens < trancheConfig.graduationQuoteTarget) {
            revert ZeroAmount();
        }
        if (tokensOut < minTokensOut) {
            revert SlippageExceeded(tokensOut, minTokensOut);
        }

        if (quoteCurrency.isAddressZero()) {
            require(msg.value >= quoteUsed, "Insufficient ETH");
        } else {
            require(msg.value == 0, "Unexpected ETH");
            if (quoteUsed > 0) {
                IERC20 quoteToken = IERC20(Currency.unwrap(quoteCurrency));
                uint256 balBefore = quoteToken.balanceOf(address(this));
                quoteToken.safeTransferFrom(msg.sender, address(this), quoteUsed);
                if (quoteToken.balanceOf(address(this)) - balBefore != quoteUsed) {
                    revert UnsupportedFeeOnTransferQuoteToken();
                }
            }
        }

        realQuoteRaised += netQuoteForTokens;
        totalSurchargeCollected += surcharge;
        curveTokensSold += tokensOut;
        buyerSurcharges[msg.sender] += surcharge;
        cumulativeTokensBought[msg.sender] += tokensOut;

        if (trancheConfig.maxWalletBps > 0) {
            uint256 supply = IERC20(projectToken).totalSupply();
            uint256 maxWallet = Math.mulDiv(supply, trancheConfig.maxWalletBps, 10_000, Math.Rounding.Floor);
            uint256 postBal = IERC20(projectToken).balanceOf(recipient) + tokensOut;
            if (postBal > maxWallet) {
                revert WalletCapExceededOnTranche(recipient, postBal, maxWallet);
            }
        }

        IERC20(projectToken).safeTransfer(recipient, tokensOut);

        if (quoteCurrency.isAddressZero() && msg.value > quoteUsed) {
            quoteCurrency.transfer(msg.sender, msg.value - quoteUsed);
        }

        emit CurveBuy(recipient, quoteUsed, tokensOut, surcharge, realQuoteRaised);

        if (
            realQuoteRaised >= trancheConfig.graduationQuoteTarget
                || curveTokensSold >= trancheConfig.curveTokenAllocation
        ) {
            _graduateToV4();
        }
    }

    /// @notice Anti-freeze guarantee: allows buyers to sell tokens back into the stepped curve prior to graduation
    ///         so capital is never permanently locked if a launch stalls before reaching `graduationQuoteTarget`.
    function sell(uint256 tokenAmountIn, uint256 minQuoteOut, address recipient)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        if (launchState != LaunchState.ActiveBonding) revert CurveNotActive();
        if (tokenAmountIn == 0 || tokenAmountIn > curveTokensSold) revert ZeroAmount();
        if (recipient == address(0)) recipient = msg.sender;

        IERC20(projectToken).safeTransferFrom(msg.sender, address(this), tokenAmountIn);

        uint256 baseRedemption =
            Math.mulDiv(tokenAmountIn, uint256(trancheConfig.basePriceQ96), uint256(1) << 96, Math.Rounding.Floor);
        uint256 proRataCap = Math.mulDiv(realQuoteRaised, tokenAmountIn, curveTokensSold, Math.Rounding.Floor);
        quoteOut = baseRedemption < proRataCap ? baseRedemption : proRataCap;

        uint256 bought = cumulativeTokensBought[msg.sender];
        uint256 alreadySold = cumulativeTokensSoldByBuyer[msg.sender];
        if (bought > alreadySold) {
            uint256 remBought = bought - alreadySold;
            uint256 credit = tokenAmountIn > remBought ? remBought : tokenAmountIn;
            cumulativeTokensSoldByBuyer[msg.sender] = alreadySold + credit;
        }

        if (quoteOut < minQuoteOut) {
            revert SlippageExceeded(quoteOut, minQuoteOut);
        }

        realQuoteRaised -= quoteOut;
        curveTokensSold -= tokenAmountIn;

        if (quoteOut > 0) {
            quoteCurrency.transfer(recipient, quoteOut);
        }

        emit CurveSell(msg.sender, tokenAmountIn, quoteOut, realQuoteRaised);
    }

    /// @notice Allows buyers who sold back into a fully stalled curve after `antiSnipeBlocks + MAX_ANTI_SNIPE_BLOCKS`
    ///         (once all active bonding quote has exited) to withdraw their pro-rata anti-snipe surcharge refund (`S3-F64`).
    function claimStalledSurchargeRefund(address recipient) external nonReentrant returns (uint256 refundAmount) {
        if (launchState != LaunchState.ActiveBonding) revert CurveNotActive();
        if (
            block.number
                <= uint256(launchCreationBlock) + uint256(trancheConfig.antiSnipeBlocks) + MAX_ANTI_SNIPE_BLOCKS
                || curveTokensSold > 0
        ) {
            revert CurveNotActive();
        }
        uint256 bought = cumulativeTokensBought[msg.sender];
        uint256 sold = cumulativeTokensSoldByBuyer[msg.sender];
        uint256 surch = buyerSurcharges[msg.sender];
        if (bought == 0 || sold == 0 || surch == 0) revert ZeroAmount();

        refundAmount = Math.mulDiv(surch, sold, bought, Math.Rounding.Floor);
        if (refundAmount > surch) refundAmount = surch;
        if (refundAmount > totalSurchargeCollected) refundAmount = totalSurchargeCollected;
        if (refundAmount == 0) revert ZeroAmount();

        stalledRefundActive = true;
        buyerSurcharges[msg.sender] = surch - refundAmount;
        totalSurchargeCollected -= refundAmount;
        cumulativeTokensBought[msg.sender] = bought - sold;
        cumulativeTokensSoldByBuyer[msg.sender] = 0;

        if (recipient == address(0)) recipient = msg.sender;
        quoteCurrency.transfer(recipient, refundAmount);
    }

    function _graduateToV4() internal {
        launchState = LaunchState.Graduated;

        IHookRigOrchestrator hook = IHookRigOrchestrator(address(poolKey.hooks));
        // Seed the King pot only when the pool runs King of the Pool; otherwise every surcharge deepens the LP.
        uint256 kingPotSeed = hook.isBlockEnabled(poolId, IHookRigBlock.BlockId.KingOfThePool)
            ? Math.mulDiv(totalSurchargeCollected, trancheConfig.surchargeToKingPotBps, 10_000, Math.Rounding.Floor)
            : 0;
        uint256 extraLpQuote = totalSurchargeCollected - kingPotSeed;
        uint256 quoteToSeed = realQuoteRaised + extraLpQuote;

        // Price of the last fill, not of `currentTrancheIndex()`: a final buy that crosses a tranche boundary only by
        // rounding dust would otherwise open the pool at a price no buyer paid.
        uint256 finalPriceQ96 = lastFillPriceQ96 > 0 ? lastFillPriceQ96 : currentMarginalPriceQ96();
        uint256 continuousLpTokens = Math.mulDiv(quoteToSeed, uint256(1) << 96, finalPriceQ96, Math.Rounding.Floor);
        uint256 availableTokens = IERC20(projectToken).balanceOf(address(this));
        if (continuousLpTokens > availableTokens) {
            quoteToSeed = Math.mulDiv(quoteToSeed, availableTokens, continuousLpTokens, Math.Rounding.Floor);
            continuousLpTokens = availableTokens;
        }
        if (continuousLpTokens == 0) {
            continuousLpTokens = trancheConfig.lpTokenReserve;
        }
        trancheConfig.lpTokenReserve = uint128(continuousLpTokens);
        uint256 tokensToSeed = continuousLpTokens;

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

        poolManager.initialize(poolKey, graduationSqrtPriceX96);
        hook.notifyPoolGraduated(poolId);

        poolManager.unlock(abi.encode(quoteToSeed, tokensToSeed, kingPotSeed));

        if (kingPotSeed > 0) {
            hook.seedKingPotFromLaunchCurve(poolId, poolKey.currency0, kingPotSeed);
        }

        emit CurveGraduated(poolId, projectToken, quoteToSeed, tokensToSeed, graduationSqrtPriceX96);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManagerUnlock();
        (uint256 quoteToSeed, uint256 tokensToSeed, uint256 kingPotSeed) = abi.decode(data, (uint256, uint256, uint256));

        int24 spacing = poolKey.tickSpacing;
        int24 tickLower = (TickMath.MIN_TICK / spacing) * spacing;
        int24 tickUpper = (TickMath.MAX_TICK / spacing) * spacing;

        uint256 baseLiquidity = (quoteToSeed <= type(uint128).max && tokensToSeed <= type(uint128).max)
            ? Math.sqrt(quoteToSeed * tokensToSeed)
            : Math.sqrt(quoteToSeed) * Math.sqrt(tokensToSeed);
        uint256 liquidityEstimate = (baseLiquidity * 9999) / 10_000;
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
            poolManager.mint(address(poolKey.hooks), poolKey.currency0.toId(), kingPotSeed);
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
