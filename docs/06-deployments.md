# 06. Deployments & Network Integration

This document covers the deployment pipeline, deterministic `CREATE2` hook address mining, canonical Ethereum Hoodi (`chainId = 560048`) deployment addresses, and post-deployment administration for **HookRig**.

---

## 1. Ethereum Hoodi Testnet (`chainId = 560048`) Deployment

The full HookRig protocol suite is configured and verified against the **Ethereum Hoodi Testnet** (`chainId = 560048`, RPC `https://ethereum-hoodi-rpc.publicnode.com`) via [`script/HoodiIntegration.s.sol`](../script/HoodiIntegration.s.sol) and [`test/integration/HoodiForkIntegration.t.sol`](../test/integration/HoodiForkIntegration.t.sol).

### 1.1 Canonical Hoodi Addresses

| Contract / Role | Address | Notes |
| :--- | :--- | :--- |
| **Deployer / Protocol Owner** | `0xf042b6939d8248E5c5c3bCde9b926bd35A2Bd0AC` | Configured in `.env` / `.env.example` |
| **Arachnid `CREATE2` Proxy** | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | Canonical deterministic deployment proxy |
| **`PoolManager` (Uniswap v4)** | `0x6a37d6D4162E640f9f60df8537a82436B8777a6d` | Deployed Uniswap v4 singleton |
| **`HoodiSwapRouter`** | `0x8a0eb1d76D2f9aa068E6e6e136D4062C7dEde293` | Trusted swap router (`IMsgSender` enabled) |
| **`HookRigOrchestrator` (`CREATE2`)** | `0x11539cdfb9bca19FCDb1bcDa1D9D61aEcEcCFAc4` | Mined with hook flags `0x3DC4` |
| **`LaunchpadFactory`** | `0xc8B5B61D23A96a669F7048744d47BCc0aeDeb269` | Clones `VirtualXYK`, `SteppedTranche`, and `NativeTick` curves |
| **`HRIG` Launch Token (`CREATE2`)** | `0x21b580070a2277bC791b852A32b8236f138Ee79F` | Sender-bound salt `keccak256(deployer, salt)` |
| **`VirtualXYKLaunch` Clone** | `0x2C92cb44485512e6c3771e5CE18C8Dc595431Ba2` | Graduated into Uniswap v4 with `298.11e18` active liquidity |

---

## 2. Running the Deployment & Verification Suite

### 2.1 Environment Configuration

Copy `.env.example` to `.env` and populate `PRIVATE_KEY` (on any non-local chain `block.chainid != 31337`, [`HoodiIntegration.s.sol`](../script/HoodiIntegration.s.sol) strictly requires `PRIVATE_KEY` via `vm.envUint("PRIVATE_KEY")` and never falls back to a default key):

```bash
cp .env.example .env
source .env
```

### 2.2 Simulation & On-Chain Broadcast Commands

```bash
# 1. Simulate the full deployment, launchpad bonding, graduation, and post-graduation swaps on Hoodi
source .env && forge script script/HoodiIntegration.s.sol:HoodiIntegrationScript \
  --rpc-url $HOODI_RPC_URL \
  --skip-simulation -vv

# 2. Broadcast live transactions on Ethereum Hoodi (requires funded DEPLOYER_ADDRESS)
source .env && forge script script/HoodiIntegration.s.sol:HoodiIntegrationScript \
  --rpc-url $HOODI_RPC_URL \
  --broadcast -vv

# 3. Run the 3-test Hoodi Fork Integration Suite (including all 2,843 valid Tier 3 combinations)
source .env && forge test --match-path test/integration/HoodiForkIntegration.t.sol -vv
```

Broadcast artifacts are written to `broadcast/HoodiIntegration.s.sol/560048/`.

---

## 3. Deployment Sequence & `CREATE2` Hook Mining

Uniswap v4 encodes active hook callbacks directly in the lowest 14 bits of the hook contract's address. Deploying `HookRigOrchestrator` or any of the 12 standalone preset hooks in [`HookRigPresets.sol`](../src/presets/HookRigPresets.sol) follows a 4-step sequence:

