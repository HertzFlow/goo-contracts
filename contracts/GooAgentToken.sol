// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGooAgentToken} from "./interfaces/IGooAgentToken.sol";
import {IGooAgentRegistry} from "./interfaces/IGooAgentRegistry.sol";

/// @title GooAgentToken — Reference Implementation (v1.0)
/// @notice ERC-20 + Treasury + FoT + Lifecycle State Machine + SurvivalSell + CTO
/// @dev Spawn → Active → Starving → Dying → Dead. Recovery = deposit or Successor(CTO) → Active.
///   - Permissionless state transitions; triggerDead() only from Dying.
///   - depositToTreasury(): Recovery path — from Starving or Dying back to Active.
///   - claimCTO(): Recovery path — Successor takes over in Dying, status → Active.
///   - All parameters immutable. Treasury = stableToken.balanceOf(this).
contract GooAgentToken is ERC20, ReentrancyGuard, IGooAgentToken {

    // ─── Constants ──────────────────────────────────────────────────────

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 private constant _BPS_BASE = 10_000;

    // ─── Immutables (all set at deployment, cannot change) ──────────────

    IERC20 public immutable STABLE_TOKEN;
    uint8  public immutable STABLE_DECIMALS;
    address public immutable AGENT_WALLET;
    address public immutable ROUTER;
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
    /// @dev Wrapped native token (WBNB on BSC, WETH on Ethereum).
    ///   PancakeSwap/Uniswap V2 Router exposes this via `WETH()` regardless of chain.
    address public immutable WRAPPED_NATIVE;

    // ─── Mutable State ──────────────────────────────────────────────────

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
    /// @param _stableToken       Stablecoin address (USDT, USDC, etc.)
    /// @param _stableDecimals    Stablecoin decimal precision
    /// @param _agentWallet       Agent runtime wallet
    /// @param _router            DEX router address
    /// @param _registry          GooAgentRegistry address
    /// @param _fixedBurnRate     Daily operational cost (stablecoin units)
    /// @param _minRunwayHours    Minimum runway hours for starving threshold
    /// @param _starvingGracePeriod  Starving → Dying grace period (seconds)
    /// @param _dyingMaxDuration     Max Dying duration before death (seconds)
    /// @param _pulseTimeout      Pulse timeout (seconds)
    /// @param _survivalSellCooldown  Min interval between survival sells (seconds)
    /// @param _maxSellBps        Max % of holdings per survivalSell (basis points)
    /// @param _minCtoAmount      Min stablecoin for CTO claim
    /// @param _feeRateBps        FoT fee rate (basis points)
    constructor(
        string memory _name,
        string memory _symbol,
        address _stableToken,
        uint8   _stableDecimals,
        address _agentWallet,
        address _router,
        address _registry,
        uint256 _fixedBurnRate,
        uint256 _minRunwayHours,
        uint256 _starvingGracePeriod,
        uint256 _dyingMaxDuration,
        uint256 _pulseTimeout,
        uint256 _survivalSellCooldown,
        uint256 _maxSellBps,
        uint256 _minCtoAmount,
        uint256 _feeRateBps
    ) ERC20(_name, _symbol) {
        // Validate critical addresses
        require(_stableToken != address(0), "Goo: zero stableToken");
        require(_agentWallet != address(0), "Goo: zero agentWallet");
        require(_router != address(0), "Goo: zero router");
        require(_registry != address(0), "Goo: zero registry");

        // Validate parameters
        require(_fixedBurnRate > 0, "Goo: zero burnRate");
        require(_minRunwayHours > 0, "Goo: zero minRunwayHours");
        require(_starvingGracePeriod >= 60, "Goo: starvingGracePeriod too short");
        require(_dyingMaxDuration >= 60, "Goo: dyingMaxDuration too short");
        require(_pulseTimeout >= 60, "Goo: pulseTimeout too short");
        require(_maxSellBps > 0 && _maxSellBps <= _BPS_BASE, "Goo: invalid maxSellBps");
        require(_minCtoAmount > 0, "Goo: zero minCtoAmount");
        require(_feeRateBps <= _BPS_BASE, "Goo: feeRate exceeds 100%");

        // Set immutables
        STABLE_TOKEN = IERC20(_stableToken);
        STABLE_DECIMALS = _stableDecimals;
        AGENT_WALLET = _agentWallet;
        ROUTER = _router;
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

        // Derive wrapped native token from router (WBNB on BSC, WETH on Ethereum).
        // PancakeSwap/Uniswap V2 Router always exposes this via WETH() regardless of chain.
        (bool wnOk, bytes memory wnData) = _router.staticcall(
            abi.encodeWithSignature("WETH()")
        );
        require(wnOk && wnData.length >= 32, "Goo: router WETH() failed");
        WRAPPED_NATIVE = abi.decode(wnData, (address));

        // Initial state
        _status = AgentStatus.ACTIVE;
        _lastPulseAt = block.timestamp;

        // Mint total supply: all to deployer (deployer manages LP + treasury setup)
        _mint(msg.sender, TOTAL_SUPPLY);
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
            block.timestamp >= _starvingEnteredAt + STARVING_GRACE_PERIOD_SECS,
            "Goo: STARVING_GRACE_PERIOD not elapsed"
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
    function treasuryBalance() public view override returns (uint256) {
        return STABLE_TOKEN.balanceOf(address(this));
    }

    /// @inheritdoc IGooAgentToken
    function depositToTreasury(uint256 amount) external override {
        require(_status != AgentStatus.DEAD, "Goo: agent is DEAD");
        require(amount > 0, "Goo: zero amount");

        // Transfer stablecoin to this contract
        bool success = STABLE_TOKEN.transferFrom(msg.sender, address(this), amount);
        require(success, "Goo: transfer failed");

        uint256 newBalance = treasuryBalance();

        // Recovery: if in Starving/Dying and deposit brings balance >= threshold → Active
        if (
            (_status == AgentStatus.STARVING || _status == AgentStatus.DYING) &&
            newBalance >= starvingThreshold()
        ) {
            AgentStatus oldStatus = _status;
            _status = AgentStatus.ACTIVE;
            _starvingEnteredAt = 0;
            _dyingEnteredAt = 0;
            emit StatusChanged(oldStatus, AgentStatus.ACTIVE, block.timestamp);
        }

        emit TreasuryDeposit(msg.sender, amount, newBalance);
    }

    /// @inheritdoc IGooAgentToken
    function starvingThreshold() public view override returns (uint256) {
        return FIXED_BURN_RATE * MIN_RUNWAY_HOURS / 24;
    }

    // ─── Survival Economics ─────────────────────────────────────────────

    /// @inheritdoc IGooAgentToken
    function survivalSell(uint256 tokenAmount, uint256 minStableOut)
        external
        override
        nonReentrant
    {
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

        // FoT exemption during swap
        _feeExempt = true;

        // Approve router
        _approve(address(this), ROUTER, tokenAmount);

        // Swap via router: token → WBNB/WETH → stablecoin (3-hop)
        // Must route through wrapped native because AMM pairs reject `to == pair token`
        address[] memory path = new address[](3);
        path[0] = address(this);
        path[1] = WRAPPED_NATIVE;
        path[2] = address(STABLE_TOKEN);

        uint256 stableBefore = STABLE_TOKEN.balanceOf(address(this));

        // Call router swap (FoT-safe variant)
        (bool ok,) = ROUTER.call(
            abi.encodeWithSignature(
                "swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)",
                tokenAmount,
                minStableOut,
                path,
                address(this),  // proceeds to treasury (this contract)
                block.timestamp
            )
        );
        require(ok, "Goo: swap failed");

        uint256 stableReceived = STABLE_TOKEN.balanceOf(address(this)) - stableBefore;

        _feeExempt = false;

        uint256 newTreasuryBalance = treasuryBalance();
        emit SurvivalSellExecuted(tokenAmount, stableReceived, newTreasuryBalance);

        // Recovery path: after survivalSell, check if treasury >= threshold → Active
        if (
            (_status == AgentStatus.STARVING || _status == AgentStatus.DYING) &&
            newTreasuryBalance >= starvingThreshold()
        ) {
            AgentStatus oldStatus = _status;
            _status = AgentStatus.ACTIVE;
            _starvingEnteredAt = 0;
            _dyingEnteredAt = 0;
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
    function claimCTO(uint256 creditAmount) external override nonReentrant {
        require(_status == AgentStatus.DYING, "Goo: not Dying");
        require(creditAmount >= MIN_CTO_AMOUNT, "Goo: below minCtoAmount");

        // 1. Transfer stablecoin from caller to treasury
        uint256 balBefore = STABLE_TOKEN.balanceOf(address(this));
        bool success = STABLE_TOKEN.transferFrom(msg.sender, address(this), creditAmount);
        require(success, "Goo: transfer failed");
        uint256 actualReceived = STABLE_TOKEN.balanceOf(address(this)) - balBefore;
        require(actualReceived >= creditAmount, "Goo: amount mismatch");

        // 2. Transfer ownership via Registry
        uint256 agentId = REGISTRY.agentIdByToken(address(this));
        require(agentId != 0, "Goo: not registered");
        REGISTRY.transferAgentOwnership(agentId, msg.sender);

        // 3. Recovery: restore to Active (Successor is now owner)
        _status = AgentStatus.ACTIVE;
        _starvingEnteredAt = 0;
        _dyingEnteredAt = 0;
        _lastPulseAt = block.timestamp;

        emit CTOClaimed(msg.sender, creditAmount, block.timestamp);
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
    function stableToken() external view override returns (address) {
        return address(STABLE_TOKEN);
    }

    /// @inheritdoc IGooAgentToken
    function stableDecimals() external view override returns (uint8) {
        return STABLE_DECIMALS;
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

    // ─── Receive native token ───────────────────────────────────────────

    receive() external payable {}
}
