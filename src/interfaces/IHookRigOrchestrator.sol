// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookRigBlock} from "./IHookRigBlock.sol";

/// @title IHookRigOrchestrator
/// @notice Interface for configuring composable HookRig pool stacks, launchpad authorization, and ERC-6909 claim pulls.
interface IHookRigOrchestrator is IHookRigBlock {
    event PoolStackConfigured(
        PoolId indexed poolId, PresetId indexed presetId, uint32 enabledBlocksBitmap, address indexed admin
    );
    event TrustedRouterUpdated(address indexed router, bool trusted);
    event ClaimCredited(PoolId indexed poolId, Currency indexed currency, address indexed beneficiary, uint256 amount);
    event ClaimWithdrawn(PoolId indexed poolId, Currency indexed currency, address indexed beneficiary, uint256 amount);

    error UnauthorizedPoolInitializer(address caller);
    error PoolAlreadyConfigured(PoolId poolId);
    error InvalidBlockBitmap(uint32 bitmap);
    error AggregateReturnDeltaBpsExceeded(uint256 totalBps, uint256 maxAllowedBps);
    error DynamicFeeFlagRequired();
    error InsufficientClaimBalance(uint256 requested, uint256 available);

    function registerPoolStack(PoolKey calldata key, PoolStackConfig calldata config) external;

    function notifyPoolGraduated(PoolId poolId) external;

    function seedKingPotFromLaunchCurve(PoolId poolId, Currency currency, uint256 amount) external;

    function withdrawClaim(PoolId poolId, Currency currency, uint256 amount, address to) external;

    function getPoolEnabledBlocks(PoolId poolId) external view returns (uint32);

    function isBlockEnabled(PoolId poolId, BlockId blockId) external view returns (bool);
}
