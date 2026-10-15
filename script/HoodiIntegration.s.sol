// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HookRigOrchestrator} from "../src/HookRigOrchestrator.sol";
import {IHookRigBlock} from "../src/interfaces/IHookRigBlock.sol";
import {IHookRigOrchestrator} from "../src/interfaces/IHookRigOrchestrator.sol";
import {ITokenLaunchpad} from "../src/interfaces/ITokenLaunchpad.sol";
import {HookPermissionMasks} from "../src/libraries/HookPermissionMasks.sol";
import {LaunchpadFactory} from "../src/launchpad/LaunchpadFactory.sol";
import {VirtualXYKLaunch} from "../src/launchpad/curves/VirtualXYKLaunch.sol";
import {SteppedTrancheLaunch} from "../src/launchpad/curves/SteppedTrancheLaunch.sol";
import {NativeTickLaunch} from "../src/launchpad/curves/NativeTickLaunch.sol";

/// @notice Minimal Uniswap v4 swap router implementing IMsgSender for Hoodi integration testing.
contract HoodiSwapRouter is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;
    address private _currentSender;

    struct SwapCallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function msgSender() external view returns (address) {
        return _currentSender;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        uint256 ethBefore = address(this).balance - msg.value;
        _currentSender = msg.sender;
        delta = abi.decode(
            manager.unlock(
                abi.encode(SwapCallbackData({sender: msg.sender, key: key, params: params, hookData: hookData}))
            ),
            (BalanceDelta)
        );
        _currentSender = address(0);
        uint256 refund = address(this).balance > ethBefore ? address(this).balance - ethBefore : 0;
        if (msg.value > 0 && refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "ETH refund failed");
        }
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(manager), "Only PoolManager");
        SwapCallbackData memory cb = abi.decode(rawData, (SwapCallbackData));
        BalanceDelta delta = manager.swap(cb.key, cb.params, cb.hookData);

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

    receive() external payable {}
}

