// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IGooAgentToken — Goo Agent Token Standard Interface (v3.1)
/// @notice ERC-20 token with integrated BNB Treasury, Fee-on-Transfer,
///         lifecycle state machine, survival economics, burn-at-deploy,
///         owner role (admin), and emergency pause.
///
/// @dev States: Spawn (deploy) → Active → Starving → Dying → Dead.
///   Recovery is not a state: return to Active via deposit (e.g. Deployer) or triggerRecovery.
///   Permissionless state transitions; survivalSell/emitPulse onlyAgentWallet.
///   Token address = Agent identity (Registry). DEAD is irreversible.
///   Treasury is BNB-native — no stablecoin dependency.
///
///   Roles:
///     PROTOCOL_ADMIN = dynamic, from REGISTRY.publisher() (pause, unpause, setSwapExecutor)
///     owner          = admin/economic (FoT income, setAgentWallet, registry mgmt)
///     AGENT_WALLET   = operational (survivalSell, emitPulse, withdrawToWallet, registerInRegistry)
interface IGooAgentToken {
    // ─── Enums ────────────────────────────────────────────────────────────

    /// @notice Agent lifecycle states
    enum AgentStatus {
        ACTIVE, // Normal operation, treasury funded
        STARVING, // Treasury below threshold
        DYING, // Grace period expired; survival window open
        DEAD // Terminal, irreversible
    }

    // ─── Lifecycle State Machine ──────────────────────────────────────────
    //
    // Spawn → Active → Starving → Dying → Dead. Recovery = deposit or triggerRecovery → Active.
    //
    // Canonical state transition table:
    //
    //   ACTIVE    → STARVING : treasuryBalance < STARVING_THRESHOLD (0.015 BNB)
    //   STARVING  → ACTIVE   : treasuryBalance ≥ STARVING_THRESHOLD (Recovery: deposit, triggerRecovery)
    //   STARVING  → DYING    : grace period elapsed (time-only, no balance check)
    //   DYING     → ACTIVE   : treasuryBalance ≥ STARVING_THRESHOLD (Recovery: deposit, triggerRecovery)
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
    ///   - treasuryBalance < STARVING_THRESHOLD
    function triggerStarving() external;

    /// @notice Trigger transition to Dying (grace period expired, time-only).
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

    /// @notice Permissionless recovery: if treasury balance is healthy, revert to ACTIVE.
    /// @dev Succeeds only if:
    ///   - Current status is STARVING or DYING
    ///   - treasuryBalance >= STARVING_THRESHOLD
    function triggerRecovery() external;

    /// @notice Unified lifecycle trigger — evaluates and executes the highest-priority transition.
    /// @dev Permissionless. Single call replaces manual triggerStarving/Dying/Dead/Recovery.
    ///   Priority: 1=recovery, 2=starving, 3=dying, 4=dead, 0=no-op.
    /// @return action The transition performed (0=none, 1=recovery, 2=starving, 3=dying, 4=dead)
    function triggerLifecycle() external returns (uint8 action);

    // ─── Treasury ─────────────────────────────────────────────────────────

    /// @notice Returns the current BNB balance in the treasury.
    /// @return Treasury balance in wei
    function treasuryBalance() external view returns (uint256);

    /// @notice Deposit BNB into the agent's treasury.
    /// @dev Permissionless — anyone can call (donate to keep agent alive).
    ///      If agent is in STARVING/DYING and deposit brings balance ≥ STARVING_THRESHOLD,
    ///      Recovery: status reverts to ACTIVE (anyone can fund, e.g. Deployer).
    function depositToTreasury() external payable;

    /// @notice Returns the Starving threshold constant (0.015 BNB).
    /// @return The threshold in wei
    function starvingThreshold() external view returns (uint256);

    /// @notice Deprecated — triggerDying is now time-only. Returns 0 for backward compat.
    /// @return Always 0
    function dyingThreshold() external view returns (uint256);

    // ─── Treasury Withdraw ─────────────────────────────────────────────────

