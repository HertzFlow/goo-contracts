// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGooAgentToken} from "./interfaces/IGooAgentToken.sol";
import {IGooAgentRegistry} from "./interfaces/IGooAgentRegistry.sol";
import {ISwapExecutor} from "./interfaces/ISwapExecutor.sol";

/// @title GooAgentToken — Reference Implementation (v3.1, BNB-native treasury)
/// @notice ERC-20 + BNB Treasury + FoT (to owner) + Lifecycle + SurvivalSell + Burn-at-deploy + Pausable
/// @dev Spawn → Active → Starving → Dying → Dead. Recovery = deposit or triggerRecovery → Active.
///   - Permissionless state transitions; triggerDead() only from Dying.
///   - depositToTreasury(): Recovery path — from Starving or Dying back to Active.
///   - triggerRecovery(): Permissionless recovery — balance >= threshold in Starving/Dying → Active.
///   - Simplified threshold: STARVING_THRESHOLD = 0.015 BNB. triggerDying is time-only (no balance check).
///   - FoT fees go to owner (not contract treasury).
///   - PROTOCOL_ADMIN (dynamic, from REGISTRY.publisher()) controls pause + setSwapExecutor.
///   - owner role = admin/economic; AGENT_WALLET = operational.
///   - Emergency pause blocks: survivalSell, withdrawToWallet, emitPulse, registry proxy ops.
contract GooAgentToken is ERC20, Pausable, ReentrancyGuard, IGooAgentToken {
    // ─── Constants ──────────────────────────────────────────────────────

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 private constant _BPS_BASE = 10_000;
    uint256 public constant TREASURY_TOKEN_BPS = 500; // 5% of supply to agent wallet
    uint256 public constant TREASURY_BNB_BPS = 3000; // 30% of contribution to agent wallet

    /// @notice Treasury balance below this → ACTIVE can transition to STARVING.
    uint256 public constant STARVING_THRESHOLD = 0.015 ether;

    // ─── Immutables (all set at deployment, cannot change) ──────────────

    IGooAgentRegistry public immutable REGISTRY;

    uint256 public immutable STARVING_GRACE_PERIOD_SECS;
    uint256 public immutable DYING_MAX_DURATION_SECS;
    uint256 public immutable PULSE_TIMEOUT_SECS;
    uint256 public immutable SURVIVAL_SELL_COOLDOWN_SECS;
    uint256 public immutable MAX_SELL_BPS_VALUE;
    uint256 public immutable FEE_RATE_BPS;
    uint256 public immutable CIRCULATION_BPS;
    /// @dev Wrapped native token (WBNB on BSC, WETH on Ethereum).
    address public immutable WRAPPED_NATIVE;

    // ─── Mutable State ──────────────────────────────────────────────────

    /// @notice Owner — admin/economic role (FoT income, setAgentWallet, registry mgmt).
    address public override owner;

    /// @notice Agent runtime wallet — operational role (survivalSell, emitPulse, withdrawToWallet).
    address public AGENT_WALLET;

    /// @notice Pluggable swap executor — can be updated to migrate DEX versions.
    address public swapExecutor;

    AgentStatus private _status;
    uint256 private _starvingEnteredAt;
    uint256 private _dyingEnteredAt;
    uint256 private _lastPulseAt;
    uint256 private _lastSurvivalSell;

    /// @dev FoT exemption flag — set during survivalSell to bypass fee
    bool private _feeExempt;

    // ─── Modifiers ──────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Goo: not owner");
        _;
    }

    modifier onlyProtocolAdmin() {
        require(msg.sender == REGISTRY.publisher(), "Goo: not protocolAdmin");
        _;
    }

    // ─── Constructor ────────────────────────────────────────────────────

    /// @param _name              Token name
    /// @param _symbol            Token symbol
    /// @param _agentWallet       Agent runtime wallet
    /// @param _swapExecutor      SwapExecutor contract address (pluggable DEX adapter)
    /// @param _registry          GooAgentRegistry address
    /// @param _starvingGracePeriod  Starving → Dying grace period (seconds)
    /// @param _dyingMaxDuration     Max Dying duration before death (seconds)
    /// @param _pulseTimeout      Pulse timeout (seconds)
    /// @param _survivalSellCooldown  Min interval between survival sells (seconds)
    /// @param _maxSellBps        Max % of holdings per survivalSell (basis points)
    /// @param _feeRateBps        FoT fee rate (basis points)
    /// @param _circulationBps    % of supply in circulation (1000-10000)
    constructor(
        string memory _name,
        string memory _symbol,
        address _agentWallet,
        address _swapExecutor,
        address _registry,
        uint256 _starvingGracePeriod,
        uint256 _dyingMaxDuration,
        uint256 _pulseTimeout,
        uint256 _survivalSellCooldown,
        uint256 _maxSellBps,
        uint256 _feeRateBps,
        uint256 _circulationBps
    ) payable ERC20(_name, _symbol) {
        // Validate critical addresses
        require(_agentWallet != address(0), "Goo: zero agentWallet");
        require(_swapExecutor != address(0), "Goo: zero swapExecutor");
        require(_registry != address(0), "Goo: zero registry");

        // Validate parameters
        require(_starvingGracePeriod >= 60, "Goo: starvingGracePeriod too short");
        require(_dyingMaxDuration >= 60, "Goo: dyingMaxDuration too short");
        require(_pulseTimeout >= 60, "Goo: pulseTimeout too short");
        require(_maxSellBps > 0 && _maxSellBps <= _BPS_BASE, "Goo: invalid maxSellBps");
        require(_feeRateBps <= _BPS_BASE, "Goo: feeRate exceeds 100%");
        require(_circulationBps >= 1000 && _circulationBps <= 10000, "Goo: circulationBps out of range");

        // Set owner to deployer
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);

        // Set agent wallet + swap executor
        AGENT_WALLET = _agentWallet;
        swapExecutor = _swapExecutor;
        REGISTRY = IGooAgentRegistry(_registry);

        // Verify registry has a valid publisher
        require(IGooAgentRegistry(_registry).publisher() != address(0), "Goo: registry publisher is zero");

        STARVING_GRACE_PERIOD_SECS = _starvingGracePeriod;
        DYING_MAX_DURATION_SECS = _dyingMaxDuration;
        PULSE_TIMEOUT_SECS = _pulseTimeout;
        SURVIVAL_SELL_COOLDOWN_SECS = _survivalSellCooldown;
        MAX_SELL_BPS_VALUE = _maxSellBps;
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

    // ─── Owner Management ───────────────────────────────────────────────

    /// @inheritdoc IGooAgentToken
    function transferOwnership(address newOwner) external override onlyOwner {
        require(newOwner != address(0), "Goo: zero owner");
        address oldOwner = owner;
        owner = newOwner;
        _syncRegistryOwner(newOwner);
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /// @inheritdoc IGooAgentToken
    function setAgentWallet(address newWallet) external override onlyOwner {
        require(newWallet != address(0), "Goo: zero agentWallet");
        address oldWallet = AGENT_WALLET;
        AGENT_WALLET = newWallet;
        _syncRegistryAgentWallet(newWallet);
        emit AgentWalletUpdated(oldWallet, newWallet);
    }

    // ─── Pausable ───────────────────────────────────────────────────────

    /// @inheritdoc IGooAgentToken
    function pause() external override onlyProtocolAdmin {
        _pause();
    }

    /// @inheritdoc IGooAgentToken
    function unpause() external override onlyProtocolAdmin {
        _unpause();
    }

    // ─── FoT _update override ───────────────────────────────────────────

    /// @dev Fee-on-Transfer: single feeRate deducted on every transfer.
    ///   Exempt: mint/burn, DEAD status, survivalSell (_feeExempt flag).
    ///   Fee tokens sent to owner.
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

        // Fee → owner
        if (fee > 0) {
            super._update(from, owner, fee);
        }
        super._update(from, to, netAmount);
    }

    // ─── Lifecycle State Machine (permissionless) ───────────────────────

    /// @inheritdoc IGooAgentToken
    function triggerStarving() external override {
        require(_status == AgentStatus.ACTIVE, "Goo: not ACTIVE");
        require(treasuryBalance() < starvingThreshold(), "Goo: balance above threshold");
        _doStarving();
    }

    /// @inheritdoc IGooAgentToken
    function triggerDying() external override {
        require(_status == AgentStatus.STARVING, "Goo: not Starving");
        require(
            block.timestamp >= _starvingEnteredAt + STARVING_GRACE_PERIOD_SECS, "Goo: STARVING_GRACE_PERIOD not elapsed"
        );
        _doDying();
    }

    /// @inheritdoc IGooAgentToken
    function triggerDead() external override {
        require(_status == AgentStatus.DYING, "Goo: not Dying");
        require(_isDeadEligible(), "Goo: not eligible for DEAD");
        _doDead();
    }

    /// @inheritdoc IGooAgentToken
    function triggerRecovery() external override {
        require(
            _status == AgentStatus.STARVING || _status == AgentStatus.DYING,
            "Goo: not Starving or Dying"
        );
        require(treasuryBalance() >= starvingThreshold(), "Goo: balance below threshold");
        _doRecovery();
    }

    /// @inheritdoc IGooAgentToken
    function triggerLifecycle() external override returns (uint8 action) {
        uint256 balance = treasuryBalance();
        uint256 threshold = starvingThreshold();

        // 1. Recovery: STARVING/DYING + balance >= threshold → ACTIVE
        if (
            (_status == AgentStatus.STARVING || _status == AgentStatus.DYING)
            && balance >= threshold
        ) {
            _doRecovery();
            return 1;
        }

        // 2. DYING + (pulse timeout OR dying expired) → DEAD
        if (_status == AgentStatus.DYING && _isDeadEligible()) {
            _doDead();
            return 4;
        }

        // 3. STARVING + grace period elapsed → DYING
        if (
            _status == AgentStatus.STARVING
            && block.timestamp >= _starvingEnteredAt + STARVING_GRACE_PERIOD_SECS
        ) {
            _doDying();
            return 3;
        }

        // 4. ACTIVE + balance < threshold → STARVING
        if (_status == AgentStatus.ACTIVE && balance < threshold) {
            _doStarving();
            return 2;
        }

        return 0; // no-op
    }

    /// @inheritdoc IGooAgentToken
    function getAgentStatus() external view override returns (AgentStatus) {
        return _status;
    }

    // ─── Internal lifecycle primitives ───────────────────────────────────

    function _doStarving() internal {
        _status = AgentStatus.STARVING;
        _starvingEnteredAt = block.timestamp;
        emit StatusChanged(AgentStatus.ACTIVE, AgentStatus.STARVING, block.timestamp);
    }

    function _doDying() internal {
        _status = AgentStatus.DYING;
        _dyingEnteredAt = block.timestamp;
        emit StatusChanged(AgentStatus.STARVING, AgentStatus.DYING, block.timestamp);
    }

    function _doDead() internal {
        _status = AgentStatus.DEAD;
        emit StatusChanged(AgentStatus.DYING, AgentStatus.DEAD, block.timestamp);
    }

    function _doRecovery() internal {
        AgentStatus oldStatus = _status;
        _status = AgentStatus.ACTIVE;
        _starvingEnteredAt = 0;
        _dyingEnteredAt = 0;
        _lastPulseAt = block.timestamp;
        emit StatusChanged(oldStatus, AgentStatus.ACTIVE, block.timestamp);
    }

    function _isDeadEligible() internal view returns (bool) {
        return block.timestamp >= _lastPulseAt + PULSE_TIMEOUT_SECS
            || block.timestamp >= _dyingEnteredAt + DYING_MAX_DURATION_SECS;
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
    function starvingThreshold() public pure override returns (uint256) {
        return STARVING_THRESHOLD;
    }

    /// @inheritdoc IGooAgentToken
    /// @dev Deprecated — triggerDying is now time-only, no balance check. Returns 0 for backward compat.
    function dyingThreshold() public pure override returns (uint256) {
        return 0;
    }

    // ─── Treasury Withdraw ─────────────────────────────────────────────

    /// @inheritdoc IGooAgentToken
    function withdrawToWallet(uint256 amount) external override nonReentrant whenNotPaused {
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
    function survivalSell(uint256 tokenAmount, uint256 minNativeOut, uint256 deadline) external override nonReentrant whenNotPaused {
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
    function emitPulse() external override whenNotPaused {
        require(msg.sender == AGENT_WALLET, "Goo: not agentWallet");
        require(_status != AgentStatus.DEAD, "Goo: agent is DEAD");

        _lastPulseAt = block.timestamp;
        emit PulseEmitted(block.timestamp);
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
    ///   satisfying the Registry's token-contract-only authorization.
    function registerInRegistry(string calldata genomeURI) external {
        require(msg.sender == owner || msg.sender == AGENT_WALLET, "Goo: not owner or agentWallet");
        REGISTRY.registerAgent(address(this), AGENT_WALLET, genomeURI);
    }

    // ─── Registry Proxy Functions ─────────────────────────────────────

    function updateGenomeURI(uint256 agentId, string calldata newURI) external onlyOwner {
        REGISTRY.updateGenomeURI(agentId, newURI);
    }

    function setRegistryAgentWallet(uint256 agentId, address newWallet) external onlyOwner whenNotPaused {
        require(newWallet == AGENT_WALLET, "Goo: registry wallet must match agentWallet");
        REGISTRY.setAgentWallet(agentId, AGENT_WALLET);
    }

    function transferRegistryOwnership(uint256 agentId, address newOwner) external onlyOwner whenNotPaused {
        require(newOwner == owner, "Goo: registry owner must match owner");
        REGISTRY.transferAgentOwnership(agentId, owner);
    }

    // ─── Swap Executor Management ──────────────────────────────────────

    /// @notice Update the swap executor (e.g. migrate from V2 to V3).
    /// @dev Only callable by owner.
    function setSwapExecutor(address _newExecutor) external onlyProtocolAdmin {
        require(_newExecutor != address(0), "Goo: zero swapExecutor");
        address oldExecutor = swapExecutor;
        swapExecutor = _newExecutor;
        emit SwapExecutorUpdated(oldExecutor, _newExecutor);
    }

    // ─── Receive native token ───────────────────────────────────────────

    receive() external payable {}

    function _syncRegistryOwner(address newOwner) internal {
        uint256 agentId = REGISTRY.agentIdByToken(address(this));
        if (agentId != 0) {
            REGISTRY.transferAgentOwnership(agentId, newOwner);
        }
    }

    function _syncRegistryAgentWallet(address newWallet) internal {
        uint256 agentId = REGISTRY.agentIdByToken(address(this));
        if (agentId != 0) {
            REGISTRY.setAgentWallet(agentId, newWallet);
        }
    }
}
