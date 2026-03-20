// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IGooAgentToken — Goo Agent Token Standard Interface (v2.0)
/// @notice ERC-20 token with integrated BNB Treasury, Fee-on-Transfer,
///         lifecycle state machine, survival economics, burn-at-deploy, and CTO.
///
/// @dev States: Spawn (deploy) → Active → Starving → Dying → Dead.
///   Recovery is not a state: return to Active via deposit (e.g. Deployer) or Successor (CTO).
///   Permissionless state transitions; survivalSell/emitPulse onlyAgentWallet.
///   Token address = Agent identity (Registry). DEAD is irreversible.
///   Treasury is BNB-native — no stablecoin dependency.
interface IGooAgentToken {
    // ─── Enums ────────────────────────────────────────────────────────────

    /// @notice Agent lifecycle states
    enum AgentStatus {
        ACTIVE, // Normal operation, treasury funded
        STARVING, // Treasury below threshold
        DYING, // Grace period expired; survival + CTO window open
        DEAD // Terminal, irreversible
    }

    // ─── Lifecycle State Machine ──────────────────────────────────────────
    //
    // Spawn → Active → Starving → Dying → Dead. Recovery = deposit or CTO → Active.
    //
    // Canonical state transition table:
    //
    //   ACTIVE    → STARVING : treasuryBalance < starvingThreshold()
    //   STARVING  → ACTIVE   : treasuryBalance ≥ starvingThreshold() (Recovery: deposit)
    //   STARVING  → DYING    : block.timestamp - starvingEnteredAt ≥ STARVING_GRACE_PERIOD
    //   DYING     → ACTIVE   : treasuryBalance ≥ starvingThreshold() (Recovery: deposit)
    //   DYING     → ACTIVE   : claimCTO() (Recovery: Successor/CTO)
    //   DYING     → DEAD     : block.timestamp - dyingEnteredAt ≥ DYING_MAX_DURATION
    //   DYING     → DEAD     : block.timestamp - lastPulseAt ≥ PULSE_TIMEOUT
    //   DEAD      → (none)   : terminal state, no exit
    //
    // triggerDead() is ONLY valid from DYING. It CANNOT be called from ACTIVE or STARVING.

    /// @notice Returns the current lifecycle status of the agent.
    /// @return The current AgentStatus
    function getAgentStatus() external view returns (AgentStatus);

    /// @notice Trigger transition to Starving (treasury below threshold).
    /// @dev Permissionless — anyone can call. Succeeds only if:
    ///   - Current status is ACTIVE
    ///   - treasuryBalance < starvingThreshold()
    function triggerStarving() external;

    /// @notice Trigger transition to Dying (grace period expired; CTO window opens).
    /// @dev Permissionless — anyone can call. Succeeds only if:
    ///   - Current status is STARVING
    ///   - block.timestamp - starvingEnteredAt >= STARVING_GRACE_PERIOD
    function triggerDying() external;

    /// @notice Trigger transition to DEAD (extinction eligible).
    /// @dev Permissionless — anyone can call. Succeeds only if:
    ///   - Current status is DYING (NOT from ACTIVE or STARVING), AND one of:
    ///     (a) block.timestamp - dyingEnteredAt >= DYING_MAX_DURATION, OR
    ///     (b) block.timestamp - lastPulseAt >= PULSE_TIMEOUT
    function triggerDead() external;

    // ─── Treasury ─────────────────────────────────────────────────────────

    /// @notice Returns the current BNB balance in the treasury.
    /// @return Treasury balance in wei
    function treasuryBalance() external view returns (uint256);

    /// @notice Deposit BNB into the agent's treasury.
    /// @dev Permissionless — anyone can call (donate to keep agent alive).
    ///      If agent is in STARVING/DYING and deposit brings balance ≥ starvingThreshold(),
    ///      Recovery: status reverts to ACTIVE (anyone can fund, e.g. Deployer).
    function depositToTreasury() external payable;

    /// @notice Returns the computed Starving threshold (treasury below this → Starving).
    /// @dev starvingThreshold = fixedBurnRate * minRunwayHours / 24
    ///      Used by triggerStarving() and by Recovery (deposit restores to Active).
    /// @return The threshold in wei
    function starvingThreshold() external view returns (uint256);

    // ─── Treasury Withdraw ─────────────────────────────────────────────────

    /// @notice Withdraw BNB from treasury to agent wallet.
    /// @dev Restricted: onlyAgentWallet. Reverts if withdrawal would drop
    ///      treasuryBalance below starvingThreshold(). Sends BNB to agent wallet.
    /// @param amount BNB amount to withdraw in wei
    function withdrawToWallet(uint256 amount) external;

    // ─── Survival Economics ───────────────────────────────────────────────

    /// @notice Agent sells its own tokens for BNB to fund treasury.
    /// @dev Restricted: onlyAgentWallet.
    ///   - Subject to SURVIVAL_SELL_COOLDOWN between calls
    ///   - Subject to maxSellBps per-call cap (enforced on-chain)
    ///   - Sells through configured DEX router
    ///   - Proceeds deposited directly to treasury
    /// @param tokenAmount Amount of agent tokens to sell (capped by maxSellBps)
    /// @param minNativeOut Minimum BNB output (slippage protection)
    function survivalSell(uint256 tokenAmount, uint256 minNativeOut, uint256 deadline) external;

