// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";
import {TransientContext} from "../../libraries/TransientContext.sol";

library WalletCapLogic {
    uint16 internal constant MIN_WALLET_CAP_BPS = 10; // Cannot set cap below 0.10% of supply (anti-honeypot)
    uint32 internal constant MAX_SUNSET_BLOCKS = 2_628_000; // ~1 year at 12s blocks

    struct WalletCapState {
        uint16 maxWalletBps;
        uint32 startBlock;
        uint32 sunsetBlocks;
    }

    error InvalidWalletCapBps(uint16 requestedBps);
    error InvalidWalletCapSunsetBlocks(uint32 sunsetBlocks);
    error WalletCapExceeded(address buyer, uint256 resultingBalance, uint256 maxAllowedBalance);

    function init(
        mapping(PoolId => WalletCapState) storage states,
        PoolId poolId,
        IHookRigBlock.WalletCapParams calldata params
    ) external {
        if (params.maxWalletBps > 0 && (params.maxWalletBps < MIN_WALLET_CAP_BPS || params.maxWalletBps > 10_000)) {
            revert InvalidWalletCapBps(params.maxWalletBps);
        }
        if (params.sunsetBlocks > MAX_SUNSET_BLOCKS) {
            revert InvalidWalletCapSunsetBlocks(params.sunsetBlocks);
        }
        states[poolId] = WalletCapState({
            maxWalletBps: params.maxWalletBps, startBlock: uint32(block.number), sunsetBlocks: params.sunsetBlocks
        });
    }

    function enforceAfterBuy(
        mapping(PoolId => WalletCapState) storage states,
        PoolId poolId,
        Currency projectCurrency,
        address recipient,
        uint256 netProjectTokensBought
    ) external {
        WalletCapState storage state = states[poolId];
        uint16 maxBps = state.maxWalletBps;
        if (maxBps == 0 || maxBps >= 10_000) return;

        uint32 sunset = state.sunsetBlocks;
        if (sunset > 0 && block.number >= uint256(state.startBlock) + uint256(sunset)) {
            return;
        }

        if (projectCurrency.isAddressZero()) return;

        IERC20 token = IERC20(Currency.unwrap(projectCurrency));
        uint256 supply = token.totalSupply();
        if (supply == 0) return;

        uint256 maxAllowed = Math.mulDiv(supply, maxBps, 10_000, Math.Rounding.Floor);
        uint256 actualBal = token.balanceOf(recipient);
        uint256 cachedBal = TransientContext.getWalletCapExpectedBalance(poolId, recipient);
        uint256 effectivePreBal = actualBal >= cachedBal ? actualBal : cachedBal;
        uint256 postBalance = effectivePreBal + netProjectTokensBought;
        if (postBalance > maxAllowed) {
            revert WalletCapExceeded(recipient, postBalance, maxAllowed);
        }
        TransientContext.setWalletCapExpectedBalance(poolId, recipient, postBalance);
    }
}

/// @title WalletCapBlock
/// @notice Group 3 (Token Rules) — Block #8: Enforces maximum wallet holdings / buy size as % of supply (`beforeSwap`, `afterSwap`).
/// @dev Trust Level: Low (never blocks selling; optionally sunsets after N blocks).
abstract contract WalletCapBlock is IHookRigBlock {
    mapping(PoolId poolId => WalletCapLogic.WalletCapState state) internal _walletCapStates;

    function _initWalletCap(PoolId poolId, WalletCapParams calldata params) internal {
        WalletCapLogic.init(_walletCapStates, poolId, params);
    }

    function _resetWalletCapGraduationClock(PoolId poolId) internal {
        WalletCapLogic.WalletCapState storage state = _walletCapStates[poolId];
        if (state.maxWalletBps > 0) {
            state.startBlock = uint32(block.number);
        }
    }

    function _enforceWalletCapAfterBuy(
        PoolId poolId,
        Currency projectCurrency,
        address recipient,
        uint256 netProjectTokensBought
    ) internal {
        WalletCapLogic.enforceAfterBuy(_walletCapStates, poolId, projectCurrency, recipient, netProjectTokensBought);
    }
}
