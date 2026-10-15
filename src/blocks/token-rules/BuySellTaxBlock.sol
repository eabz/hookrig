// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library BuySellTaxLogic {
    uint16 internal constant MAX_TAX_BPS = 1000; // 10.00% hard anti-rug ceiling

    event BuySellTaxUpdated(PoolId indexed poolId, uint16 buyTaxBps, uint16 sellTaxBps, address recipient);

    error TaxExceedsHardCap(uint16 buyTaxBps, uint16 sellTaxBps);
    error TaxIncreaseForbiddenInDecayOnlyMode();
    error InvalidTaxRecipient();

    function init(
        mapping(PoolId => IHookRigBlock.BuySellTaxParams) storage configs,
        PoolId poolId,
        IHookRigBlock.BuySellTaxParams calldata params
    ) external {
        if (params.buyTaxBps > MAX_TAX_BPS || params.sellTaxBps > MAX_TAX_BPS) {
            revert TaxExceedsHardCap(params.buyTaxBps, params.sellTaxBps);
        }
        if ((params.buyTaxBps > 0 || params.sellTaxBps > 0) && params.taxRecipient == address(0)) {
            revert InvalidTaxRecipient();
        }
        configs[poolId] = params;
    }

    function update(
        mapping(PoolId => IHookRigBlock.BuySellTaxParams) storage configs,
        PoolId poolId,
        uint16 newBuyTaxBps,
        uint16 newSellTaxBps,
        address newRecipient
    ) external {
        if (newBuyTaxBps > MAX_TAX_BPS || newSellTaxBps > MAX_TAX_BPS) {
            revert TaxExceedsHardCap(newBuyTaxBps, newSellTaxBps);
        }
        IHookRigBlock.BuySellTaxParams storage cfg = configs[poolId];
        if (cfg.decayOnly && (newBuyTaxBps > cfg.buyTaxBps || newSellTaxBps > cfg.sellTaxBps)) {
            revert TaxIncreaseForbiddenInDecayOnlyMode();
        }
        if ((newBuyTaxBps > 0 || newSellTaxBps > 0) && newRecipient == address(0)) {
            revert InvalidTaxRecipient();
        }
        cfg.buyTaxBps = newBuyTaxBps;
        cfg.sellTaxBps = newSellTaxBps;
        if (newRecipient != address(0)) {
            cfg.taxRecipient = newRecipient;
        }
        emit BuySellTaxUpdated(poolId, newBuyTaxBps, newSellTaxBps, cfg.taxRecipient);
    }
}

/// @title BuySellTaxBlock
/// @notice Group 3 (Token Rules) — Block #9: Configurable buy tax and sell tax in bps (`afterSwap`, `afterSwapReturnDelta`).
/// @dev Trust Level: Medium (strictly capped at MAX_TAX_BPS = 1000 = 10%; supports decay-only anti-honeypot mode).
abstract contract BuySellTaxBlock is IHookRigBlock {
    mapping(PoolId poolId => BuySellTaxParams config) internal _taxConfigs;

    function _initBuySellTax(PoolId poolId, BuySellTaxParams calldata params) internal {
        BuySellTaxLogic.init(_taxConfigs, poolId, params);
    }

    function _updateBuySellTax(PoolId poolId, uint16 newBuyTaxBps, uint16 newSellTaxBps, address newRecipient)
        internal
    {
        BuySellTaxLogic.update(_taxConfigs, poolId, newBuyTaxBps, newSellTaxBps, newRecipient);
    }

    function _getApplicableTaxBps(PoolId poolId, bool isBuy) internal view returns (uint16 taxBps, address recipient) {
        BuySellTaxParams storage cfg = _taxConfigs[poolId];
        taxBps = isBuy ? cfg.buyTaxBps : cfg.sellTaxBps;
        recipient = cfg.taxRecipient;
    }
}