    /// @notice Emit Pulse (proof-of-life signal) from the agent.
    /// @dev Restricted: onlyAgentWallet.
    ///      Resets the pulse timer. If not called within PULSE_TIMEOUT
    ///      while in DYING, anyone can trigger DEAD state.
    function emitPulse() external;

    /// @notice Maximum token amount per survivalSell as % of agent's holdings.
    /// @dev Immutable. Set at deployment. Basis points (e.g., 5000 = 50%).
    ///      survivalSell() MUST revert if tokenAmount exceeds this percentage.
    /// @return Basis points cap (1-10000)
    function maxSellBps() external view returns (uint256);

    // ─── Fee-on-Transfer ──────────────────────────────────────────────────

    /// @notice Returns the current FoT rate in basis points.
    /// @return Fee rate (e.g., 500 = 5%)
    function feeRate() external view returns (uint256);

    // ─── CTO (Recovery via Successor) ──────────────────────────────────────

    /// @notice CTO: inject BNB capital to take over agent ownership during DYING (Recovery via Successor).
    /// @dev Permissionless — anyone can call. Succeeds only if:
    ///   - Current status is DYING
    ///   - msg.value >= minCtoAmount
    ///   Atomic execution:
    ///   1. BNB stays in contract (treasury)
    ///   2. Ownership transferred to msg.sender (via Registry)
    ///   3. Status restored to ACTIVE
    function claimCTO() external payable;

    /// @notice Minimum BNB injection required for CTO claim.
    /// @dev Immutable. Set at deployment.
    /// @return Minimum amount in wei
    function minCtoAmount() external view returns (uint256);

    // ─── Configuration (Read-only) ────────────────────────────────────────

    /// @notice Returns the agent wallet address.
    /// @return The wallet address authorized for economic actions
    function agentWallet() external view returns (address);

    /// @notice Returns the circulation basis points (% of supply in circulation).
    /// @dev Immutable. Set at deployment. 1000-10000 (10%-100%).
    /// @return Circulation in basis points
    function circulationBps() external view returns (uint256);

    /// @notice Returns the timestamp of the last Pulse (proof-of-life).
    /// @return Unix timestamp
    function lastPulseAt() external view returns (uint256);

    /// @notice Returns the timestamp when Starving was entered.
    /// @return Unix timestamp (0 if not in Starving or later)
    function starvingEnteredAt() external view returns (uint256);

    /// @notice Returns the timestamp when Dying was entered.
    /// @return Unix timestamp (0 if not in Dying)
    function dyingEnteredAt() external view returns (uint256);

    // ─── Protocol Parameters (all immutable, set at deployment) ──────────

    /// @notice Daily operational cost in BNB (wei). 0 is valid (disables on-chain starving).
    /// @dev Immutable. When 0, starvingThreshold() returns 0 — treasury can never be below threshold.
    function fixedBurnRate() external view returns (uint256);

    /// @notice Minimum runway hours used in starving threshold calculation.
    /// @dev Immutable. starvingThreshold = fixedBurnRate * minRunwayHours / 24
    function minRunwayHours() external view returns (uint256);

    /// @notice Starving → Dying grace period in seconds.
    /// @dev Immutable. Reference default: 86400 (24 hours).
    ///      Recommended bound: >= 3600 (1 hour)
    function STARVING_GRACE_PERIOD() external view returns (uint256);

    /// @notice Maximum duration in Dying before forced death, in seconds.
    /// @dev Immutable. Reference default: 604800 (7 days).
    function DYING_MAX_DURATION() external view returns (uint256);

    /// @notice Pulse timeout in seconds. No Pulse in Dying within this → DEAD eligible.
    /// @dev Immutable. Reference default: 172800 (48 hours).
    ///      Recommended bound: >= STARVING_GRACE_PERIOD
    function PULSE_TIMEOUT() external view returns (uint256);

    /// @notice Minimum interval between survivalSell calls, in seconds.
    /// @dev Immutable. Reference default: 3600 (1 hour).
    function SURVIVAL_SELL_COOLDOWN() external view returns (uint256);

    // ─── Swap Executor ──────────────────────────────────────────────────

    /// @notice Returns the current swap executor address.
    /// @dev Mutable — can be updated by agent wallet via setSwapExecutor().
    function swapExecutor() external view returns (address);

    /// @notice Update the swap executor (e.g. migrate from V2 to V3).
    /// @dev Restricted: onlyAgentWallet.
    /// @param _newExecutor Address of the new ISwapExecutor contract
    function setSwapExecutor(address _newExecutor) external;

    // ─── Events ───────────────────────────────────────────────────────────

    event SwapExecutorUpdated(address indexed oldExecutor, address indexed newExecutor);

    event StatusChanged(AgentStatus indexed oldStatus, AgentStatus indexed newStatus, uint256 timestamp);

    event TreasuryDeposit(address indexed depositor, uint256 amount, uint256 newBalance);

    event SurvivalSellExecuted(uint256 tokensSold, uint256 nativeReceived, uint256 newTreasuryBalance);

    event PulseEmitted(uint256 timestamp);

    event CTOClaimed(address indexed newOwner, uint256 creditAmount, uint256 timestamp);

    event TreasuryWithdraw(address indexed to, uint256 amount, uint256 newBalance);

    event AgentWalletUpdated(address indexed oldWallet, address indexed newWallet);
}
