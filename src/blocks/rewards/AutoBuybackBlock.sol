// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";
import {HookPermissionMasks} from "../../libraries/HookPermissionMasks.sol";
import {PoolTokenDir} from "../../libraries/PoolTokenDir.sol";
import {TransientContext} from "../../libraries/TransientContext.sol";
import {KingOfThePoolLogic} from "./KingOfThePoolBlock.sol";

library AutoBuybackLogic {
    using PoolIdLibrary for PoolKey;

    uint16 internal constant MAX_AUTO_BUYBACK_BPS = 500; // 5.00% hard cap

    struct AutoBuybackState {
        uint16 buybackFeeBps;
        int24 triggerFloorTick;
        uint128 minBuybackReserve;
        uint256 totalFloorDefendedAmount;
        mapping(Currency currency => uint256 reserve) reserveByCurrency;
    }

    event BuybackReserveAccumulated(PoolId indexed poolId, Currency indexed currency, uint256 added, uint256 reserve);
    event FloorBuybackTriggered(
        PoolId indexed poolId, Currency indexed currency, int24 postSwapTick, uint256 amountDeployed
    );
    event LPRewardsDonated(PoolId indexed poolId, uint256 amount0, uint256 amount1);

    error AutoBuybackFeeExceedsCap(uint16 requestedBps);
    error InvalidAutoBuybackFloorTick(int24 triggerFloorTick);

    function init(
        mapping(PoolId => AutoBuybackState) storage states,
        PoolId poolId,
        IHookRigBlock.AutoBuybackParams calldata params
    ) external {
        if (params.buybackFeeBps > MAX_AUTO_BUYBACK_BPS) {
            revert AutoBuybackFeeExceedsCap(params.buybackFeeBps);
        }
        if (
            params.triggerFloorTick < TickMath.MIN_TICK || params.triggerFloorTick > TickMath.MAX_TICK
                || (params.buybackFeeBps > 0 && params.minBuybackReserve == 0)
        ) {
            revert InvalidAutoBuybackFloorTick(params.triggerFloorTick);
        }
        AutoBuybackState storage st = states[poolId];
        st.buybackFeeBps = params.buybackFeeBps;
        st.triggerFloorTick = params.triggerFloorTick;
        st.minBuybackReserve = params.minBuybackReserve;
        st.totalFloorDefendedAmount = 0;
    }

    function accumulateAndCheckTrigger(
        mapping(PoolId => AutoBuybackState) storage states,
        PoolId poolId,
        Currency cutCurrency,
        uint256 cutAmount,
        int24 postSwapTick,
        bool isToken0ProjectToken,
        bool hasActiveLiquidity
    ) public returns (uint256 deployedToFloor) {
        AutoBuybackState storage st = states[poolId];
        uint256 newReserve = st.reserveByCurrency[cutCurrency] + cutAmount;
        if (cutAmount > 0) {
            st.reserveByCurrency[cutCurrency] = newReserve;
            emit BuybackReserveAccumulated(poolId, cutCurrency, cutAmount, newReserve);
        }

        bool isBelowFloor =
            isToken0ProjectToken ? (postSwapTick >= st.triggerFloorTick) : (postSwapTick <= st.triggerFloorTick);

        if (
            hasActiveLiquidity && !TransientContext.wasLiquidityAddedInTx(poolId) && st.minBuybackReserve > 0
                && newReserve >= st.minBuybackReserve && isBelowFloor
        ) {
            deployedToFloor = newReserve;
            st.reserveByCurrency[cutCurrency] = 0;
            st.totalFloorDefendedAmount += deployedToFloor;
            emit FloorBuybackTriggered(poolId, cutCurrency, postSwapTick, deployedToFloor);
        }
    }

    function processWaterfallBuyback(
        mapping(PoolId => AutoBuybackState) storage autoBuybackStates,
        IPoolManager manager,
        PoolId poolId,
        Currency unspecifiedCurrency,
        uint256 grossAmount,
        int24 postSwapTick,
        bool isExactInput,
        bool isToken0ProjectToken,
        bool hasActiveLiquidity,
        uint256 totalCutAmount
    ) external returns (uint256 newTotalCut, uint256 addedLpDonation) {
        uint256 bbCut;
        {
            uint16 bbBps = autoBuybackStates[poolId].buybackFeeBps;
            if (bbBps == 0) return (totalCutAmount, 0);
            bbCut = _boundedCut(grossAmount, isExactInput, bbBps, totalCutAmount);
        }
        newTotalCut = totalCutAmount + bbCut;
        addedLpDonation = accumulateAndCheckTrigger(
            autoBuybackStates,
            poolId,
            unspecifiedCurrency,
            bbCut,
            postSwapTick,
            isToken0ProjectToken,
            hasActiveLiquidity
        );
        if (addedLpDonation > 0) {
            if (addedLpDonation > bbCut) {
                manager.burn(address(this), unspecifiedCurrency.toId(), addedLpDonation - bbCut);
            }
        } else if (bbCut > 0) {
            manager.mint(address(this), unspecifiedCurrency.toId(), bbCut);
        }
    }

    function settleLPDonation(
        mapping(PoolId => uint256) storage totalLPRewardsDonated,
        IPoolManager manager,
        PoolKey calldata key,
        bool hasActiveLiquidity,
        Currency unspecifiedCurrency,
        uint256 totalCutAmount,
        uint256 lpDonationAmount
    ) external returns (uint256 finalTotalCut) {
        finalTotalCut = totalCutAmount;
        if (hasActiveLiquidity) {
            PoolId poolId = key.toId();
            uint256 amount0 = unspecifiedCurrency == key.currency0 ? lpDonationAmount : 0;
            uint256 amount1 = unspecifiedCurrency == key.currency1 ? lpDonationAmount : 0;
            manager.donate(key, amount0, amount1, "");
            totalLPRewardsDonated[poolId] += lpDonationAmount;
            emit LPRewardsDonated(poolId, amount0, amount1);
        } else {
            finalTotalCut -= lpDonationAmount;
        }
    }

    function _boundedCut(uint256 grossAmount, bool isExactInput, uint16 bps, uint256 currentTotal)
        private
        pure
        returns (uint256 cut)
    {
        Math.Rounding rounding = isExactInput ? Math.Rounding.Floor : Math.Rounding.Ceil;
        uint256 maxAllowed = Math.mulDiv(grossAmount, 2500, 10_000, rounding);
        if (currentTotal >= maxAllowed) return 0;
        cut = Math.mulDiv(grossAmount, bps, 10_000, rounding);
        if (currentTotal + cut > maxAllowed) {
            cut = maxAllowed - currentTotal;
        }
    }
}