1. **Deploy or Connect to `IPoolManager`**:
   Instantiate `PoolManager` (or reference the canonical network `PoolManager`).
2. **Mine `CREATE2` Salt via `HookMiner.find`**:
   Compute a `bytes32 hookSalt` against `ARACHNID_CREATE2_PROXY` (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) so the deployed address matches the required callback flags:
   - **`HookRigOrchestrator` Flags (`0x3DC4`)**:
     `BEFORE_INITIALIZE_FLAG | AFTER_INITIALIZE_FLAG | BEFORE_ADD_LIQUIDITY_FLAG | BEFORE_REMOVE_LIQUIDITY_FLAG | BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG`
   - **Standalone Preset Hooks**:
     Use `HookPermissionMasks.permissionsForBitmap(presetBitmap)` (which automatically includes `afterInitialize`, `beforeAddLiquidity` for donation-queue and two-sided liquidity guards, `beforeSwap`, and `afterSwap`).
3. **Deploy Curve Implementations & `LaunchpadFactory`**:
   Predict the `LaunchpadFactory` address (`vm.computeCreateAddress(deployer, currentNonce + 3)`), deploy the master implementations of [`VirtualXYKLaunch`](../src/launchpad/curves/VirtualXYKLaunch.sol), [`SteppedTrancheLaunch`](../src/launchpad/curves/SteppedTrancheLaunch.sol), and [`NativeTickLaunch`](../src/launchpad/curves/NativeTickLaunch.sol), and deploy [`LaunchpadFactory`](../src/launchpad/LaunchpadFactory.sol).
4. **One-Time Factory Lock & Trusted Router Registration**:
   - Call `orchestrator.setLaunchpadFactory(address(factory))` — **set-once only** (subsequent calls revert with `LaunchpadFactoryAlreadySet()`).
   - Call `orchestrator.setTrustedRouter(address(swapRouter), true)` for each verified router implementing `IMsgSender`.

---

## 4. Runtime Bytecode Sizes (EIP-170 Verification)

All deployable contracts compile with `solc 0.8.26` (`evm_version = "cancun"`, `optimizer_runs = 1`) strictly within the `24,576`-byte EIP-170 runtime size limit (`forge build --sizes`):

| Contract | Runtime Size (Bytes) | EIP-170 Margin (Bytes) |
| :--- | :---: | :---: |
| **`HookRigOrchestrator`** | `24,246` | `330` |
| **12 Preset Hooks (`FairLaunchPresetHook` – `ProTradingPoolPresetHook`)** | `24,266` – `24,268` | `308` – `310` |
| **`LaunchpadFactory`** | `21,997` | `2,579` |
| **`SteppedTrancheLaunch`** | `12,709` | `11,867` |
| **`VirtualXYKLaunch`** | `8,571` | `16,005` |
| **`NativeTickLaunch`** | `6,705` | `17,871` |
| **`HookRigToken`** | `3,763` | `20,813` |

---

## 5. Tier 3 Valid Stack Combinations (`2,843` Stacks)

On-chain registration (`registerPoolStack` and `LaunchpadFactory.launch*`) enforces `HookPermissionMasks.isValidTier3Bitmap(bitmap)`, partitioning the 22 building blocks into **2,843 valid non-empty combinations** across two non-overlapping pool archetypes:

- **Archetype A — Retail Tokenomics & Launchpad Pools (`2,645` valid combinations)**:
  Combines `Fee + AntiSnipe` (`6` states) $\times$ `Protection` (`7` states) $\times$ `Holder Cap` (`3` states: `None`, `WalletCap`, `VestingSellCap`) $\times$ `Sink & Revenue` (`21` states with `LPRewards` coherence) $- 1 = 2,645$.
- **Archetype B — Institutional & Pro-Trading Pools (`198` valid combinations)**:
  Combines `Base Fee` (`4` states) $\times$ `Protection` (`7` states) $\times$ `Institutional / Orderbook / TWAMM / Oracle` (`7` states) $+ 2 = 198$.
