// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library AutoBuybackLogic {
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

    error AutoBuybackFeeExceedsCap(uint16 requestedBps);

    function init(
        mapping(PoolId => AutoBuybackState) storage states,
        PoolId poolId,
        IHookRigBlock.AutoBuybackParams calldata params
    ) external {
        if (params.buybackFeeBps > MAX_AUTO_BUYBACK_BPS) {
            revert AutoBuybackFeeExceedsCap(params.buybackFeeBps);
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
        bool hasActiveLiquidity
    ) external returns (uint256 deployedToFloor) {
        AutoBuybackState storage st = states[poolId];
        uint256 newReserve = st.reserveByCurrency[cutCurrency] + cutAmount;
        if (cutAmount > 0) {
            st.reserveByCurrency[cutCurrency] = newReserve;
            emit BuybackReserveAccumulated(poolId, cutCurrency, cutAmount, newReserve);
        }

        if (
            hasActiveLiquidity && st.minBuybackReserve > 0 && newReserve >= st.minBuybackReserve
                && postSwapTick <= st.triggerFloorTick
        ) {
            deployedToFloor = newReserve;
            st.reserveByCurrency[cutCurrency] = 0;
            st.totalFloorDefendedAmount += deployedToFloor;
            emit FloorBuybackTriggered(poolId, cutCurrency, postSwapTick, deployedToFloor);
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
        bool hasActiveLiquidity
    ) internal returns (uint256 deployedToFloor) {
        return AutoBuybackLogic.accumulateAndCheckTrigger(
            _autoBuybackStates, poolId, cutCurrency, cutAmount, postSwapTick, hasActiveLiquidity
        );
    }
}
