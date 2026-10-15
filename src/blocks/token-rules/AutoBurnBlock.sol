// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

/// @title AutoBurnBlock
/// @notice Group 3 (Token Rules) — Block #10: Automatically burns a % of each buy (`afterSwap`, `afterSwapReturnDelta`).
/// @dev Trust Level: Medium (capped at MAX_AUTO_BURN_BPS = 500 = 5%).
abstract contract AutoBurnBlock is IHookRigBlock {
    uint16 internal constant MAX_AUTO_BURN_BPS = 500; // 5.00% hard cap
    address internal constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    mapping(PoolId poolId => AutoBurnParams config) internal _autoBurnConfigs;
    mapping(PoolId poolId => uint256 totalBurned) public totalAutoBurnedByPool;

    event TokensAutoBurned(PoolId indexed poolId, Currency indexed currency, uint256 amount);

    error AutoBurnExceedsCap(uint16 requestedBps);

    function _initAutoBurn(PoolId poolId, AutoBurnParams calldata params) internal {
        if (params.burnOnBuyBps > MAX_AUTO_BURN_BPS) {
            revert AutoBurnExceedsCap(params.burnOnBuyBps);
        }
        _autoBurnConfigs[poolId] = params;
    }

    function _executeAutoBurn(IPoolManager manager, PoolId poolId, Currency currency, uint256 burnAmount) internal {
        if (burnAmount == 0) return;

        if (_autoBurnConfigs[poolId].useTokenBurnCall && !currency.isAddressZero()) {
            manager.take(currency, address(this), burnAmount);
            ERC20Burnable(Currency.unwrap(currency)).burn(burnAmount);
        } else {
            manager.take(currency, DEAD_ADDRESS, burnAmount);
        }

        totalAutoBurnedByPool[poolId] += burnAmount;
        emit TokensAutoBurned(poolId, currency, burnAmount);
    }
}
