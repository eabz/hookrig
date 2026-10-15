// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {IMsgSender} from "../../src/interfaces/IMsgSender.sol";
import {IHookRigBlock} from "../../src/interfaces/IHookRigBlock.sol";
import {IHookRigOrchestrator} from "../../src/interfaces/IHookRigOrchestrator.sol";
import {HookRigOrchestrator} from "../../src/HookRigOrchestrator.sol";
import {LaunchpadFactory} from "../../src/launchpad/LaunchpadFactory.sol";
import {VirtualXYKLaunch} from "../../src/launchpad/curves/VirtualXYKLaunch.sol";
import {SteppedTrancheLaunch} from "../../src/launchpad/curves/SteppedTrancheLaunch.sol";
import {NativeTickLaunch} from "../../src/launchpad/curves/NativeTickLaunch.sol";

contract MockBurnableERC20 is ERC20, ERC20Burnable {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Canonical test router implementing `IUnlockCallback` and `IMsgSender` for Uniswap v4 PoolManager interactions.
contract HookRigTestRouter is IUnlockCallback, IMsgSender {
    using CurrencySettler for Currency;

    enum ActionType {
        ModifyLiquidity,
        Swap,
        Donate
    }

    struct CallbackData {
        ActionType action;
        address sender;
        PoolKey key;
        ModifyLiquidityParams modParams;
        SwapParams swapParams;
        uint256 donate0;
        uint256 donate1;
        bytes hookData;
    }

    IPoolManager public immutable manager;
    address private _currentMsgSender;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    receive() external payable {}

    function msgSender() external view override returns (address) {
        return _currentMsgSender;
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        _currentMsgSender = msg.sender;
        CallbackData memory cb;
        cb.action = ActionType.ModifyLiquidity;
        cb.sender = msg.sender;
        cb.key = key;
        cb.modParams = params;
        cb.hookData = hookData;
        delta = abi.decode(manager.unlock(abi.encode(cb)), (BalanceDelta));
        _currentMsgSender = address(0);
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        _currentMsgSender = msg.sender;
        CallbackData memory cb;
        cb.action = ActionType.Swap;
        cb.sender = msg.sender;
        cb.key = key;
        cb.swapParams = params;
        cb.hookData = hookData;
        delta = abi.decode(manager.unlock(abi.encode(cb)), (BalanceDelta));
        _currentMsgSender = address(0);
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        _currentMsgSender = msg.sender;
        CallbackData memory cb;
        cb.action = ActionType.Donate;
        cb.sender = msg.sender;
        cb.key = key;
        cb.donate0 = amount0;
        cb.donate1 = amount1;
        cb.hookData = hookData;
        delta = abi.decode(manager.unlock(abi.encode(cb)), (BalanceDelta));
        _currentMsgSender = address(0);
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(manager), "Only PoolManager");
        CallbackData memory cb = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;

        if (cb.action == ActionType.ModifyLiquidity) {
            (delta,) = manager.modifyLiquidity(cb.key, cb.modParams, cb.hookData);
        } else if (cb.action == ActionType.Swap) {
            delta = manager.swap(cb.key, cb.swapParams, cb.hookData);
        } else if (cb.action == ActionType.Donate) {
            delta = manager.donate(cb.key, cb.donate0, cb.donate1, cb.hookData);
        }

        if (delta.amount0() < 0) {
            cb.key.currency0.settle(manager, cb.sender, uint256(uint128(-delta.amount0())), false);
        } else if (delta.amount0() > 0) {
            cb.key.currency0.take(manager, cb.sender, uint256(uint128(delta.amount0())), false);
        }

        if (delta.amount1() < 0) {
            cb.key.currency1.settle(manager, cb.sender, uint256(uint128(-delta.amount1())), false);
        } else if (delta.amount1() > 0) {
            cb.key.currency1.take(manager, cb.sender, uint256(uint128(delta.amount1())), false);
        }

        return abi.encode(delta);
    }
}

