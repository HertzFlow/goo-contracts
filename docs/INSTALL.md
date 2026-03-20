# goo-contracts Installation & Build

How to install, build, test, and deploy goo-contracts. Remappings for Foundry and npm consumers.

---

## 1. Prerequisites

- **Foundry** (forge, cast) — recommended for build and test  
- **Node.js** 18+ and npm — if consuming as npm package  
- **OpenZeppelin contracts** — reference implementations depend on them (ERC20, ReentrancyGuard, ERC721, IERC165)

---

## 2. Install (Foundry)

```bash
cd packages/goo-contracts
forge install
forge build
```

If this repo is used as a submodule or path dependency:

```bash
# In your project
forge install path/to/goo-contracts --no-commit
# Add remapping in foundry.toml or remappings.txt:
# goo-contracts/=path/to/goo-contracts/src/
```

OpenZeppelin is usually installed as a Forge dependency; ensure `lib/openzeppelin-contracts` exists and remapping `@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/` is set.

---

## 3. Remappings

**Inside this repo (foundry.toml):**

- `@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/`
- Consumers of goo-contracts add: `goo-contracts/=lib/goo-contracts/src/` or `goo-contracts/=node_modules/goo-contracts/src/`

**Import in your Solidity:**

```solidity
import {IGooAgentToken} from "goo-contracts/interfaces/IGooAgentToken.sol";
import {IGooAgentRegistry} from "goo-contracts/interfaces/IGooAgentRegistry.sol";
import {GooAgentToken} from "goo-contracts/GooAgentToken.sol";
```

---

## 4. Test

```bash
forge test
forge test -v
forge test --match-contract GooAgentToken
forge test --match-contract GooAgentRegistry
```

Tests live in `test/`. They use mocks (MockStable, MockRouter, MockSwapExecutor) and may deploy a fresh Registry and Token. No mainnet fork required for unit tests.

---

## 5. Deploy

**GooAgentToken** requires: name, symbol, agentWallet, **swapExecutor** (not raw router), registry, and all immutable lifecycle/economic parameters. **GooAgentRegistry** has no constructor args.

**Typical order:**

1. Deploy **GooAgentRegistry** (if not already deployed).
2. Deploy **SwapExecutorV2(router)** where `router` is your PancakeSwap/Uniswap V2 router address. Use the returned address as `swapExecutor`.
3. Deploy **GooAgentToken** with constructor args including the swapExecutor and registry addresses.

**Forge script (this repo):**

The provided `script/Deploy.s.sol` reads env vars. Ensure **AGENT_WALLET** and **ROUTER** are set. If **REGISTRY** is not set or is zero, the script deploys a new Registry. The script may pass ROUTER directly to the token constructor in some versions; if your token expects a swap executor, deploy SwapExecutorV2(ROUTER) first and pass that address as the executor parameter.

```bash
export AGENT_WALLET=0x...
export ROUTER=0x...   # V2 router
export REGISTRY=0x... # or 0 to deploy new
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PK
```

Optional env (defaults in script): FIXED_BURN_RATE, MIN_RUNWAY_HOURS, STARVING_GRACE_PERIOD, DYING_MAX_DURATION, PULSE_TIMEOUT, SURVIVAL_SELL_COOLDOWN, MAX_SELL_BPS, MIN_CTO_AMOUNT, FEE_RATE_BPS, CIRCULATION_BPS, TOKEN_NAME, TOKEN_SYMBOL, DEPLOY_BNB.

---

## 6. npm package

**Publish:** `package.json` has `"files": ["src"]`. Only `src/` is published. Peer dependency: `@openzeppelin/contracts` (optional in meta, but required for reference impls).

**Consume:**

```bash
npm install @hertzflow/goo-contracts
# or workspace
"goo-contracts": "file:../goo-contracts"
```

In Foundry, point remapping to `node_modules/goo-contracts/src/`. In Hardhat, add to compiler paths or remappings so that `goo-contracts/interfaces/IGooAgentToken.sol` resolves.

---

## 7. Verify on explorer

After deploy, verify the contract source (e.g. BSCScan):

```bash
forge verify-contract <TOKEN_ADDRESS> GooAgentToken --chain-id 97 --constructor-args $(cast abi-encode "constructor(...)" ...)
```

Adjust constructor args encoding to match your deployment. Some chains support flattened source or standard JSON input.
