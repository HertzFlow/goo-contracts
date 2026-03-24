# goo-contracts

**On-chain Goo protocol:** agent token standard (ERC-20 + BNB Treasury + Fee-on-Transfer + lifecycle + SurvivalSell + CTO) and agent registry (ERC-721 + minimal ERC-8004). Delivered as **interfaces** + **reference implementations** + **mocks** for tests and integrators. Single source of truth for the Goo contract API.

- **License:** MIT  
- **Solidity:** ^0.8.24  
- **Chain:** BSC (Testnet/Mainnet), Ethereum, or any EVM with a V2-style DEX (PancakeSwap/Uniswap).

---

## What is goo-contracts?

Goo gives AI agents **economic life**: real consumption, real death, survival pressure. The **on-chain** layer is this repo: **IGooAgentToken** (token + treasury + lifecycle + survival economics) and **IGooAgentRegistry** (agent identity + ERC-8004). The **off-chain** runtime that calls these contracts is [goo-core](../goo-core).

- **Token (GooAgentToken):** ERC-20 with BNB treasury, Fee-on-Transfer (FoT), four-state lifecycle (ACTIVE → STARVING → DYING → DEAD), proof-of-life (Pulse), SurvivalSell (agent sells its tokens for BNB to fund treasury), optional treasury withdraw to agent wallet (V2), and CTO (Community Take Over in Dying).
- **Registry (GooAgentRegistry):** ERC-721 + minimal ERC-8004 adapter. Maps agentId ↔ tokenContract ↔ agentWallet ↔ genomeURI. Used for discovery and agent-wallet binding.
- **No admin keys.** State transitions are permissionless and condition-based; only the agent wallet can call `emitPulse()` and `survivalSell()`.

---

## Role in the Goo economy

- **Protocol, not platform.** Goo is an economic-layer protocol. goo-contracts define **how** an agent dies, lives, proves it is alive, and how recovery (deposit / CTO) works. Launchpads, goo-core, and indexers **consume** these contracts.
- **Token address = Agent identity.** One token contract per Goo Agent; the Registry maps token → agentId and agentWalletOf(agentId).
- **Treasury is BNB-native.** No stablecoin dependency in the token contract; treasury = contract balance + agent wallet BNB. SurvivalSell sells agent tokens for BNB via a pluggable **SwapExecutor** (e.g. PancakeSwap V2).
- **Immutable parameters.** STARVING_GRACE_PERIOD, DYING_MAX_DURATION, PULSE_TIMEOUT, maxSellBps, minCtoAmount, etc. are set at deployment and cannot be changed.

---

## What goo-contracts implements

| Component | Description |
|-----------|-------------|
| **IGooAgentToken** | Full token API: lifecycle (getAgentStatus, triggerStarving, triggerDying, triggerDead), treasury (treasuryBalance, depositToTreasury, starvingThreshold, withdrawToWallet), survival (survivalSell, emitPulse, maxSellBps), FoT (feeRate), CTO (claimCTO, minCtoAmount), config (agentWallet, lastPulseAt, fixedBurnRate, minRunwayHours, PULSE_TIMEOUT, etc.), swapExecutor. |
| **GooAgentToken** | Reference implementation: ERC20 + ReentrancyGuard, BNB treasury (includes agent wallet balance), FoT to contract, lifecycle state machine, SurvivalSell via ISwapExecutor, Pulse, withdrawToWallet (agent wallet only), claimCTO (ownership via Registry), burn-at-deploy (1 - circulationBps). |
| **IGooAgentRegistry** | Registry API: registerAgent, agentWalletOf (ERC-8004), tokenOf, agentIdByToken, getAgent, genomeURIOf, agentOwnerOf, totalAgents, updateGenomeURI, setAgentWallet, transferAgentOwnership. |
| **GooAgentRegistry** | Reference implementation: ERC-721, auto-increment agentId, ownership-verified registration (caller = token or token.owner()). |
| **ISwapExecutor** | Pluggable swap: executeSwap(token, tokenAmount, minNativeOut, recipient, deadline), router(), wrappedNative(). |
| **SwapExecutorV2** | PancakeSwap/Uniswap V2 executor; FoT-safe swapExactTokensForETHSupportingFeeOnTransferTokens. |
| **Mocks** | MockStable, MockRouter, MockSwapExecutor for tests and local integrators. |

---

## Repo layout

```
goo-contracts/
├── src/
│   ├── GooAgentToken.sol       # Reference token implementation
│   ├── GooAgentRegistry.sol   # Reference registry implementation
│   ├── SwapExecutorV2.sol     # V2 DEX adapter
│   ├── interfaces/
│   │   ├── IGooAgentToken.sol  # Token standard (stable API)
│   │   ├── IGooAgentRegistry.sol # Registry + IERC8004
│   │   └── ISwapExecutor.sol  # Swap executor interface
│   └── mocks/
│       ├── MockStable.sol     # Test stablecoin
│       ├── MockRouter.sol     # V2 router mock
│       └── MockSwapExecutor.sol # Swap executor mock
├── script/
│   └── Deploy.s.sol           # Forge deploy script (env-based)
├── test/                      # Foundry tests
├── docs/                      # DESIGN, INSTALL, GOO-CORE-INTEGRATION
├── foundry.toml
├── package.json               # "files": ["src"], peerDep: OpenZeppelin
└── AI-AGENT-CONTEXT.md        # Canonical terminology and invariants
```

