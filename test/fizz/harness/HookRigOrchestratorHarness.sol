// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {HookRigOrchestrator} from "../../../src/HookRigOrchestrator.sol";
import {HookPermissionMasks} from "../../../src/libraries/HookPermissionMasks.sol";
import {KingOfThePoolLogic} from "../../../src/blocks/rewards/KingOfThePoolBlock.sol";
import {LimitOrdersLogic} from "../../../src/blocks/trading/LimitOrdersBlock.sol";
import {TWAMMLogic} from "../../../src/blocks/trading/TWAMMBlock.sol";
import {AntiSnipeLogic} from "../../../src/blocks/protection/AntiSnipeBlock.sol";

/// @title HookRigOrchestratorHarness
/// @notice Drop-in `HookRigOrchestrator` that only adds view getters over internal block storage for the fuzz suite.
/// @dev No behaviour changes: same constructor, same hook permissions, so the CREATE2-mined address is still valid.
contract HookRigOrchestratorHarness is HookRigOrchestrator {
    using PoolIdLibrary for PoolKey;

    constructor(IPoolManager _poolManager, address _initialOwner) HookRigOrchestrator(_poolManager, _initialOwner) {}

    /// @notice Full King of the Pool round state (`_kingStates`), including `potCurrency`.
    function kingState(PoolId poolId) external view returns (KingOfThePoolLogic.KingRoundState memory) {
        return _kingStates[poolId];
    }

    /// @notice A finalized King round (`_settledKingRounds`).
    function settledKingRound(PoolId poolId, uint64 roundId)
        external
        view
        returns (KingOfThePoolLogic.SettledKingRound memory)
    {
        return _settledKingRounds[poolId][roundId];
    }

    /// @notice Auto-buyback reserve held as hook ERC-6909 for `currency` (`_autoBuybackStates[p].reserveByCurrency`).
    function buybackReserve(PoolId poolId, Currency currency) external view returns (uint256) {
        return _autoBuybackStates[poolId].reserveByCurrency[currency];
    }

    /// @notice Limit-order bucket at `(poolId, tick, zeroForOne)` (`_limitOrderBuckets`).
    function limitOrderBucket(PoolId poolId, int24 tick, bool zeroForOne)
        external
        view
        returns (LimitOrdersLogic.LimitOrderBucket memory)
    {
        return _limitOrderBuckets[poolId][tick][zeroForOne];
    }

    /// @notice Stored limit order (`_limitOrders`).
    function limitOrder(uint256 orderId) external view returns (LimitOrdersLogic.UserLimitOrder memory) {
        return _limitOrders[orderId];
    }

    /// @notice TWAMM streaming checkpoint (`_twammStates`), projected to `block.timestamp`.
    function twammState(PoolId poolId) external view returns (TWAMMLogic.TWAMMState memory) {
        return _previewTWAMMState(poolId);
    }

    /// @notice Anti-snipe configuration and decay clock (`_antiSnipeStates`).
    function antiSnipeState(PoolId poolId) external view returns (AntiSnipeLogic.AntiSnipeState memory) {
        return _antiSnipeStates[poolId];
    }

    /// @notice Anti-snipe fee the pool would charge at the current block.
    function antiSnipeFee(PoolId poolId) external view returns (uint24) {
        return _computeAntiSnipeFee(poolId);
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160)
        internal
        view
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        PoolRuntimeMeta storage meta = _poolMeta[poolId];
        if (meta.isLaunchpadPool && sender != meta.authorizedCurve && sender != launchpadFactory) {
            revert UnauthorizedPoolInitializer(sender);
        }
        if ((meta.enabledBlocksBitmap & HookPermissionMasks.BIT_TWAMM) != 0) {
            _validateTWAMMBeforeInitialize(key.tickSpacing);
        }
        return IHooks.beforeInitialize.selector;
    }

    function _validateBitmapCompatibility(uint32) internal pure override {}

    function _protocolRoyaltyBps() internal pure override returns (uint16) {
        return 0;
    }

    function _swapFilledOrderOnClaim() internal pure override returns (bool) {
        return true;
    }
}
