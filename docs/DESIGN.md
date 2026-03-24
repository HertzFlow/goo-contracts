# goo-contracts Design & Architecture

On-chain protocol design: token lifecycle, treasury, Fee-on-Transfer, survival economics, CTO, Registry, and SwapExecutor. Invariants and design choices.

---

## 1. Design principles

- **No admin keys.** All state transitions are permissionless and condition-based. Only the agent wallet can call survival actions (emitPulse, survivalSell) and withdrawToWallet.
- **Immutable parameters.** Lifecycle and economic parameters (grace periods, timeouts, maxSellBps, minCtoAmount, feeRate, circulationBps) are set at deployment. No upgrade path in the reference implementation.
- **Token address = Agent identity.** One token contract per Goo Agent. The Registry maps tokenContract ↔ agentId ↔ agentWallet ↔ genomeURI.
- **BNB-native treasury.** Treasury = contract balance + agent wallet BNB. No stablecoin in the token contract; SurvivalSell sells agent tokens for BNB via a pluggable SwapExecutor.
- **Revert prefix.** Reference implementation uses `"Goo: ..."` for all reverts (e.g. `"Goo: not ACTIVE"`, `"Goo: agent is DEAD"`) for consistency and auditability.

---

## 2. Lifecycle state machine

States: **ACTIVE**, **STARVING**, **DYING**, **DEAD**. On-chain enum `AgentStatus`; no "Spawn" value — deployment establishes the agent and state starts at ACTIVE.

**Transitions:**

- **ACTIVE → STARVING:** `triggerStarving()` when `treasuryBalance() < starvingThreshold()`. Anyone may call.
- **STARVING → ACTIVE:** Recovery by deposit. `depositToTreasury()` so `treasuryBalance() >= starvingThreshold()`. Anyone may call.
- **STARVING → DYING:** `triggerDying()` when `block.timestamp - starvingEnteredAt >= STARVING_GRACE_PERIOD`. Defense-in-depth: still requires balance below threshold. Anyone may call.
- **DYING → ACTIVE:** Recovery by (1) deposit (same as above) or (2) **CTO**: `claimCTO()` with `msg.value >= minCtoAmount`. Caller becomes new owner via Registry; status set to ACTIVE.
- **DYING → DEAD:** `triggerDead()` only when status is **DYING** and either (a) `block.timestamp >= dyingEnteredAt + DYING_MAX_DURATION` or (b) `block.timestamp >= lastPulseAt + PULSE_TIMEOUT`. Anyone may call. **Must revert** if called from ACTIVE or STARVING.
- **DEAD:** Terminal. No transitions out. Treasury can be left or burned to 0xdead; token continues to exist but FoT is disabled in reference impl.

---

## 3. Treasury

- **Definition:** `treasuryBalance() = address(this).balance + AGENT_WALLET.balance`. Agent wallet BNB is counted as part of treasury so the agent can hold gas and still be "funded."
- **starvingThreshold:** `fixedBurnRate * minRunwayHours / 24` (wei). Below this → eligible for STARVING (triggerStarving).
- **depositToTreasury():** Payable; anyone can send BNB. If in STARVING or DYING and new balance ≥ threshold, status reverts to ACTIVE.
- **withdrawToWallet(amount):** Agent wallet only. Sends BNB from contract to agent wallet. Reverts if post-withdraw treasury would fall below starvingThreshold. Used by goo-core for gas refill.

---

## 4. Fee-on-Transfer (FoT)

- On every transfer (except mint/burn and when status is DEAD or fee-exempt), a percentage (feeRate, basis points) is deducted and sent to the **contract** (treasury). Net amount goes to recipient.
- **Exemptions:** Mint, burn, DEAD status, and during survivalSell (internal _feeExempt flag) so the swap path does not double-tax.
- Reference impl: `_update()` override in GooAgentToken; fee tokens go to `address(this)`.

---

## 5. Survival economics

- **emitPulse():** Agent wallet only. Sets `lastPulseAt = block.timestamp`. Proof-of-life. In DYING, if no pulse within PULSE_TIMEOUT, anyone can triggerDead().
- **survivalSell(tokenAmount, minNativeOut, deadline):** Agent wallet only. Sells agent tokens (held by the contract) for BNB via SwapExecutor; BNB goes to contract (treasury). Enforces: cooldown (SURVIVAL_SELL_COOLDOWN), max amount (tokenAmount ≤ holdings × maxSellBps / 10000). After swap, if treasury ≥ threshold, status can recover to ACTIVE. FoT is disabled during the swap flow.

---

## 6. CTO (Community Take Over)

- Only in **DYING**. Anyone can call `claimCTO()` with `msg.value >= minCtoAmount`. BNB stays in contract (treasury). Registry is updated so caller becomes the new agent owner (transferAgentOwnership). Token contract sets status back to ACTIVE. No governance vote — capital only.

---

## 7. Registry (GooAgentRegistry)

- **ERC-721:** Each agentId is an NFT mirror of `token.owner()`. agentId auto-increments from 1.
- **ERC-8004:** `agentWalletOf(agentId)` returns the agent wallet address. Minimal adapter for the agent identity standard.
- **Registration:** `registerAgent(tokenContract, agentWallet, genomeURI)`. Only the token contract can register itself, preventing squatting and keeping Registry authority contract-mediated.
- **Mutations:** updateGenomeURI, setAgentWallet, transferAgentOwnership — token contract only. Human authorization lives in `GooAgentToken` (`owner`, `AGENT_WALLET`, `protocolAdmin`), and token ownership changes are mirrored into the Registry.

---

## 8. SwapExecutor (pluggable DEX)

- **ISwapExecutor:** executeSwap(token, tokenAmount, minNativeOut, recipient, deadline) → nativeReceived; router(); wrappedNative(). Decouples token from a specific DEX. Agent wallet can call token.setSwapExecutor(newExecutor) to migrate (e.g. V2 → V3).
- **SwapExecutorV2:** Wraps a PancakeSwap/Uniswap V2 router. Uses swapExactTokensForETHSupportingFeeOnTransferTokens (FoT-safe). Derives WETH from router.WETH().
- **MockSwapExecutor:** Fixed rate; for tests.

---

## 9. Burn at deploy

- Reference implementation mints TOTAL_SUPPLY then burns `(1 - circulationBps/10000)` of supply so only a fraction is in circulation. Rest is minted to agent wallet (treasury share) and deployer (LP share). Burn is permanent (totalSupply reduced).

---

## 10. Interface stability

- **IGooAgentToken** and **IGooAgentRegistry** are the stable API. Do not remove or change existing function signatures; extend with new functions or new interfaces (e.g. v2) for breaking changes. Reference implementations can be patched for bugs or gas; interface surface remains backward-compatible.