abstract contract HookRigTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    uint160 internal constant ORCHESTRATOR_HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    PoolManager public poolManager;
    HookRigOrchestrator public orchestrator;
    HookRigTestRouter public router;

    VirtualXYKLaunch public virtualXYKImpl;
    SteppedTrancheLaunch public steppedTrancheImpl;
    NativeTickLaunch public nativeTickImpl;
    LaunchpadFactory public launchpadFactory;

    MockBurnableERC20 public token0;
    MockBurnableERC20 public token1;
    Currency public currency0;
    Currency public currency1;

    address public owner = address(0xA11CE);
    address public alice = address(0xB0B01);
    address public bob = address(0xB0B02);
    address public carol = address(0xB0B03);
    address public treasury = address(0xFEE01);
    address public charity = address(0xFEE02);

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        vm.roll(10_000);

        poolManager = new PoolManager(owner);
        router = new HookRigTestRouter(poolManager);

        address hookAddr = address(uint160(0x4444000000000000000000000000000000000000) | ORCHESTRATOR_HOOK_FLAGS);
        deployCodeTo("HookRigOrchestrator.sol:HookRigOrchestrator", abi.encode(poolManager, owner), hookAddr);
        orchestrator = HookRigOrchestrator(hookAddr);

        uint64 nextNonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nextNonce + 3);

        virtualXYKImpl = new VirtualXYKLaunch(poolManager, orchestrator, predictedFactory);
        steppedTrancheImpl = new SteppedTrancheLaunch(poolManager, orchestrator, predictedFactory);
        nativeTickImpl = new NativeTickLaunch(poolManager, orchestrator, predictedFactory);

        launchpadFactory = new LaunchpadFactory(
            poolManager, orchestrator, address(virtualXYKImpl), address(steppedTrancheImpl), address(nativeTickImpl)
        );
        assertEq(address(launchpadFactory), predictedFactory);

        vm.startPrank(owner);
        orchestrator.setLaunchpadFactory(address(launchpadFactory));
        orchestrator.setTrustedRouter(address(router), true);
        vm.stopPrank();

        MockBurnableERC20 tA = new MockBurnableERC20("Quote Token", "QUOTE");
        MockBurnableERC20 tB = new MockBurnableERC20("Project Token", "PROJ");
        if (address(tA) < address(tB)) {
            token0 = tA;
            token1 = tB;
        } else {
            token0 = tB;
            token1 = tA;
        }
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        _fundAndApprove(address(this), 1_000_000_000 ether);
        _fundAndApprove(alice, 100_000_000 ether);
        _fundAndApprove(bob, 100_000_000 ether);
        _fundAndApprove(carol, 100_000_000 ether);
    }

    function _fundAndApprove(address account, uint256 amount) internal {
        vm.deal(account, 10_000 ether);
        token0.mint(account, amount);
        token1.mint(account, amount);
        vm.startPrank(account);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(orchestrator), type(uint256).max);
        token1.approve(address(orchestrator), type(uint256).max);
        vm.stopPrank();
    }

    function _defaultPoolKey(IHooks hook) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0, currency1: currency1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: hook
        });
    }

    function _initPoolWithStack(IHookRigBlock.PoolStackConfig memory cfg)
        internal
        returns (PoolKey memory key, PoolId poolId)
    {
        key = _defaultPoolKey(IHooks(address(orchestrator)));
        poolId = key.toId();
        orchestrator.registerPoolStack(key, cfg);
        poolManager.initialize(key, SQRT_PRICE_1_1);
    }

    function _seedFullRangeLiquidity(PoolKey memory key, int256 liquidityDelta) internal {
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: liquidityDelta, salt: bytes32(0)
            }),
            ""
        );
    }

    function _swapExactIn(address trader, PoolKey memory key, bool zeroForOne, uint256 amountIn, bytes memory hookData)
        internal
        returns (BalanceDelta delta)
    {
        vm.prank(trader);
        delta = router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            hookData
        );
    }

    function _swapExactOut(
        address trader,
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountOut,
        bytes memory hookData
    ) internal returns (BalanceDelta delta) {
        vm.prank(trader);
        delta = router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            hookData
        );
    }

    function _flagsFromPermissions(Hooks.Permissions memory p) internal pure returns (uint160 flags) {
        if (p.beforeInitialize) flags |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (p.afterInitialize) flags |= Hooks.AFTER_INITIALIZE_FLAG;
        if (p.beforeAddLiquidity) flags |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (p.afterAddLiquidity) flags |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (p.beforeRemoveLiquidity) flags |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (p.afterRemoveLiquidity) flags |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (p.beforeSwap) flags |= Hooks.BEFORE_SWAP_FLAG;
        if (p.afterSwap) flags |= Hooks.AFTER_SWAP_FLAG;
        if (p.beforeDonate) flags |= Hooks.BEFORE_DONATE_FLAG;
        if (p.afterDonate) flags |= Hooks.AFTER_DONATE_FLAG;
        if (p.beforeSwapReturnDelta) flags |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterSwapReturnDelta) flags |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterAddLiquidityReturnDelta) flags |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (p.afterRemoveLiquidityReturnDelta) flags |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
    }
}
