// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookRigBlock} from "./IHookRigBlock.sol";

/// @title ITokenLaunchpad
/// @notice Shared types and interfaces for the HookRig Token Launchpad and its 3 launch curve models.
interface ITokenLaunchpad {
    /// @notice The 3 token launch curve models supported by HookRig.
    enum LaunchCurveType {
        VirtualXYK, // 0: Pump.fun-style virtual constant-product curve -> graduates to v4
        SteppedTranche, // 1: Anti-bundle stepped accumulation curve -> graduates to v4
        NativeTick // 2: Direct Block-0 single-sided concentrated tick curve inside Uniswap v4
    }

    /// @notice Lifecycle state of a launchpad curve.
    enum LaunchState {
        Uninitialized,
        ActiveBonding,
        Graduated
    }

    struct LaunchTokenMetadata {
        string name;
        string symbol;
        uint256 totalSupply;
        address creator;
        uint16 creatorVestingBps; // Optional creator vesting slice (0..1000 = 0..10%)
        uint64 vestingDurationSeconds;
    }

    struct VirtualXYKConfig {
        uint128 virtualQuoteReserve; // X_0
        uint128 virtualTokenReserve; // Y_0
        uint128 graduationQuoteTarget; // X_target in quote currency
        uint128 curveTokenAllocation; // S_curve
        uint128 lpTokenReserve; // S_lp reserved for Uniswap v4 seeding
        uint16 maxWalletBpsDuringCurve; // 0 = no cap, >0 = enforced during bonding
    }

    struct SteppedTrancheConfig {
        uint8 numTranches; // M discrete tranches
        uint128 basePriceQ96; // Starting marginal price in Q96
        uint128 stepPriceIncrementQ96; // Price increment per tranche in Q96
        uint128 graduationQuoteTarget;
        uint128 curveTokenAllocation;
        uint128 lpTokenReserve;
        uint16 maxWalletBps;
        uint16 antiSnipeSurchargeBps;
        uint32 antiSnipeBlocks;
        uint16 surchargeToKingPotBps; // Portion of curve anti-snipe surcharges seeded into Round #1 King pot
    }

    struct NativeTickBand {
        int24 tickLower;
        int24 tickUpper;
        uint128 tokenAmount;
    }

    struct NativeTickConfig {
        uint160 initialSqrtPriceX96;
        int24 tickSpacing;
        NativeTickBand[] bands;
    }

    event TokenLaunched(
        address indexed token,
        address indexed curve,
        LaunchCurveType indexed curveType,
        PoolId poolId,
        IHookRigBlock.PresetId presetId,
        address creator
    );

    event CurveBuy(
        address indexed buyer, uint256 quoteIn, uint256 tokensOut, uint256 surchargeCollected, uint256 totalQuoteRaised
    );

    event CurveSell(address indexed seller, uint256 tokensIn, uint256 quoteOut, uint256 totalQuoteRaised);

    event CurveGraduated(
        PoolId indexed poolId,
        address indexed token,
        uint256 quoteSeeded,
        uint256 tokensSeeded,
        uint160 graduationSqrtPriceX96
    );
}
