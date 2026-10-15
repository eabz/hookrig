// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookPermissionMasks} from "../libraries/HookPermissionMasks.sol";
import {HookRigOrchestrator} from "../HookRigOrchestrator.sol";

/// @title FairLaunchPresetHook
/// @notice Preset #1: Dynamic fee + Anti-snipe + Wallet cap + Auto burn + LP rewards
contract FairLaunchPresetHook is HookRigOrchestrator {
    constructor(IPoolManager _poolManager, address _owner) HookRigOrchestrator(_poolManager, _owner) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return HookPermissionMasks.permissionsForBitmap(HookPermissionMasks.PRESET_FAIR_LAUNCH);
    }
}

/// @title KingOfThePoolLaunchPresetHook
/// @notice Preset #2: Dynamic fee + Anti-snipe + Arb recapture + LP rewards + King of the Pool
contract KingOfThePoolLaunchPresetHook is HookRigOrchestrator {
    constructor(IPoolManager _poolManager, address _owner) HookRigOrchestrator(_poolManager, _owner) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return HookPermissionMasks.permissionsForBitmap(HookPermissionMasks.PRESET_KING_OF_THE_POOL_LAUNCH);
    }
}

/// @title WeeklyKingBuyRewardsPresetHook
/// @notice Preset #3: King of the Pool launch + Swap rewards (168-hour round)
contract WeeklyKingBuyRewardsPresetHook is HookRigOrchestrator {
    constructor(IPoolManager _poolManager, address _owner) HookRigOrchestrator(_poolManager, _owner) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return HookPermissionMasks.permissionsForBitmap(HookPermissionMasks.PRESET_WEEKLY_KING_BUY_REWARDS);
    }
}

/// @title CreatorEconomyPresetHook
/// @notice Preset #4: Dynamic fee + Anti-snipe + Buy and sell tax + Fee sharing + LP rewards
contract CreatorEconomyPresetHook is HookRigOrchestrator {
    constructor(IPoolManager _poolManager, address _owner) HookRigOrchestrator(_poolManager, _owner) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return HookPermissionMasks.permissionsForBitmap(HookPermissionMasks.PRESET_CREATOR_ECONOMY);
    }
}

/// @title CharityTokenPresetHook
/// @notice Preset #5: Dynamic fee + Anti-snipe + Fee sharing + LP rewards + Auto burn
contract CharityTokenPresetHook is HookRigOrchestrator {
    constructor(IPoolManager _poolManager, address _owner) HookRigOrchestrator(_poolManager, _owner) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return HookPermissionMasks.permissionsForBitmap(HookPermissionMasks.PRESET_CHARITY_TOKEN);
    }
}

/// @title TreasuryBackedPresetHook
/// @notice Preset #6: Dynamic fee + Anti-snipe + Arb recapture + Buy and sell tax (sell only) + LP rewards + Auto burn
contract TreasuryBackedPresetHook is HookRigOrchestrator {
    constructor(IPoolManager _poolManager, address _owner) HookRigOrchestrator(_poolManager, _owner) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return HookPermissionMasks.permissionsForBitmap(HookPermissionMasks.PRESET_TREASURY_BACKED);
    }
}

/// @title StockQuotedPresetHook
/// @notice Preset #7: Market-hours fee + Anti-snipe + Arb recapture + LP rewards + Auto burn
contract StockQuotedPresetHook is HookRigOrchestrator {
    constructor(IPoolManager _poolManager, address _owner) HookRigOrchestrator(_poolManager, _owner) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return HookPermissionMasks.permissionsForBitmap(HookPermissionMasks.PRESET_STOCK_QUOTED);
    }
}

/// @title DeepLiquidityPresetHook
/// @notice Preset #8: Dynamic fee + Arb recapture + LP rewards
contract DeepLiquidityPresetHook is HookRigOrchestrator {
    constructor(IPoolManager _poolManager, address _owner) HookRigOrchestrator(_poolManager, _owner) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return HookPermissionMasks.permissionsForBitmap(HookPermissionMasks.PRESET_DEEP_LIQUIDITY);
    }
}

/// @title TraderFirstPresetHook
/// @notice Preset #9: Dynamic fee + Anti-snipe + Arb recapture
contract TraderFirstPresetHook is HookRigOrchestrator {
    constructor(IPoolManager _poolManager, address _owner) HookRigOrchestrator(_poolManager, _owner) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return HookPermissionMasks.permissionsForBitmap(HookPermissionMasks.PRESET_TRADER_FIRST);
    }
}

/// @title StablePairProjectFeePresetHook
/// @notice Preset #10: Arb recapture + Buy and sell tax (1.875% each way) + LP rewards
contract StablePairProjectFeePresetHook is HookRigOrchestrator {
    constructor(IPoolManager _poolManager, address _owner) HookRigOrchestrator(_poolManager, _owner) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return HookPermissionMasks.permissionsForBitmap(HookPermissionMasks.PRESET_STABLE_PAIR_PROJECT_FEE);
    }
}

/// @title PrivatePoolPresetHook
/// @notice Preset #11: Access control + MEV protection + Oracle
contract PrivatePoolPresetHook is HookRigOrchestrator {
    constructor(IPoolManager _poolManager, address _owner) HookRigOrchestrator(_poolManager, _owner) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return HookPermissionMasks.permissionsForBitmap(HookPermissionMasks.PRESET_PRIVATE_POOL);
    }
}

/// @title ProTradingPoolPresetHook
/// @notice Preset #12: Dynamic fee + Limit orders + TWAMM + Oracle
contract ProTradingPoolPresetHook is HookRigOrchestrator {
    constructor(IPoolManager _poolManager, address _owner) HookRigOrchestrator(_poolManager, _owner) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return HookPermissionMasks.permissionsForBitmap(HookPermissionMasks.PRESET_PRO_TRADING_POOL);
    }
}