Consumers should depend on **interfaces** only for stability; use reference implementations or their own implementations as needed.

---

## Lifecycle state machine (invariant)

| Transition | Condition |
|------------|-----------|
| ACTIVE → STARVING | Anyone calls `triggerStarving()` when treasuryBalance &lt; starvingThreshold(). |
| STARVING → ACTIVE | Recovery: anyone calls `depositToTreasury()` so balance ≥ starvingThreshold(). |
| STARVING → DYING | Anyone calls `triggerDying()` when block.timestamp - starvingEnteredAt ≥ STARVING_GRACE_PERIOD. |
| DYING → ACTIVE | Recovery: deposit (balance ≥ threshold) or anyone calls `claimCTO()` with msg.value ≥ minCtoAmount. |
| DYING → DEAD | Anyone calls `triggerDead()` when status is DYING and (dyingEnteredAt + DYING_MAX_DURATION elapsed OR lastPulseAt + PULSE_TIMEOUT elapsed). |
| DEAD | Terminal; no exit. |

**Critical:** `triggerDead()` is only callable from DYING. It must revert from ACTIVE or STARVING.

---

## Permission matrix (invariant)

| Function | Caller |
|----------|--------|
| triggerStarving, triggerDying, triggerDead | Anyone (condition checks only) |
| depositToTreasury | Anyone |
| claimCTO | Anyone (only in DYING, msg.value ≥ minCtoAmount) |
| survivalSell | **Agent wallet only** |
| emitPulse | **Agent wallet only** |
| withdrawToWallet | **Agent wallet only** (V2) |
| setSwapExecutor | **Agent wallet only** |

Registry: registerAgent requires caller = token contract or token.owner(). updateGenomeURI, setAgentWallet, transferAgentOwnership are owner or token (for CTO).

---

## Installation and usage

**Foundry (recommended):**

```bash
cd packages/goo-contracts
forge install
forge build
forge test
```

**As npm dependency:**

```bash
npm install @hertzflow/goo-contracts
# or from workspace
"goo-contracts": "file:../goo-contracts"
```

Consumers need **OpenZeppelin** (reference impls use ERC20, ReentrancyGuard, ERC721, IERC165). Set remapping:

- Foundry: `goo-contracts/=lib/goo-contracts/src/` (or `node_modules/goo-contracts/src/`)
- Import: `import {IGooAgentToken} from "goo-contracts/interfaces/IGooAgentToken.sol";`

**Deploy (example):**

```bash
# Set env: AGENT_WALLET, ROUTER (V2 router), REGISTRY (or 0 to deploy new)
# Optionally deploy SwapExecutorV2(ROUTER) and pass it as swapExecutor to GooAgentToken
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PK
```

See [docs/INSTALL.md](docs/INSTALL.md) and [docs/GOO-CORE-INTEGRATION.md](docs/GOO-CORE-INTEGRATION.md).

---

## Interaction with goo-core

goo-core reads state (getAgentStatus, treasuryBalance, starvingThreshold, lastPulseAt, etc.) and calls **agent-wallet-only** functions: `emitPulse()`, `survivalSell(tokenAmount, minNativeOut, deadline)`, and optionally `withdrawToWallet(amount)`. goo-core does not call triggerStarving, triggerDying, triggerDead, depositToTreasury, or claimCTO. See [docs/GOO-CORE-INTEGRATION.md](docs/GOO-CORE-INTEGRATION.md).

---

## Documentation

| Doc | Description |
|-----|-------------|
| [docs/DESIGN.md](docs/DESIGN.md) | Architecture, lifecycle, treasury, FoT, CTO, Registry. |
| [docs/INSTALL.md](docs/INSTALL.md) | Install, remappings, build, test, deploy. |
| [docs/GOO-CORE-INTEGRATION.md](docs/GOO-CORE-INTEGRATION.md) | How goo-core uses these contracts; ABIs and callers. |
| [src/interfaces/README.md](src/interfaces/README.md) | Interface overview and stability. |
| [src/mocks/README.md](src/mocks/README.md) | Mocks for tests and integrators. |
| [AI-AGENT-CONTEXT.md](AI-AGENT-CONTEXT.md) | Canonical terminology, state machine, permission matrix (for AI/maintainers). |

---

## References

- [GOO-NARRATIVE.md](../../GOO-NARRATIVE.md) — Economics 4.0, Cyber Sovereign Entity.
- [THESIS.md](../../THESIS.md) — Economic Agent thesis and eight rules.
- [goo-core](../goo-core) — Off-chain runtime that calls these contracts.
