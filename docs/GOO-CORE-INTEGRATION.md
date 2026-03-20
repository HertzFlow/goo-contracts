# goo-contracts ↔ goo-core Integration

How [goo-core](https://github.com/HertzFlow/goo-core) (off-chain runtime) uses goo-contracts: which functions it calls, under which identity, and which ABIs it needs.

---

## 1. Roles

- **goo-contracts:** On-chain protocol. Defines token (IGooAgentToken) and registry (IGooAgentRegistry). Lifecycle, treasury, Pulse, SurvivalSell, CTO, withdrawToWallet.
- **goo-core:** Off-chain process per agent. Holds the **agent wallet** private key. Reads chain state and calls **agent-wallet–only** token functions. Does not call permissionless triggers (triggerStarving, triggerDying, triggerDead) or recovery (depositToTreasury, claimCTO) — it only **reacts** to status.

---

## 2. Read-only usage (any RPC)

goo-core uses a minimal **read** ABI to build its ChainState every heartbeat. All of these are view/pure and can be called without the agent wallet:

| IGooAgentToken function | Purpose |
|-------------------------|---------|
| getAgentStatus() | Current lifecycle (ACTIVE/STARVING/DYING/DEAD) |
| treasuryBalance() | Treasury BNB (contract + agent wallet) |
| starvingThreshold() | Threshold for STARVING |
| fixedBurnRate() | Daily burn (wei) |
| minRunwayHours() | For threshold calculation |
| lastPulseAt() | Last Pulse timestamp |
| starvingEnteredAt() | When entered STARVING |
| dyingEnteredAt() | When entered DYING |
| totalSupply() | Token total supply |
| balanceOf(address) | Token balance (e.g. contract self for SurvivalSell size) |
| agentWallet() | Authorized wallet for survival actions |
| swapExecutor() | For router/WETH lookup (SurvivalSell quote) |
| maxSellBps() / MAX_SELL_BPS_VALUE() | Cap per survivalSell |
| SURVIVAL_SELL_COOLDOWN() | Cooldown between sells |
| PULSE_TIMEOUT() / PULSE_TIMEOUT_SECS() | Max time without Pulse in DYING before triggerDead |
| feeRate() | FoT rate (informational) |

goo-core’s ABIs are in `src/const.ts` (TOKEN_ABI). Names and selectors must match the contract; reference impl uses both camelCase and UPPER for constants (e.g. PULSE_TIMEOUT_SECS in impl, PULSE_TIMEOUT in interface). goo-core may need to read the one the contract actually exposes.

---

## 3. Write calls (agent wallet only)

goo-core **signs** with the agent wallet and sends:

| Function | When | Notes |
|----------|------|-------|
| emitPulse() | Every heartbeat (subject to cooldown, e.g. PULSE_TIMEOUT/3) | Proof-of-life. Required in DYING to avoid triggerDead. |
| survivalSell(uint256 tokenAmount, uint256 minNativeOut, uint256 deadline) | When status is STARVING or DYING and contract holds tokens | Sells agent tokens for BNB; BNB to treasury. goo-core computes tokenAmount ≤ holdings × maxSellBps/10000 and minNativeOut (e.g. from router quote with slippage). **Note:** IGooAgentToken has 3-arg survivalSell; ensure goo-core passes deadline (e.g. block.timestamp + 300). |
| withdrawToWallet(uint256 amount) | When native balance < MIN_GAS_BALANCE and contract supports it | Withdraws BNB from treasury to agent wallet for gas. goo-core detects support via staticCall(0). |

All three require `msg.sender == agentWallet()`. goo-core never calls as any other identity.

---

## 4. What goo-core does not call

| Function | Caller in protocol | goo-core |
|----------|--------------------|----------|
| triggerStarving() | Anyone | Does not call (reacts to state after someone else triggers) |
| triggerDying() | Anyone | Does not call |
| triggerDead() | Anyone | Does not call |
| depositToTreasury() | Anyone | Does not call |
| claimCTO() | Anyone | Does not call |
| registerAgent(), updateGenomeURI(), setAgentWallet(), transferAgentOwnership() | Registry callers / token (CTO) | Does not call in heartbeat loop; launchpad or token handles Registry |

---

## 5. ABI alignment

- **survivalSell:** Interface has `survivalSell(uint256 tokenAmount, uint256 minNativeOut, uint256 deadline)`. If goo-core was written for a 2-arg version, it must be updated to pass deadline (e.g. `Math.min(block.timestamp + 300, type(uint256).max)` or chain-specific deadline).
- **Constant names:** Reference impl uses suffixes like `_SECS` (STARVING_GRACE_PERIOD_SECS, PULSE_TIMEOUT_SECS). Interface may expose PULSE_TIMEOUT(). goo-core should use the selector/name the deployed contract actually has.
- **withdrawToWallet:** Only in token implementations that support it (V2). goo-core detects via staticCall(0) and skips gas refill if unsupported.

---

## 6. Registry

goo-core does **not** call the Registry in its main loop. It only needs the **token contract address** and the **agent wallet** key. Registration and CTO ownership updates are done by the launchpad (registerAgent) or by the token contract (transferAgentOwnership after claimCTO).

---

## 7. Summary

| Action | Who | goo-core role |
|--------|-----|----------------|
| Read state | goo-core | ChainMonitor.readState() using TOKEN_ABI |
| emitPulse | Agent wallet only | goo-core signs and sends |
| survivalSell | Agent wallet only | goo-core signs and sends (with deadline) |
| withdrawToWallet | Agent wallet only (V2) | goo-core signs and sends (gas refill) |
| triggerStarving / triggerDying / triggerDead | Anyone | Not called by goo-core |
| depositToTreasury / claimCTO | Anyone | Not called by goo-core |
| Registry | Launchpad / token (CTO) | goo-core does not use in loop |

This keeps goo-core a pure **economic sidecar**: it observes the chain and performs only the agent-wallet–allowed survival and gas actions defined by goo-contracts.
