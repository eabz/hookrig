// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library AutoBurnLogic {
    using SafeERC20 for IERC20;

    uint16 internal constant MAX_AUTO_BURN_BPS = 500; // 5.00% hard cap
    address internal constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    event TokensAutoBurned(PoolId indexed poolId, Currency indexed currency, uint256 amount);

    error AutoBurnExceedsCap(uint16 requestedBps);

    function init(
        mapping(PoolId => IHookRigBlock.AutoBurnParams) storage configs,
        PoolId poolId,
        IHookRigBlock.AutoBurnParams calldata params
    ) external {
        if (params.burnOnBuyBps > MAX_AUTO_BURN_BPS) {
            revert AutoBurnExceedsCap(params.burnOnBuyBps);
        }
        configs[poolId] = params;
    }

    function execute(
        mapping(PoolId => IHookRigBlock.AutoBurnParams) storage configs,
        mapping(PoolId => uint256) storage totalAutoBurnedByPool,
        IPoolManager manager,
        PoolId poolId,
        Currency currency,
        uint256 burnAmount
    ) public {
        if (burnAmount == 0) return;

        if (configs[poolId].useTokenBurnCall && !currency.isAddressZero()) {
            address token = Currency.unwrap(currency);
            uint256 balBefore = IERC20(token).balanceOf(address(this));
            manager.take(currency, address(this), burnAmount);
            uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
            if (received > 0) {
                try ERC20Burnable(token).burn(received) {}
                catch {
                    IERC20(token).safeTransfer(DEAD_ADDRESS, received);
                }
            }
        } else {
            manager.take(currency, DEAD_ADDRESS, burnAmount);
        }

        totalAutoBurnedByPool[poolId] += burnAmount;
        emit TokensAutoBurned(poolId, currency, burnAmount);
    }

    function processWaterfallBurn(
        mapping(PoolId => IHookRigBlock.AutoBurnParams) storage configs,
        mapping(PoolId => uint256) storage totalAutoBurnedByPool,
        IPoolManager manager,
        PoolId poolId,
        Currency unspecifiedCurrency,
        uint256 grossAmount,
        bool isExactInput,
        uint256 totalCutAmount
    ) external returns (uint256 newTotalCut) {
        newTotalCut = totalCutAmount;
        uint16 burnBps = configs[poolId].burnOnBuyBps;
        if (burnBps > 0) {
            Math.Rounding rounding = isExactInput ? Math.Rounding.Floor : Math.Rounding.Ceil;
            uint256 maxAllowed = Math.mulDiv(grossAmount, 2500, 10_000, rounding);
            if (newTotalCut < maxAllowed) {
                uint256 burnCut = Math.mulDiv(grossAmount, burnBps, 10_000, rounding);
                if (newTotalCut + burnCut > maxAllowed) burnCut = maxAllowed - newTotalCut;
                if (burnCut > 0) {
                    newTotalCut += burnCut;
                    execute(configs, totalAutoBurnedByPool, manager, poolId, unspecifiedCurrency, burnCut);
                }
            }
        }
    }
}

/// @title AutoBurnBlock
/// @notice Group 3 (Token Rules) — Block #10: Automatically burns a % of each buy (`afterSwap`, `afterSwapReturnDelta`).
/// @dev Trust Level: Medium (capped at MAX_AUTO_BURN_BPS = 500 = 5%).
abstract contract AutoBurnBlock is IHookRigBlock {
    mapping(PoolId poolId => AutoBurnParams config) internal _autoBurnConfigs;
    mapping(PoolId poolId => uint256 totalBurned) public totalAutoBurnedByPool;

    error AutoBurnExceedsCap(uint16 requestedBps);

    function _initAutoBurn(PoolId poolId, AutoBurnParams calldata params) internal {
        AutoBurnLogic.init(_autoBurnConfigs, poolId, params);
    }

    function _executeAutoBurn(IPoolManager manager, PoolId poolId, Currency currency, uint256 burnAmount) internal {
        AutoBurnLogic.execute(_autoBurnConfigs, totalAutoBurnedByPool, manager, poolId, currency, burnAmount);
    }
}