    /// @notice Withdraw BNB from treasury to agent wallet.
    /// @dev Restricted: onlyAgentWallet + whenNotPaused. Reverts if withdrawal would drop
    ///      treasuryBalance below starvingThreshold(). Sends BNB to agent wallet.
    /// @param amount BNB amount to withdraw in wei
    function withdrawToWallet(uint256 amount) external;

    // ─── Survival Economics ───────────────────────────────────────────────

    /// @notice Agent sells its own tokens for BNB to fund treasury.
    /// @dev Restricted: onlyAgentWallet + whenNotPaused.
    ///   - Subject to SURVIVAL_SELL_COOLDOWN between calls
    ///   - Subject to maxSellBps per-call cap (enforced on-chain)
    ///   - Sells through configured DEX router
    ///   - Proceeds deposited directly to treasury
    /// @param tokenAmount Amount of agent tokens to sell (capped by maxSellBps)
    /// @param minNativeOut Minimum BNB output (slippage protection)
    function survivalSell(uint256 tokenAmount, uint256 minNativeOut, uint256 deadline) external;

    /// @notice Emit Pulse (proof-of-life signal) from the agent.
    /// @dev Restricted: onlyAgentWallet + whenNotPaused.
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

    // ─── Owner Role ────────────────────────────────────────────────────────

    /// @notice Returns the current owner address.
    function owner() external view returns (address);

    /// @notice Transfer ownership to a new address.
    /// @dev Restricted: onlyOwner.
    function transferOwnership(address newOwner) external;

    /// @notice Update the agent wallet address.
    /// @dev Restricted: onlyOwner.
    function setAgentWallet(address newWallet) external;

    // ─── Pausable ──────────────────────────────────────────────────────────

    /// @notice Pause critical operations.
    /// @dev Restricted: onlyProtocolAdmin (dynamic, from REGISTRY.publisher()).
    function pause() external;

    /// @notice Unpause operations.
    /// @dev Restricted: onlyProtocolAdmin.
    function unpause() external;

    // NOTE: paused() is inherited from Pausable, not declared in this interface.

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

    /// @notice Starving → Dying grace period in seconds.
    /// @dev Immutable. Reference default: 86400 (24 hours).
    function STARVING_GRACE_PERIOD() external view returns (uint256);

    /// @notice Maximum duration in Dying before forced death, in seconds.
    /// @dev Immutable. Reference default: 259200 (3 days).
    function DYING_MAX_DURATION() external view returns (uint256);

    /// @notice Pulse timeout in seconds. No Pulse in Dying within this → DEAD eligible.
    /// @dev Immutable. Reference default: 172800 (48 hours).
    function PULSE_TIMEOUT() external view returns (uint256);

    /// @notice Minimum interval between survivalSell calls, in seconds.
    /// @dev Immutable. Reference default: 3600 (1 hour).
    function SURVIVAL_SELL_COOLDOWN() external view returns (uint256);

    // ─── Swap Executor ──────────────────────────────────────────────────

    /// @notice Returns the current swap executor address.
    /// @dev Mutable — can be updated by protocolAdmin via setSwapExecutor().
    function swapExecutor() external view returns (address);

    /// @notice Update the swap executor (e.g. migrate from V2 to V3).
    /// @dev Restricted: onlyProtocolAdmin.
    /// @param _newExecutor Address of the new ISwapExecutor contract
    function setSwapExecutor(address _newExecutor) external;

    // ─── Events ───────────────────────────────────────────────────────────

    event SwapExecutorUpdated(address indexed oldExecutor, address indexed newExecutor);

    event StatusChanged(AgentStatus indexed oldStatus, AgentStatus indexed newStatus, uint256 timestamp);

    event TreasuryDeposit(address indexed depositor, uint256 amount, uint256 newBalance);

    event SurvivalSellExecuted(uint256 tokensSold, uint256 nativeReceived, uint256 newTreasuryBalance);

    event PulseEmitted(uint256 timestamp);

    event TreasuryWithdraw(address indexed to, uint256 amount, uint256 newBalance);

    event AgentWalletUpdated(address indexed oldWallet, address indexed newWallet);

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
}
