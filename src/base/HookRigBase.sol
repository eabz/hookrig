// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IMsgSender} from "../interfaces/IMsgSender.sol";
import {IHookRigOrchestrator} from "../interfaces/IHookRigOrchestrator.sol";

/// @title HookRigBase
/// @notice Base security & isolation contract for HookRig hooks:
///         - Enforces `onlyPoolManager` via OpenZeppelin `BaseHook`
///         - Isolates all ERC-6909 claim balances by `PoolId`
///         - Resolves authenticated trader/LP addresses via Trusted Routers (`IMsgSender`) or `hookData`
///         - Guards launchpad pools against pre-initialization front-running
abstract contract HookRigBase is
    BaseHook,
    Ownable2Step,
    ReentrancyGuardTransient,
    IUnlockCallback,
    IHookRigOrchestrator
{
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;

    struct PoolRuntimeMeta {
        PresetId presetId;
        uint32 enabledBlocksBitmap;
        bool isToken0ProjectToken;
        bool configured;
        bool isLaunchpadPool;
        bool launchpadGraduated;
        address authorizedCurve;
        address poolAdmin;
    }

    address public launchpadFactory;
    mapping(address router => bool trusted) public isTrustedRouter;
    mapping(PoolId poolId => PoolRuntimeMeta meta) internal _poolMeta;

    /// @notice Strictly isolated per-PoolId ERC-6909 claim ledger: poolId => currency => beneficiary => amount
    mapping(PoolId poolId => mapping(Currency currency => mapping(address beneficiary => uint256 amount))) public
        poolClaims;

    error OnlyLaunchpadFactory(address caller);
    error OnlyAuthorizedCurve(address caller);

    constructor(IPoolManager _poolManager, address _initialOwner) BaseHook(_poolManager) Ownable(_initialOwner) {}

    function setLaunchpadFactory(address _factory) external onlyOwner {
        launchpadFactory = _factory;
    }

    function setTrustedRouter(address router, bool trusted) external onlyOwner {
        isTrustedRouter[router] = trusted;
        emit TrustedRouterUpdated(router, trusted);
    }

    /// @notice Resolves the true end-user initiator address safely (preventing the `msg.sender` vs `sender` trap).
    function _resolveUser(address routerSender, bytes calldata hookData) internal view returns (address user) {
        if (isTrustedRouter[routerSender]) {
            try IMsgSender(routerSender).msgSender() returns (address resolved) {
                if (resolved != address(0)) return resolved;
            } catch {}
        }
        if (hookData.length >= 32) {
            user = abi.decode(hookData[:32], (address));
            if (user != address(0)) return user;
        }
        return routerSender;
    }

    /// @notice Credits an ERC-6909 claim inside PoolManager isolated to `poolId` and `beneficiary`.
    function _creditPoolClaim(PoolId poolId, Currency currency, address beneficiary, uint256 amount) internal {
        if (amount == 0 || beneficiary == address(0)) return;
        currency.take(poolManager, address(this), amount, true);
        poolClaims[poolId][currency][beneficiary] += amount;
        emit ClaimCredited(poolId, currency, beneficiary, amount);
    }

    /// @notice Pull-based claim withdrawal so blacklisted or reverting tokens never brick swaps.
    function withdrawClaim(PoolId poolId, Currency currency, uint256 amount, address to)
        external
        override
        nonReentrant
    {
        uint256 available = poolClaims[poolId][currency][msg.sender];
        if (amount == 0 || amount > available) {
            revert InsufficientClaimBalance(amount, available);
        }
        poolClaims[poolId][currency][msg.sender] = available - amount;

        _payoutERC6909Claim(currency, to, amount);

        emit ClaimWithdrawn(poolId, currency, msg.sender, amount);
    }

    /// @notice Unlocks PoolManager to burn ERC-6909 claims held by this hook and transfer underlying currency to `to`.
    function _payoutERC6909Claim(Currency currency, address to, uint256 amount) internal {
        poolManager.unlock(abi.encode(currency, to, amount));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
        return "";
    }

    function getPoolEnabledBlocks(PoolId poolId) external view override returns (uint32) {
        return _poolMeta[poolId].enabledBlocksBitmap;
    }

    function isBlockEnabled(PoolId poolId, BlockId blockId) external view override returns (bool) {
        return (_poolMeta[poolId].enabledBlocksBitmap & uint32(1 << uint8(blockId))) != 0;
    }
}
