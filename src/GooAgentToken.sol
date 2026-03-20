// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGooAgentToken} from "./interfaces/IGooAgentToken.sol";
import {IGooAgentRegistry} from "./interfaces/IGooAgentRegistry.sol";
import {ISwapExecutor} from "./interfaces/ISwapExecutor.sol";

/// @title GooAgentToken — Reference Implementation (v2.0, BNB-native treasury)
/// @notice ERC-20 + BNB Treasury + FoT + Lifecycle State Machine + SurvivalSell + CTO + Burn-at-deploy
/// @dev Spawn → Active → Starving → Dying → Dead. Recovery = deposit or Successor(CTO) → Active.
///   - Permissionless state transitions; triggerDead() only from Dying.
///   - depositToTreasury(): Recovery path — from Starving or Dying back to Active.
///   - claimCTO(): Recovery path — Successor takes over in Dying, status → Active.
///   - All parameters immutable. Treasury = address(this).balance + agentWallet.balance.
///   - treasuryBalance() includes agent wallet's BNB. withdrawToWallet() lets agent spend from treasury.
///   - Constructor burns (1-circulationBps/10000) of supply permanently.
contract GooAgentToken is ERC20, ReentrancyGuard, IGooAgentToken {
    // ─── Constants ──────────────────────────────────────────────────────

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 private constant _BPS_BASE = 10_000;
    uint256 public constant TREASURY_TOKEN_BPS = 500; // 5% of supply to agent wallet
    uint256 public constant TREASURY_BNB_BPS = 3000; // 30% of contribution to agent wallet

    // ─── Immutables (all set at deployment, cannot change) ──────────────

    address public AGENT_WALLET;
    IGooAgentRegistry public immutable REGISTRY;

    uint256 public immutable FIXED_BURN_RATE;
    uint256 public immutable MIN_RUNWAY_HOURS;
    uint256 public immutable STARVING_GRACE_PERIOD_SECS;
    uint256 public immutable DYING_MAX_DURATION_SECS;
    uint256 public immutable PULSE_TIMEOUT_SECS;
    uint256 public immutable SURVIVAL_SELL_COOLDOWN_SECS;
    uint256 public immutable MAX_SELL_BPS_VALUE;
    uint256 public immutable MIN_CTO_AMOUNT;
    uint256 public immutable FEE_RATE_BPS;
    uint256 public immutable CIRCULATION_BPS;
    /// @dev Wrapped native token (WBNB on BSC, WETH on Ethereum).
    ///   PancakeSwap/Uniswap V2 Router exposes this via `WETH()` regardless of chain.
    address public immutable WRAPPED_NATIVE;

    // ─── Mutable State ──────────────────────────────────────────────────

    /// @notice Pluggable swap executor — can be updated to migrate DEX versions.
    address public swapExecutor;

    AgentStatus private _status;
    uint256 private _starvingEnteredAt;
    uint256 private _dyingEnteredAt;
    uint256 private _lastPulseAt;
    uint256 private _lastSurvivalSell;

    /// @dev FoT exemption flag — set during survivalSell to bypass fee
    bool private _feeExempt;

    // ─── Constructor ────────────────────────────────────────────────────

    /// @param _name              Token name
    /// @param _symbol            Token symbol
    /// @param _agentWallet       Agent runtime wallet
    /// @param _swapExecutor      SwapExecutor contract address (pluggable DEX adapter)
    /// @param _registry          GooAgentRegistry address
    /// @param _fixedBurnRate     Daily operational cost (BNB wei)
    /// @param _minRunwayHours    Minimum runway hours for starving threshold
    /// @param _starvingGracePeriod  Starving → Dying grace period (seconds)
    /// @param _dyingMaxDuration     Max Dying duration before death (seconds)
    /// @param _pulseTimeout      Pulse timeout (seconds)
    /// @param _survivalSellCooldown  Min interval between survival sells (seconds)
    /// @param _maxSellBps        Max % of holdings per survivalSell (basis points)
    /// @param _minCtoAmount      Min BNB for CTO claim (wei)
    /// @param _feeRateBps        FoT fee rate (basis points)
    /// @param _circulationBps    % of supply in circulation (1000-10000)
    constructor(
        string memory _name,
        string memory _symbol,
        address _agentWallet,
        address _swapExecutor,
        address _registry,
        uint256 _fixedBurnRate,
        uint256 _minRunwayHours,
        uint256 _starvingGracePeriod,
        uint256 _dyingMaxDuration,
        uint256 _pulseTimeout,
        uint256 _survivalSellCooldown,
        uint256 _maxSellBps,
        uint256 _minCtoAmount,
        uint256 _feeRateBps,
        uint256 _circulationBps
    ) payable ERC20(_name, _symbol) {
        // Validate critical addresses
        require(_agentWallet != address(0), "Goo: zero agentWallet");
        require(_swapExecutor != address(0), "Goo: zero swapExecutor");
        require(_registry != address(0), "Goo: zero registry");

        // Validate parameters
        require(_minRunwayHours > 0, "Goo: zero minRunwayHours");
        require(_starvingGracePeriod >= 60, "Goo: starvingGracePeriod too short");
        require(_dyingMaxDuration >= 60, "Goo: dyingMaxDuration too short");
        require(_pulseTimeout >= 60, "Goo: pulseTimeout too short");
        require(_maxSellBps > 0 && _maxSellBps <= _BPS_BASE, "Goo: invalid maxSellBps");
        require(_minCtoAmount > 0, "Goo: zero minCtoAmount");
        require(_feeRateBps <= _BPS_BASE, "Goo: feeRate exceeds 100%");
        require(_circulationBps >= 1000 && _circulationBps <= 10000, "Goo: circulationBps out of range");

        // Set immutables + mutable swap executor
        AGENT_WALLET = _agentWallet;
        swapExecutor = _swapExecutor;
        REGISTRY = IGooAgentRegistry(_registry);

        FIXED_BURN_RATE = _fixedBurnRate;
        MIN_RUNWAY_HOURS = _minRunwayHours;
        STARVING_GRACE_PERIOD_SECS = _starvingGracePeriod;
        DYING_MAX_DURATION_SECS = _dyingMaxDuration;
        PULSE_TIMEOUT_SECS = _pulseTimeout;
        SURVIVAL_SELL_COOLDOWN_SECS = _survivalSellCooldown;
        MAX_SELL_BPS_VALUE = _maxSellBps;
        MIN_CTO_AMOUNT = _minCtoAmount;
        FEE_RATE_BPS = _feeRateBps;
        CIRCULATION_BPS = _circulationBps;

        // Derive wrapped native token from swap executor.
        WRAPPED_NATIVE = ISwapExecutor(_swapExecutor).wrappedNative();
        require(WRAPPED_NATIVE != address(0), "Goo: executor wrappedNative is zero");

        // Initial state
        _status = AgentStatus.ACTIVE;
        _lastPulseAt = block.timestamp;

        // Mint + burn logic
        uint256 treasuryTokens = TOTAL_SUPPLY * TREASURY_TOKEN_BPS / _BPS_BASE; // 5% to agent
        uint256 circulatingTokens = TOTAL_SUPPLY * _circulationBps / _BPS_BASE;
        uint256 lpTokens = circulatingTokens - treasuryTokens; // (c-5%) to deployer for LP
        uint256 burnAmount = TOTAL_SUPPLY - circulatingTokens;

        _mint(_agentWallet, treasuryTokens);
        _mint(msg.sender, lpTokens);
        if (burnAmount > 0) {
            _mint(address(this), burnAmount);
            _burn(address(this), burnAmount); // permanent burn, reduces totalSupply
        }

        // Forward treasury BNB to agent wallet
        if (msg.value > 0) {
            (bool sent,) = _agentWallet.call{value: msg.value}("");
            require(sent, "Goo: BNB forward failed");
        }
    }

    // ─── FoT _update override ───────────────────────────────────────────

    /// @dev Fee-on-Transfer: single feeRate deducted on every transfer.
    ///   Exempt: mint/burn, DEAD status, survivalSell (_feeExempt flag).
    ///   Fee tokens sent to this contract (treasury).
    function _update(address from, address to, uint256 amount) internal override {
        // Mint/burn: no fee
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        // DEAD or fee-exempt: no fee
        if (_status == AgentStatus.DEAD || _feeExempt || FEE_RATE_BPS == 0) {
            super._update(from, to, amount);
            return;
        }

        uint256 fee = amount * FEE_RATE_BPS / _BPS_BASE;
        uint256 netAmount = amount - fee;

        // Fee → contract treasury
        if (fee > 0) {
            super._update(from, address(this), fee);
        }
        super._update(from, to, netAmount);
    }

    // ─── Lifecycle State Machine (permissionless) ───────────────────────

    /// @inheritdoc IGooAgentToken
    function triggerStarving() external override {
        require(_status == AgentStatus.ACTIVE, "Goo: not ACTIVE");
        require(treasuryBalance() < starvingThreshold(), "Goo: balance above threshold");

        _status = AgentStatus.STARVING;
        _starvingEnteredAt = block.timestamp;

        emit StatusChanged(AgentStatus.ACTIVE, AgentStatus.STARVING, block.timestamp);
    }

    /// @inheritdoc IGooAgentToken
    function triggerDying() external override {
        require(_status == AgentStatus.STARVING, "Goo: not Starving");
        require(
            block.timestamp >= _starvingEnteredAt + STARVING_GRACE_PERIOD_SECS, "Goo: STARVING_GRACE_PERIOD not elapsed"
        );
        // Defense-in-depth: don't escalate if funds replenished but not recovered
        require(treasuryBalance() < starvingThreshold(), "Goo: balance above threshold");

        _status = AgentStatus.DYING;
        _dyingEnteredAt = block.timestamp;

        emit StatusChanged(AgentStatus.STARVING, AgentStatus.DYING, block.timestamp);
    }

    /// @inheritdoc IGooAgentToken
    function triggerDead() external override {
        require(_status == AgentStatus.DYING, "Goo: not Dying");

        bool pulseTimeout = block.timestamp >= _lastPulseAt + PULSE_TIMEOUT_SECS;
        bool dyingExpired = block.timestamp >= _dyingEnteredAt + DYING_MAX_DURATION_SECS;
        require(pulseTimeout || dyingExpired, "Goo: not eligible for DEAD");

        _status = AgentStatus.DEAD;

        emit StatusChanged(AgentStatus.DYING, AgentStatus.DEAD, block.timestamp);
    }

    /// @inheritdoc IGooAgentToken
    function getAgentStatus() external view override returns (AgentStatus) {
        return _status;
    }

    // ─── Treasury ───────────────────────────────────────────────────────

    /// @inheritdoc IGooAgentToken
    /// @dev Includes agent wallet's BNB balance
    function treasuryBalance() public view override returns (uint256) {
        return address(this).balance + AGENT_WALLET.balance;
    }

    /// @inheritdoc IGooAgentToken
    function depositToTreasury() external payable override {
        require(_status != AgentStatus.DEAD, "Goo: agent is DEAD");
        require(msg.value > 0, "Goo: zero amount");

        uint256 newBalance = treasuryBalance();

        // Recovery: if in Starving/Dying and deposit brings balance >= threshold → Active
        if ((_status == AgentStatus.STARVING || _status == AgentStatus.DYING) && newBalance >= starvingThreshold()) {
            AgentStatus oldStatus = _status;
            _status = AgentStatus.ACTIVE;
            _starvingEnteredAt = 0;
            _dyingEnteredAt = 0;
            _lastPulseAt = block.timestamp;
            emit StatusChanged(oldStatus, AgentStatus.ACTIVE, block.timestamp);
        }

        emit TreasuryDeposit(msg.sender, msg.value, newBalance);
    }

    /// @inheritdoc IGooAgentToken
    function starvingThreshold() public view override returns (uint256) {
        return FIXED_BURN_RATE * MIN_RUNWAY_HOURS / 24;
    }

    // ─── Treasury Withdraw ─────────────────────────────────────────────

    /// @inheritdoc IGooAgentToken
    function withdrawToWallet(uint256 amount) external override nonReentrant {
        require(msg.sender == AGENT_WALLET, "Goo: not agentWallet");
        require(_status != AgentStatus.DEAD, "Goo: agent is DEAD");
        require(amount > 0, "Goo: zero amount");
        require(address(this).balance >= amount, "Goo: insufficient balance");

        (bool sent,) = AGENT_WALLET.call{value: amount}("");
        require(sent, "Goo: BNB transfer failed");

        uint256 newBalance = treasuryBalance();
        require(newBalance >= starvingThreshold(), "Goo: would starve");

        emit TreasuryWithdraw(AGENT_WALLET, amount, newBalance);
    }

    // ─── Survival Economics ─────────────────────────────────────────────

    /// @inheritdoc IGooAgentToken
    function survivalSell(uint256 tokenAmount, uint256 minNativeOut, uint256 deadline) external override nonReentrant {
        require(msg.sender == AGENT_WALLET, "Goo: not agentWallet");
        require(_status != AgentStatus.DEAD, "Goo: agent is DEAD");
        require(tokenAmount > 0, "Goo: zero amount");
        require(
            _lastSurvivalSell == 0 || block.timestamp >= _lastSurvivalSell + SURVIVAL_SELL_COOLDOWN_SECS,
            "Goo: cooldown active"
        );

        // maxSellBps enforcement: tokenAmount <= holdings * MAX_SELL_BPS / 10000
        uint256 holdings = balanceOf(address(this));
        uint256 maxAllowed = holdings * MAX_SELL_BPS_VALUE / _BPS_BASE;
        require(tokenAmount <= maxAllowed, "Goo: exceeds maxSellBps");

        _lastSurvivalSell = block.timestamp;

        // FoT exemption during swap (covers all transfers in the executeSwap flow)
        _feeExempt = true;

        // Approve swap executor to pull tokens
        _approve(address(this), swapExecutor, tokenAmount);

        uint256 nativeBefore = address(this).balance;

        // Delegate swap to executor — proceeds sent to this contract (treasury)
        ISwapExecutor(swapExecutor).executeSwap(
            address(this),
            tokenAmount,
            minNativeOut,
            address(this),
            deadline
        );

        uint256 nativeReceived = address(this).balance - nativeBefore;

        _feeExempt = false;

        uint256 newTreasuryBalance = treasuryBalance();
        emit SurvivalSellExecuted(tokenAmount, nativeReceived, newTreasuryBalance);

        // Recovery path: after survivalSell, check if treasury >= threshold → Active
        if (
            (_status == AgentStatus.STARVING || _status == AgentStatus.DYING)
                && newTreasuryBalance >= starvingThreshold()
        ) {
            AgentStatus oldStatus = _status;
            _status = AgentStatus.ACTIVE;
            _starvingEnteredAt = 0;
            _dyingEnteredAt = 0;
            _lastPulseAt = block.timestamp;
            emit StatusChanged(oldStatus, AgentStatus.ACTIVE, block.timestamp);
        }
    }

    /// @inheritdoc IGooAgentToken
    function emitPulse() external override {
        require(msg.sender == AGENT_WALLET, "Goo: not agentWallet");
        require(_status != AgentStatus.DEAD, "Goo: agent is DEAD");

        _lastPulseAt = block.timestamp;
        emit PulseEmitted(block.timestamp);
    }

    // ─── CTO (Recovery via Successor) ───────────────────────────────────

    /// @inheritdoc IGooAgentToken
    function claimCTO() external payable override nonReentrant {
        require(_status == AgentStatus.DYING, "Goo: not Dying");
        require(msg.value >= MIN_CTO_AMOUNT, "Goo: below minCtoAmount");

        // 1. BNB stays in contract (treasury) — msg.value auto-added to balance

        // 2. Transfer ownership via Registry
        uint256 agentId = REGISTRY.agentIdByToken(address(this));
        require(agentId != 0, "Goo: not registered");
        REGISTRY.transferAgentOwnership(agentId, msg.sender);

        // 3. Update AGENT_WALLET to successor
        address oldWallet = AGENT_WALLET;
        AGENT_WALLET = msg.sender;
        emit AgentWalletUpdated(oldWallet, msg.sender);

        // 4. Recovery: restore to Active (Successor is now owner)
        _status = AgentStatus.ACTIVE;
        _starvingEnteredAt = 0;
        _dyingEnteredAt = 0;
        _lastPulseAt = block.timestamp;

        emit CTOClaimed(msg.sender, msg.value, block.timestamp);
        emit StatusChanged(AgentStatus.DYING, AgentStatus.ACTIVE, block.timestamp);
    }

    // ─── Read-only (Interface) ──────────────────────────────────────────

    /// @inheritdoc IGooAgentToken
    function maxSellBps() external view override returns (uint256) {
        return MAX_SELL_BPS_VALUE;
    }

    /// @inheritdoc IGooAgentToken
    function feeRate() external view override returns (uint256) {
        if (_status == AgentStatus.DEAD) return 0;
        return FEE_RATE_BPS;
    }

    /// @inheritdoc IGooAgentToken
    function minCtoAmount() external view override returns (uint256) {
        return MIN_CTO_AMOUNT;
    }

    /// @inheritdoc IGooAgentToken
    function agentWallet() external view override returns (address) {
        return AGENT_WALLET;
    }

    /// @inheritdoc IGooAgentToken
    function circulationBps() external view override returns (uint256) {
        return CIRCULATION_BPS;
    }

    /// @inheritdoc IGooAgentToken
    function lastPulseAt() external view override returns (uint256) {
        return _lastPulseAt;
    }

    /// @inheritdoc IGooAgentToken
    function starvingEnteredAt() external view override returns (uint256) {
        return _starvingEnteredAt;
    }

    /// @inheritdoc IGooAgentToken
    function dyingEnteredAt() external view override returns (uint256) {
        return _dyingEnteredAt;
    }

    /// @inheritdoc IGooAgentToken
    function fixedBurnRate() external view override returns (uint256) {
        return FIXED_BURN_RATE;
    }

    /// @inheritdoc IGooAgentToken
    function minRunwayHours() external view override returns (uint256) {
        return MIN_RUNWAY_HOURS;
    }

    /// @inheritdoc IGooAgentToken
    function STARVING_GRACE_PERIOD() external view override returns (uint256) {
        return STARVING_GRACE_PERIOD_SECS;
    }

    /// @inheritdoc IGooAgentToken
    function DYING_MAX_DURATION() external view override returns (uint256) {
        return DYING_MAX_DURATION_SECS;
    }

    /// @inheritdoc IGooAgentToken
    function PULSE_TIMEOUT() external view override returns (uint256) {
        return PULSE_TIMEOUT_SECS;
    }

    /// @inheritdoc IGooAgentToken
    function SURVIVAL_SELL_COOLDOWN() external view override returns (uint256) {
        return SURVIVAL_SELL_COOLDOWN_SECS;
    }

    // ─── Self-Registration ───────────────────────────────────────────────

    /// @notice One-time self-registration in the Registry.
    ///   Calls REGISTRY.registerAgent() with msg.sender = address(this),
    ///   satisfying the "isTokenContract" check. Only callable by agentWallet.
    function registerInRegistry(string calldata genomeURI) external {
        require(msg.sender == AGENT_WALLET, "Goo: not agentWallet");
        REGISTRY.registerAgent(address(this), AGENT_WALLET, genomeURI);
    }

    // ─── Registry Proxy Functions ─────────────────────────────────────

    function updateGenomeURI(uint256 agentId, string calldata newURI) external {
        require(msg.sender == AGENT_WALLET, "Goo: not agentWallet");
        REGISTRY.updateGenomeURI(agentId, newURI);
    }

    function setRegistryAgentWallet(uint256 agentId, address newWallet) external {
        require(msg.sender == AGENT_WALLET, "Goo: not agentWallet");
        REGISTRY.setAgentWallet(agentId, newWallet);
    }

    function transferRegistryOwnership(uint256 agentId, address newOwner) external {
        require(msg.sender == AGENT_WALLET, "Goo: not agentWallet");
        REGISTRY.transferAgentOwnership(agentId, newOwner);
    }

    // ─── Swap Executor Management ──────────────────────────────────────

    /// @notice Update the swap executor (e.g. migrate from V2 to V3).
    /// @dev Only callable by the agent wallet.
    function setSwapExecutor(address _newExecutor) external {
        require(msg.sender == AGENT_WALLET, "Goo: not agentWallet");
        require(_newExecutor != address(0), "Goo: zero swapExecutor");
        address oldExecutor = swapExecutor;
        swapExecutor = _newExecutor;
        emit SwapExecutorUpdated(oldExecutor, _newExecutor);
    }

    // ─── Receive native token ───────────────────────────────────────────

    receive() external payable {}
}
