// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";
import {IHookRigOrchestrator} from "../../interfaces/IHookRigOrchestrator.sol";
import {HookRigBase} from "../../base/HookRigBase.sol";
import {HookPermissionMasks} from "../../libraries/HookPermissionMasks.sol";
import {PoolTokenDir} from "../../libraries/PoolTokenDir.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {ArbRecaptureLogic} from "../protection/ArbRecaptureBlock.sol";
import {AccessControlLogic} from "../protection/AccessControlBlock.sol";
import {WalletCapLogic} from "./WalletCapBlock.sol";
import {AutoBurnLogic} from "./AutoBurnBlock.sol";
import {FeeSharingLogic} from "../rewards/FeeSharingBlock.sol";
import {LPRewardsBlock} from "../rewards/LPRewardsBlock.sol";
import {SwapRewardsLogic} from "../rewards/SwapRewardsBlock.sol";
import {KingOfThePoolLogic} from "../rewards/KingOfThePoolBlock.sol";
import {AutoBuybackLogic} from "../rewards/AutoBuybackBlock.sol";

library BuySellTaxLogic {
    using CurrencySettler for Currency;

    uint16 internal constant MAX_TAX_BPS = 1000; // 10.00% hard anti-rug ceiling
    uint16 internal constant MAX_AGGREGATE_AFTER_SWAP_BPS = 2500;

    event BuySellTaxUpdated(PoolId indexed poolId, uint16 buyTaxBps, uint16 sellTaxBps, address recipient);

    error TaxExceedsHardCap(uint16 buyTaxBps, uint16 sellTaxBps);
    error TaxIncreaseForbiddenInDecayOnlyMode();
    error InvalidTaxRecipient();

    function init(
        mapping(PoolId => IHookRigBlock.BuySellTaxParams) storage configs,
        PoolId poolId,
        IHookRigBlock.BuySellTaxParams calldata params
    ) public {
        if (params.buyTaxBps > MAX_TAX_BPS || params.sellTaxBps > MAX_TAX_BPS) {
            revert TaxExceedsHardCap(params.buyTaxBps, params.sellTaxBps);
        }
        if ((params.buyTaxBps > 0 || params.sellTaxBps > 0) && params.taxRecipient == address(0)) {
            revert InvalidTaxRecipient();
        }
        configs[poolId] = params;
    }

    function initRulesAndRewardsBlocks(
        mapping(PoolId => IHookRigBlock.AccessControlParams) storage accessConfigs,
        mapping(
            PoolId => WalletCapLogic.WalletCapState
        ) storage walletCapStates,
        mapping(PoolId => IHookRigBlock.BuySellTaxParams) storage buySellTaxConfigs,
        mapping(PoolId => IHookRigBlock.AutoBurnParams) storage autoBurnConfigs,
        mapping(PoolId => IHookRigBlock.FeeSharingParams) storage feeSharingConfigs,
        mapping(PoolId => IHookRigBlock.LPRewardsParams) storage lpRewardsConfigs,
        mapping(PoolId => IHookRigBlock.SwapRewardsParams) storage swapRewardsConfigs,
        PoolId poolId,
        IHookRigBlock.PoolStackConfig calldata config,
        uint32 bitmap,
        address admin
    ) external {
        if ((bitmap & HookPermissionMasks.BIT_ACCESS_CONTROL) != 0) {
            AccessControlLogic.init(accessConfigs, poolId, config.accessControl, admin);
        }
        if ((bitmap & HookPermissionMasks.BIT_WALLET_CAP) != 0) {
            WalletCapLogic.init(walletCapStates, poolId, config.walletCap);
        }
        if ((bitmap & HookPermissionMasks.BIT_BUY_SELL_TAX) != 0) {
            init(buySellTaxConfigs, poolId, config.buySellTax);
        }
        if ((bitmap & HookPermissionMasks.BIT_AUTO_BURN) != 0) {
            AutoBurnLogic.init(autoBurnConfigs, poolId, config.autoBurn);
        }
        if ((bitmap & HookPermissionMasks.BIT_FEE_SHARING) != 0) {
            FeeSharingLogic.init(feeSharingConfigs, poolId, config.feeSharing);
        }
        if ((bitmap & HookPermissionMasks.BIT_LP_REWARDS) != 0) {
            if (config.lpRewards.extraBuyFeeBps > 500) {
                revert LPRewardsBlock.LPRewardExceedsCap(config.lpRewards.extraBuyFeeBps);
            }
            lpRewardsConfigs[poolId] = config.lpRewards;
        }
        if ((bitmap & HookPermissionMasks.BIT_SWAP_REWARDS) != 0) {
            SwapRewardsLogic.init(swapRewardsConfigs, poolId, config.swapRewards);
        }
    }

    function update(
        mapping(PoolId => IHookRigBlock.BuySellTaxParams) storage configs,
        PoolId poolId,
        uint16 newBuyTaxBps,
        uint16 newSellTaxBps,
        address newRecipient
    ) public {
        if (newBuyTaxBps > MAX_TAX_BPS || newSellTaxBps > MAX_TAX_BPS) {
            revert TaxExceedsHardCap(newBuyTaxBps, newSellTaxBps);
        }
        IHookRigBlock.BuySellTaxParams storage cfg = configs[poolId];
        // Taxes can only ever decrease after registration (whatever `decayOnly` says), so a pool admin cannot
        // raise the tax on holders who bought under a lower one.
        if (newBuyTaxBps > cfg.buyTaxBps || newSellTaxBps > cfg.sellTaxBps) {
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

    function validateTaxBudget(
        mapping(PoolId => HookRigBase.PoolRuntimeMeta) storage poolMeta,
        mapping(PoolId => IHookRigBlock.AutoBurnParams) storage autoBurnConfigs,
        mapping(PoolId => IHookRigBlock.FeeSharingParams) storage feeSharingConfigs,
        mapping(PoolId => IHookRigBlock.LPRewardsParams) storage lpRewardsConfigs,
        mapping(PoolId => KingOfThePoolLogic.KingRoundState) storage kingStates,
        mapping(PoolId => IHookRigBlock.ReferralSplitParams) storage referralConfigs,
        mapping(PoolId => AutoBuybackLogic.AutoBuybackState) storage autoBuybackStates,
        PoolId poolId,
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        uint16 protocolRoyaltyBps,
        bool isTaxUpdateCall
    ) external view {
        HookRigBase.PoolRuntimeMeta storage meta = poolMeta[poolId];
        uint32 bitmap = meta.enabledBlocksBitmap;
        if (isTaxUpdateCall) {
            if (!meta.configured || (bitmap & HookPermissionMasks.BIT_BUY_SELL_TAX) == 0) {
                revert IHookRigOrchestrator.PoolNotConfigured(poolId);
            }
            if (msg.sender != meta.poolAdmin) revert HookRigBase.OnlyPoolAdmin(msg.sender);
        } else if ((bitmap & HookPermissionMasks.AFTER_SWAP_RETURN_DELTA_BLOCKS_MASK) == 0) {
            return;
        }

        uint256 otherBuyBps = protocolRoyaltyBps;
        uint256 otherSellBps = protocolRoyaltyBps;

        if ((bitmap & HookPermissionMasks.BIT_AUTO_BURN) != 0) {
            otherBuyBps += autoBurnConfigs[poolId].burnOnBuyBps;
        }
        if ((bitmap & HookPermissionMasks.BIT_FEE_SHARING) != 0) {
            otherBuyBps += feeSharingConfigs[poolId].feeShareBps;
            otherSellBps += feeSharingConfigs[poolId].feeShareBps;
        }
        if ((bitmap & HookPermissionMasks.BIT_LP_REWARDS) != 0) {
            otherBuyBps += lpRewardsConfigs[poolId].extraBuyFeeBps;
        }
        if ((bitmap & HookPermissionMasks.BIT_KING_OF_THE_POOL) != 0) {
            otherBuyBps += kingStates[poolId].potFeeOnBuyBps;
        }
        if ((bitmap & HookPermissionMasks.BIT_REFERRAL_SPLIT) != 0) {
            otherBuyBps += referralConfigs[poolId].referralFeeBps;
            otherSellBps += referralConfigs[poolId].referralFeeBps;
        }
        if ((bitmap & HookPermissionMasks.BIT_AUTO_BUYBACK) != 0) {
            otherBuyBps += autoBuybackStates[poolId].buybackFeeBps;
            otherSellBps += autoBuybackStates[poolId].buybackFeeBps;
        }

        uint256 newBuyTotal = otherBuyBps + ((bitmap & HookPermissionMasks.BIT_BUY_SELL_TAX) != 0 ? buyTaxBps : 0);
        uint256 newSellTotal = otherSellBps + ((bitmap & HookPermissionMasks.BIT_BUY_SELL_TAX) != 0 ? sellTaxBps : 0);
        uint256 maxTotal = newBuyTotal > newSellTotal ? newBuyTotal : newSellTotal;
        if (maxTotal > MAX_AGGREGATE_AFTER_SWAP_BPS) {
            revert IHookRigOrchestrator.AggregateReturnDeltaBpsExceeded(maxTotal, MAX_AGGREGATE_AFTER_SWAP_BPS);
        }
    }

    function processWaterfallRoyalty(
        mapping(PoolId => mapping(Currency => mapping(address => uint256))) storage poolClaims,
        IPoolManager manager,
        PoolId poolId,
        Currency unspecifiedCurrency,
        uint256 grossAmount,
        bool isExactInput,
        uint16 royaltyBps,
        address royaltyRecipient
    ) external returns (uint256 totalCutAmount) {
        if (royaltyBps > 0 && royaltyRecipient != address(0)) {
            Math.Rounding rounding = isExactInput ? Math.Rounding.Floor : Math.Rounding.Ceil;
            uint256 maxAllowed = Math.mulDiv(grossAmount, MAX_AGGREGATE_AFTER_SWAP_BPS, 10_000, rounding);
            uint256 royaltyCut = Math.mulDiv(grossAmount, royaltyBps, 10_000, rounding);
            if (royaltyCut > maxAllowed) royaltyCut = maxAllowed;
            if (royaltyCut > 0) {
                totalCutAmount = royaltyCut;
                _creditClaim(poolClaims, manager, poolId, unspecifiedCurrency, royaltyRecipient, royaltyCut);
            }
        }
    }

    function processWaterfallTax(
        mapping(PoolId => mapping(Currency => mapping(address => uint256))) storage poolClaims,
        mapping(
            PoolId => IHookRigBlock.BuySellTaxParams
        ) storage taxConfigs,
        IPoolManager manager,
        PoolId poolId,
        Currency unspecifiedCurrency,
        uint256 grossAmount,
        bool isBuy,
        bool isExactInput,
        uint256 totalCutAmount
    ) external returns (uint256 newTotalCut) {
        newTotalCut = totalCutAmount;
        IHookRigBlock.BuySellTaxParams storage cfg = taxConfigs[poolId];
        uint16 taxBps = isBuy ? cfg.buyTaxBps : cfg.sellTaxBps;
        address taxRecipient = cfg.taxRecipient;
        if (taxBps > 0 && taxRecipient != address(0)) {
            uint256 taxCut = _boundedCut(grossAmount, isExactInput, taxBps, newTotalCut);
            if (taxCut > 0) {
                newTotalCut += taxCut;
                _creditClaim(poolClaims, manager, poolId, unspecifiedCurrency, taxRecipient, taxCut);
            }
        }
    }

    function _creditClaim(
        mapping(PoolId => mapping(Currency => mapping(address => uint256))) storage poolClaims,
        IPoolManager manager,
        PoolId poolId,
        Currency currency,
        address beneficiary,
        uint256 amount
    ) private {
        if (amount == 0 || beneficiary == address(0)) return;
        currency.take(manager, address(this), amount, true);
        poolClaims[poolId][currency][beneficiary] += amount;
        emit IHookRigOrchestrator.ClaimCredited(poolId, currency, beneficiary, amount);
    }

    function _boundedCut(uint256 grossAmount, bool isExactInput, uint16 bps, uint256 currentTotal)
        private
        pure
        returns (uint256 cut)
    {
        Math.Rounding rounding = isExactInput ? Math.Rounding.Floor : Math.Rounding.Ceil;
        uint256 maxAllowed = Math.mulDiv(grossAmount, MAX_AGGREGATE_AFTER_SWAP_BPS, 10_000, rounding);
        if (currentTotal >= maxAllowed) return 0;
        cut = Math.mulDiv(grossAmount, bps, 10_000, rounding);
        if (currentTotal + cut > maxAllowed) {
            cut = maxAllowed - currentTotal;
        }
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