/// @title AutoBuybackBlock
/// @notice Group 4 (Rewards & Income) — Expansion Block #22: Buyback & Floor Defense
///         (`afterSwap`, `afterSwapReturnDelta`).
/// @dev Trust Level: Medium (capped at 5%; accumulates swap fee into an isolated per-currency pool reserve and deploys it
///      to defend pool liquidity when spot tick drops below `triggerFloorTick` and active liquidity > 0).
abstract contract AutoBuybackBlock is IHookRigBlock {
    mapping(PoolId poolId => AutoBuybackLogic.AutoBuybackState state) internal _autoBuybackStates;

    function _initAutoBuyback(PoolId poolId, AutoBuybackParams calldata params) internal {
        AutoBuybackLogic.init(_autoBuybackStates, poolId, params);
    }

    function _processAutoBuyback(
        PoolId poolId,
        Currency cutCurrency,
        uint256 cutAmount,
        int24 postSwapTick,
        bool isToken0ProjectToken,
        bool hasActiveLiquidity
    ) internal returns (uint256 deployedToFloor) {
        return AutoBuybackLogic.accumulateAndCheckTrigger(
            _autoBuybackStates, poolId, cutCurrency, cutAmount, postSwapTick, isToken0ProjectToken, hasActiveLiquidity
        );
    }
}
