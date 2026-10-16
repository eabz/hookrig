// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";
import {HookPermissionMasks} from "../../libraries/HookPermissionMasks.sol";
import {PoolTokenDir} from "../../libraries/PoolTokenDir.sol";
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
        /// @dev LP donations (ArbRecapture, LPRewards, deployed buyback reserves) held as hook ERC-6909 claims
        ///      until a later swap flushes them, so the swap that pays a cut cannot target its own donation.
        mapping(Currency currency => uint256 amount) pendingDonation;
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

    /// @notice Adds `cutAmount` to the reserve of `cutCurrency`. `minBuybackReserve` is denominated in the quote
    ///         currency; once the quote reserve reaches it while the price is below the floor, both currency
    ///         reserves move into the pending LP donation (so no reserve waits on a threshold in the wrong unit).
    function accumulateAndCheckTrigger(
        mapping(PoolId => AutoBuybackState) storage states,
        PoolId poolId,
        Currency cutCurrency,
        uint256 cutAmount,
        int24 postSwapTick,
        Currency projectCurrency,
        Currency quoteCurrency
    ) public {
        AutoBuybackState storage st = states[poolId];
        if (cutAmount > 0) {
            uint256 newReserve = st.reserveByCurrency[cutCurrency] + cutAmount;
            st.reserveByCurrency[cutCurrency] = newReserve;
            emit BuybackReserveAccumulated(poolId, cutCurrency, cutAmount, newReserve);
        }

        bool isToken0ProjectToken = Currency.unwrap(projectCurrency) < Currency.unwrap(quoteCurrency);
        // When token0 is the project token, its price in token1 is 1.0001^tick (a price drop moves tick down).
        // When token1 is the project token, its price in token0 is 1.0001^(-tick) (a price drop moves tick up).
        bool isBelowFloor =
            isToken0ProjectToken ? (postSwapTick <= st.triggerFloorTick) : (postSwapTick >= st.triggerFloorTick);
        uint256 quoteReserve = st.reserveByCurrency[quoteCurrency];

        if (st.minBuybackReserve > 0 && quoteReserve >= st.minBuybackReserve && isBelowFloor) {
            uint256 projectReserve = st.reserveByCurrency[projectCurrency];
            st.reserveByCurrency[quoteCurrency] = 0;
            st.reserveByCurrency[projectCurrency] = 0;
            st.pendingDonation[quoteCurrency] += quoteReserve;
            st.pendingDonation[projectCurrency] += projectReserve;
            st.totalFloorDefendedAmount += quoteReserve;
            emit FloorBuybackTriggered(poolId, quoteCurrency, postSwapTick, quoteReserve);
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
        Currency projectCurrency,
        Currency quoteCurrency,
        uint256 totalCutAmount
    ) external returns (uint256 newTotalCut) {
        uint256 bbCut;
        {
            uint16 bbBps = autoBuybackStates[poolId].buybackFeeBps;
            if (bbBps == 0) return totalCutAmount;
            bbCut = _boundedCut(grossAmount, isExactInput, bbBps, totalCutAmount);
        }
        newTotalCut = totalCutAmount + bbCut;
        if (bbCut > 0) {
            manager.mint(address(this), unspecifiedCurrency.toId(), bbCut);
        }
        accumulateAndCheckTrigger(
            autoBuybackStates, poolId, unspecifiedCurrency, bbCut, postSwapTick, projectCurrency, quoteCurrency
        );
    }

    /// @notice Holds an LP donation cut as hook ERC-6909 claims until `flushPendingDonations` pays it out.
    function queueLPDonation(
        mapping(PoolId => AutoBuybackState) storage states,
        IPoolManager manager,
        PoolId poolId,
        Currency currency,
        uint256 amount
    ) external {
        manager.mint(address(this), currency.toId(), amount);
        states[poolId].pendingDonation[currency] += amount;
    }

    /// @notice Donates queued LP donations to in-range liquidity before a swap moves the price. Skipped while
    ///         liquidity was added in the current block, so just-in-time positions cannot collect them.
    function flushPendingDonations(
        mapping(PoolId => AutoBuybackState) storage states,
        mapping(PoolId => uint256) storage totalLPRewardsDonated,
        mapping(PoolId => uint256) storage lastLiquidityAddBlock,
        IPoolManager manager,
        PoolKey calldata key
    ) external {
        PoolId poolId = key.toId();
        if (lastLiquidityAddBlock[poolId] >= block.number) return;
        AutoBuybackState storage st = states[poolId];
        uint256 amount0 = st.pendingDonation[key.currency0];
        uint256 amount1 = st.pendingDonation[key.currency1];
        if ((amount0 == 0 && amount1 == 0) || StateLibrary.getLiquidity(manager, poolId) == 0) return;

        st.pendingDonation[key.currency0] = 0;
        st.pendingDonation[key.currency1] = 0;
        manager.donate(key, amount0, amount1, "");
        if (amount0 > 0) manager.burn(address(this), key.currency0.toId(), amount0);
        if (amount1 > 0) manager.burn(address(this), key.currency1.toId(), amount1);
        totalLPRewardsDonated[poolId] += amount0 + amount1;
        emit LPRewardsDonated(poolId, amount0, amount1);
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
    /// @dev Last block in which liquidity was added; pending LP donations wait until a later block.
    mapping(PoolId poolId => uint256 blockNumber) internal _lastLiquidityAddBlock;

    function _initAutoBuyback(PoolId poolId, AutoBuybackParams calldata params) internal {
        AutoBuybackLogic.init(_autoBuybackStates, poolId, params);
    }

    /// @notice Pending LP donation for `currency` that the next eligible swap will donate.
    function pendingLPDonation(PoolId poolId, Currency currency) external view returns (uint256) {
        return _autoBuybackStates[poolId].pendingDonation[currency];
    }
}
