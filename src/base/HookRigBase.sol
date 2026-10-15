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
import {AccessControlLogic} from "../blocks/protection/AccessControlBlock.sol";

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
        Currency projectCurrency;
    }

    address public launchpadFactory;
    mapping(address router => bool trusted) public isTrustedRouter;
    mapping(PoolId poolId => PoolRuntimeMeta meta) internal _poolMeta;

    /// @notice Publicly announced 5 bps (0.05%) protocol royalty on return-delta swaps.
    uint16 public constant override PROTOCOL_ROYALTY_BPS = 5;

    /// @notice Publicly exposed static protocol royalty recipient address defined at build time (no admin key).
    address public constant override PROTOCOL_ROYALTY_RECIPIENT = 0x576e9C47665887298EB39eeaa070Dfc1fF6B960A;

    /// @notice Strictly isolated per-PoolId ERC-6909 claim ledger: poolId => currency => beneficiary => amount
    mapping(PoolId poolId => mapping(Currency currency => mapping(address beneficiary => uint256 amount))) public
        poolClaims;

    error OnlyLaunchpadFactory(address caller);
    error OnlyAuthorizedCurve(address caller);
    error OnlyPoolAdmin(address caller);

    constructor(IPoolManager _poolManager, address _initialOwner) BaseHook(_poolManager) Ownable(_initialOwner) {}

    receive() external payable {}

    function setLaunchpadFactory(address _factory) external onlyOwner {
        launchpadFactory = _factory;
    }

    function setTrustedRouter(address router, bool trusted) external onlyOwner {
        isTrustedRouter[router] = trusted;
        emit TrustedRouterUpdated(router, trusted);
    }

    /// @notice Resolves the true end-user initiator address safely (preventing untrusted router hookData spoofing).
    function _resolveUser(address routerSender, bytes calldata hookData) internal view returns (address user) {
        return AccessControlLogic.resolveUser(isTrustedRouter, routerSender, hookData);
    }

    /// @notice Pull-based claim withdrawal so blacklisted or reverting tokens never brick swaps.
    ///         Passing `amount == 0` withdraws the caller's full available balance.
    function withdrawClaim(PoolId poolId, Currency currency, uint256 amount, address to)
        external
        override
        nonReentrant
    {
        uint256 withdrawAmount = AccessControlLogic.validateWithdrawClaim(poolClaims, poolId, currency, amount);
        _payoutERC6909Claim(currency, to == address(0) ? msg.sender : to, withdrawAmount);
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
