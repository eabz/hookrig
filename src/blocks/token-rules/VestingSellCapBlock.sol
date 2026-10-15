// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library VestingSellCapLogic {
    uint16 internal constant MIN_DAILY_SELL_BPS = 50; // Minimum 0.50% per day (anti-honeypot)

    struct WalletSellEpoch {
        uint64 epochIndex;
        uint128 startOfEpochBalance;
        uint128 soldInEpoch;
    }

    error InvalidDailySellCapBps(uint16 requestedBps);
    error DailyVestingSellCapExceeded(address seller, uint256 attemptedSellTotal, uint256 maxDailyAllowed);

    function init(
        mapping(PoolId => IHookRigBlock.VestingSellCapParams) storage configs,
        PoolId poolId,
        IHookRigBlock.VestingSellCapParams calldata params
    ) external {
        if (
            params.maxDailySellBps > 0
                && (params.maxDailySellBps < MIN_DAILY_SELL_BPS || params.maxDailySellBps > 10_000)
        ) {
            revert InvalidDailySellCapBps(params.maxDailySellBps);
        }
        configs[poolId] = params;
    }

    function enforceSellCap(
        mapping(PoolId => IHookRigBlock.VestingSellCapParams) storage configs,
        mapping(PoolId => mapping(address => WalletSellEpoch)) storage epochs,
        PoolId poolId,
        Currency projectCurrency,
        address seller,
        uint256 tokensSold
    ) external {
        uint16 maxBps = configs[poolId].maxDailySellBps;
        if (maxBps == 0 || maxBps >= 10_000 || tokensSold == 0 || projectCurrency.isAddressZero()) return;

        uint64 currentEpoch = uint64(block.timestamp / 1 days);
        WalletSellEpoch storage ep = epochs[poolId][seller];

        if (ep.epochIndex != currentEpoch || ep.startOfEpochBalance == 0) {
            uint256 currentBal = IERC20(Currency.unwrap(projectCurrency)).balanceOf(seller);
            if (currentBal == 0) {
                currentBal = tokensSold;
            }
            ep.epochIndex = currentEpoch;
            ep.startOfEpochBalance = uint128(currentBal > type(uint128).max ? type(uint128).max : currentBal);
            ep.soldInEpoch = 0;
        }

        uint256 maxAllowed = Math.mulDiv(ep.startOfEpochBalance, maxBps, 10_000, Math.Rounding.Floor);
        if (maxAllowed == 0 && ep.startOfEpochBalance > 0) {
            maxAllowed = 1;
        }
        uint256 newSoldTotal = uint256(ep.soldInEpoch) + tokensSold;
        if (newSoldTotal > maxAllowed) {
            revert DailyVestingSellCapExceeded(seller, newSoldTotal, maxAllowed);
        }

        ep.soldInEpoch = uint128(newSoldTotal);
    }
}

/// @title VestingSellCapBlock
/// @notice Group 3 (Token Rules) — Expansion Block #21: Vesting / Daily Sell Cap (`beforeSwap`, `afterSwap`).
/// @dev Trust Level: Low (caps the percentage of a wallet's balance that can be sold per 24-hour epoch;
///      bounded by MIN_DAILY_SELL_BPS = 50 = 0.50%/day so selling can never be bricked).
abstract contract VestingSellCapBlock is IHookRigBlock {
    mapping(PoolId poolId => VestingSellCapParams config) internal _vestingSellConfigs;
    mapping(PoolId poolId => mapping(address seller => VestingSellCapLogic.WalletSellEpoch epoch)) internal
        _walletSellEpochs;

    function _initVestingSellCap(PoolId poolId, VestingSellCapParams calldata params) internal {
        VestingSellCapLogic.init(_vestingSellConfigs, poolId, params);
    }

    function _enforceVestingSellCap(PoolId poolId, Currency projectCurrency, address seller, uint256 tokensSold)
        internal
    {
        VestingSellCapLogic.enforceSellCap(
            _vestingSellConfigs, _walletSellEpochs, poolId, projectCurrency, seller, tokensSold
        );
    }
}