/// @title HoodiIntegrationScript
/// @notice End-to-end deployment and integration verification script for the Ethereum Hoodi testnet (chainId 560048).
/// @dev Usage:
///   Dry-run simulation on live Hoodi RPC:
///     `forge script script/HoodiIntegration.s.sol --rpc-url https://ethereum-hoodi-rpc.publicnode.com -vv`
///   Live on-chain broadcast on Hoodi:
///     `PRIVATE_KEY=0x... forge script script/HoodiIntegration.s.sol --rpc-url https://ethereum-hoodi-rpc.publicnode.com --broadcast -vv`
contract HoodiIntegrationScript is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant ARACHNID_CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant ORCHESTRATOR_HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    PoolManager public poolManager;
    HoodiSwapRouter public swapRouter;
    HookRigOrchestrator public orchestrator;
    LaunchpadFactory public factory;

    function _deployProtocol(address deployer) internal {
        poolManager = new PoolManager(deployer);
        swapRouter = new HoodiSwapRouter(poolManager);
        console2.log("PoolManager deployed at:", address(poolManager));
        console2.log("HoodiSwapRouter deployed at:", address(swapRouter));

        (address minedHookAddr, bytes32 hookSalt) = HookMiner.find(
            ARACHNID_CREATE2_PROXY,
            ORCHESTRATOR_HOOK_FLAGS,
            type(HookRigOrchestrator).creationCode,
            abi.encode(poolManager, deployer)
        );
        orchestrator = new HookRigOrchestrator{salt: hookSalt}(poolManager, deployer);
        require(address(orchestrator) == minedHookAddr, "CREATE2 Hook address mismatch");
        console2.log("HookRigOrchestrator CREATE2 deployed at:", address(orchestrator));

        uint64 currentNonce = vm.getNonce(deployer);
        address predictedFactory = vm.computeCreateAddress(deployer, currentNonce + 3);

        VirtualXYKLaunch virtualXYKImpl = new VirtualXYKLaunch(poolManager, orchestrator, predictedFactory);
        SteppedTrancheLaunch steppedTrancheImpl = new SteppedTrancheLaunch(poolManager, orchestrator, predictedFactory);
        NativeTickLaunch nativeTickImpl = new NativeTickLaunch(poolManager, orchestrator, predictedFactory);

        factory = new LaunchpadFactory(
            poolManager, orchestrator, address(virtualXYKImpl), address(steppedTrancheImpl), address(nativeTickImpl)
        );
        require(address(factory) == predictedFactory, "LaunchpadFactory nonce prediction mismatch");
        console2.log("LaunchpadFactory deployed at:", address(factory));

        orchestrator.setLaunchpadFactory(address(factory));
        orchestrator.setTrustedRouter(address(swapRouter), true);
    }

    function _buildStackConfig() internal pure returns (IHookRigBlock.PoolStackConfig memory stackCfg) {
        stackCfg.presetId = IHookRigBlock.PresetId.Blank;
        stackCfg.enabledBlocksBitmap = HookPermissionMasks.PRESET_FAIR_LAUNCH | HookPermissionMasks.BIT_KING_OF_THE_POOL
            | HookPermissionMasks.BIT_SWAP_REWARDS;
        stackCfg.dynamicFee =
            IHookRigBlock.DynamicFeeParams({baseFee: 3000, maxFee: 10_000, volatilityTickThreshold: 50});
        stackCfg.antiSnipe = IHookRigBlock.AntiSnipeParams({launchFee: 50_000, normalFee: 3000, decayBlocks: 20});
        stackCfg.walletCap = IHookRigBlock.WalletCapParams({maxWalletBps: 5000, sunsetBlocks: 500});
        stackCfg.autoBurn = IHookRigBlock.AutoBurnParams({burnOnBuyBps: 100, useTokenBurnCall: false});
        stackCfg.lpRewards = IHookRigBlock.LPRewardsParams({extraBuyFeeBps: 100});
        stackCfg.kingOfThePool = IHookRigBlock.KingOfThePoolParams({
            potFeeOnBuyBps: 100, roundDurationSeconds: 3600, minBuyAmountForReset: 0.01 ether
        });
        stackCfg.swapRewards = IHookRigBlock.SwapRewardsParams({pointsPerUnitVolume: 10});
    }

    function run() external {
        uint256 deployerPrivateKey =
            vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(deployerPrivateKey);

        if (deployer.balance < 10 ether) {
            vm.deal(deployer, 100 ether);
        }

        console2.log("=== HookRig Hoodi Integration Suite ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        _deployProtocol(deployer);

        ITokenLaunchpad.LaunchTokenMetadata memory meta = ITokenLaunchpad.LaunchTokenMetadata({
            name: "Hoodi Rig Token",
            symbol: "HRIG",
            totalSupply: 1_000_000_000 ether,
            creator: deployer,
            creatorVestingBps: 500,
            vestingDurationSeconds: 30 days
        });

        ITokenLaunchpad.VirtualXYKConfig memory curveCfg = ITokenLaunchpad.VirtualXYKConfig({
            virtualQuoteReserve: 0.001 ether,
            virtualTokenReserve: 800_000_000 ether,
            graduationQuoteTarget: 0.0005 ether,
            curveTokenAllocation: 750_000_000 ether,
            lpTokenReserve: 200_000_000 ether,
            maxWalletBpsDuringCurve: 5000
        });

        (address tokenAddr, address curveAddr, PoolKey memory poolKey) = factory.launchVirtualXYK(
            meta,
            CurrencyLibrary.ADDRESS_ZERO,
            60,
            IHookRigOrchestrator(address(0)),
            _buildStackConfig(),
            curveCfg,
            bytes32(uint256(1))
        );
        console2.log("Launched HRIG Token at:", tokenAddr);
        console2.log("VirtualXYK Bonding Curve at:", curveAddr);

        VirtualXYKLaunch(payable(curveAddr)).buy{value: 0.0006 ether}(0.0006 ether, 1, deployer);
        require(
            VirtualXYKLaunch(payable(curveAddr)).launchState() == ITokenLaunchpad.LaunchState.Graduated,
            "Curve did not graduate"
        );
        console2.log(
            "Curve graduated into Uniswap v4 Pool! Active Liquidity:",
            IPoolManager(poolManager).getLiquidity(poolKey.toId())
        );

        swapRouter.swap{value: 0.0001 ether}(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -0.0001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        IERC20(tokenAddr).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -1_000_000 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        console2.log(
            "Post-graduation swaps completed! Dead-address auto-burned HRIG:",
            IERC20(tokenAddr).balanceOf(address(0xdead))
        );

        vm.stopBroadcast();
    }
}
