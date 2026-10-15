// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library MarketHoursFeeLogic {
    uint24 internal constant MAX_MARKET_HOURS_FEE = 50_000; // 5.00%

    error InvalidMarketHoursConfig();

    function init(
        mapping(PoolId => IHookRigBlock.MarketHoursFeeParams) storage configs,
        PoolId poolId,
        IHookRigBlock.MarketHoursFeeParams calldata params
    ) external {
        if (
            params.openHourUtc >= 24 || params.closeHourUtc >= 24 || params.openFee > MAX_MARKET_HOURS_FEE
                || params.closedFee > MAX_MARKET_HOURS_FEE
                || (params.openHourUtc == params.closeHourUtc && params.openFee != params.closedFee)
        ) {
            revert InvalidMarketHoursConfig();
        }
        configs[poolId] = params;
    }

    function computeFee(mapping(PoolId => IHookRigBlock.MarketHoursFeeParams) storage configs, PoolId poolId)
        external
        view
        returns (uint24)
    {
        IHookRigBlock.MarketHoursFeeParams storage cfg = configs[poolId];
        uint24 openFee = cfg.openFee;
        uint24 closedFee = cfg.closedFee;
        if (openFee == 0 && closedFee == 0) return 0;

        uint256 dayOfWeek = ((block.timestamp / 86400) + 4) % 7;
        if (cfg.weekendClosed && (dayOfWeek == 0 || dayOfWeek == 6)) {
            return closedFee;
        }

        uint8 currentHourUtc = uint8((block.timestamp / 3600) % 24);
        uint8 openH = cfg.openHourUtc;
        uint8 closeH = cfg.closeHourUtc;
        bool isOpen = openH <= closeH
            ? (currentHourUtc >= openH && currentHourUtc < closeH)
            : (currentHourUtc >= openH || currentHourUtc < closeH);

        return isOpen ? openFee : closedFee;
    }
}

/// @title MarketHoursFeeBlock
/// @notice Group 1 (Fees) — Block #3: UTC market-hours schedule fee (`afterInitialize`, `beforeSwap`).
/// @dev Trust Level: Low (immutable UTC schedule once initialized; designed for RWA / Stock-quoted tokens).
abstract contract MarketHoursFeeBlock is IHookRigBlock {
    mapping(PoolId poolId => MarketHoursFeeParams params) internal _marketHoursConfigs;

    function _initMarketHoursFee(PoolId poolId, MarketHoursFeeParams calldata params) internal {
        MarketHoursFeeLogic.init(_marketHoursConfigs, poolId, params);
    }

    function _computeMarketHoursFee(PoolId poolId) internal view returns (uint24) {
        return MarketHoursFeeLogic.computeFee(_marketHoursConfigs, poolId);
    }
}
