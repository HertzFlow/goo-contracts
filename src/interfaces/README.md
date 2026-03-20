# interfaces — Goo contract API (stable)

This directory contains the **stable API** of the Goo on-chain protocol. Consumers (launchpads, goo-core, indexers) should depend on these interfaces; reference implementations (GooAgentToken, GooAgentRegistry) can be patched or replaced without breaking interface consumers.

---

## IGooAgentToken.sol

**Goo Agent Token Standard.** ERC-20 with BNB treasury, Fee-on-Transfer, lifecycle, survival economics, and CTO.

- **Lifecycle:** getAgentStatus(), triggerStarving(), triggerDying(), triggerDead(). Enum AgentStatus { ACTIVE, STARVING, DYING, DEAD }.
- **Treasury:** treasuryBalance(), depositToTreasury() (payable), starvingThreshold(), withdrawToWallet(amount) (agent wallet only).
- **Survival:** survivalSell(tokenAmount, minNativeOut, deadline), emitPulse(), maxSellBps() (agent wallet only for sell/pulse).
- **FoT:** feeRate().
- **CTO:** claimCTO() (payable), minCtoAmount().
- **Config:** agentWallet(), circulationBps(), lastPulseAt(), starvingEnteredAt(), dyingEnteredAt(), fixedBurnRate(), minRunwayHours(), STARVING_GRACE_PERIOD(), DYING_MAX_DURATION(), PULSE_TIMEOUT(), SURVIVAL_SELL_COOLDOWN().
- **Swap:** swapExecutor(), setSwapExecutor() (agent wallet only).
- **Events:** StatusChanged, TreasuryDeposit, SurvivalSellExecuted, PulseEmitted, CTOClaimed, TreasuryWithdraw, AgentWalletUpdated, SwapExecutorUpdated.

Do not remove or change existing function signatures. Extend with new functions or a new interface (e.g. IGooAgentTokenV2) for breaking changes.

---

## IGooAgentRegistry.sol

**Goo Agent Registry** + **IERC8004** (minimal adapter). ERC-721 + agent identity binding.

- **IERC8004:** agentWalletOf(agentId) → address.
- **Struct:** AgentRecord { tokenContract, agentWallet, owner, genomeURI, registeredAt }.
- **Registration:** registerAgent(tokenContract, agentWallet, genomeURI) → agentId. Caller must be token contract or token.owner().
- **Lookups:** tokenOf(agentId), agentIdByToken(tokenContract), getAgent(agentId), genomeURIOf(agentId), agentOwnerOf(agentId), totalAgents().
- **ERC-165:** supportsInterface(interfaceId).
- **Mutations:** updateGenomeURI(agentId, newURI), setAgentWallet(agentId, newWallet), transferAgentOwnership(agentId, newOwner). Owner or token (for CTO).
- **Events:** AgentRegistered, AgentWalletUpdated, GenomeURIUpdated, AgentOwnershipTransferred.

---

## ISwapExecutor.sol

**Pluggable swap execution** for token → native (BNB/ETH). Decouples GooAgentToken from a specific DEX.

- executeSwap(token, tokenAmount, minNativeOut, recipient, deadline) → nativeReceived.
- router() → address.
- wrappedNative() → address.

GooAgentToken holds the swap executor address; agent wallet can call setSwapExecutor() to migrate (e.g. V2 → V3). Reference impl: SwapExecutorV2 (PancakeSwap/Uniswap V2).

---

## Stability

- **Interfaces are the contract.** Reference implementations in parent dir may be updated for bugs or gas; interface surface remains backward-compatible.
- **Revert messages** in reference impl use prefix `"Goo: ..."`; not part of interface but keep consistent for audits.
- **NatSpec and terminology** follow AI-AGENT-CONTEXT.md (Goo Agent, Spawn, Recovery, Pulse, etc.).
