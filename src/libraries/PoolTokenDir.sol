// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title PoolTokenDir
/// @notice Normalizes Buy vs. Sell swap direction and Specified vs. Unspecified currencies
///         across Exact-Input (`amountSpecified < 0`) and Exact-Output (`amountSpecified > 0`) swaps.
library PoolTokenDir {
    struct SwapContext {
        bool isBuy; // True if trader is acquiring the project token
        bool isExactInput; // True if params.amountSpecified < 0
        Currency projectCurrency;
        Currency quoteCurrency;
        Currency specifiedCurrency;
        Currency unspecifiedCurrency;
        uint256 settledSpecifiedAmount; // Actual settled magnitude on specified leg
        uint256 grossUnspecifiedAmount; // Magnitude of unspecified delta from swap
        address trader;
        int24 preSwapTick;
        int24 postSwapTick;
    }

    /// @notice Resolves full swap directional and currency context for a given PoolKey and SwapParams.
    function resolveSwapContext(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        bool isToken0ProjectToken
    ) internal pure returns (SwapContext memory ctx) {
        ctx.projectCurrency = isToken0ProjectToken ? key.currency0 : key.currency1;
        ctx.quoteCurrency = isToken0ProjectToken ? key.currency1 : key.currency0;

        // If projectToken is currency1: zeroForOne (paying currency0 to get currency1) is a BUY.
        // If projectToken is currency0: !zeroForOne (paying currency1 to get currency0) is a BUY.
        ctx.isBuy = isToken0ProjectToken ? !params.zeroForOne : params.zeroForOne;
        ctx.isExactInput = params.amountSpecified < 0;

        bool specifiedIsToken0 = (params.zeroForOne == ctx.isExactInput);
        ctx.specifiedCurrency = specifiedIsToken0 ? key.currency0 : key.currency1;
        ctx.unspecifiedCurrency = specifiedIsToken0 ? key.currency1 : key.currency0;

        int128 rawSpecified = specifiedIsToken0 ? swapDelta.amount0() : swapDelta.amount1();
        int128 rawUnspecified = specifiedIsToken0 ? swapDelta.amount1() : swapDelta.amount0();
        if (ctx.isExactInput) {
            // In exact-input, specified is input debt (< 0) and unspecified is output credit (> 0)
            ctx.settledSpecifiedAmount = rawSpecified < 0 ? uint256(uint128(-rawSpecified)) : 0;
            ctx.grossUnspecifiedAmount = rawUnspecified > 0 ? uint256(uint128(rawUnspecified)) : 0;
        } else {
            // In exact-output, specified is output credit (> 0) and unspecified is input debt (< 0)
            ctx.settledSpecifiedAmount = rawSpecified > 0 ? uint256(uint128(rawSpecified)) : 0;
            ctx.grossUnspecifiedAmount = rawUnspecified < 0 ? uint256(uint128(-rawUnspecified)) : 0;
        }
    }
}
