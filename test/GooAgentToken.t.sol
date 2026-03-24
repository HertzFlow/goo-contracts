// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./TestSetup.sol";
import {IGooAgentToken} from "../src/interfaces/IGooAgentToken.sol";

contract GooAgentTokenTest is TestSetup {
    function setUp() public {
        _deployTokenAndRegistry();
    }

    // ─── Constructor & initial state ─────────────────────────────────────

    function test_InitialStatus_Active() public view {
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
    }

    function test_InitialSupply_FullCirculation() public view {
        // CIRCULATION_BPS = 10000 (100%), no burn
        uint256 treasuryTokens = 1_000_000_000e18 * 500 / 10_000; // TREASURY_TOKEN_BPS = 500
        uint256 lpTokens = 1_000_000_000e18 - treasuryTokens;
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(agentWallet), treasuryTokens);
        assertEq(token.balanceOf(deployer), lpTokens);
    }

    function test_StarvingThreshold_Formula() public view {
        assertEq(token.starvingThreshold(), 0.015 ether);
    }

    function test_RevertWhen_ZeroAgentWallet() public {
        vm.expectRevert("Goo: zero agentWallet");
        new GooAgentToken(
            "G", "G",
            address(0),
            address(swapExecutor),
            address(registry),
            STARVING_GRACE_PERIOD, DYING_MAX_DURATION,
            PULSE_TIMEOUT, SURVIVAL_SELL_COOLDOWN,
            MAX_SELL_BPS, MIN_CTO_AMOUNT, FEE_RATE_BPS,
            CIRCULATION_BPS
        );
    }

    function test_RevertWhen_ZeroSwapExecutor() public {
        vm.expectRevert("Goo: zero swapExecutor");
        new GooAgentToken(
            "G", "G",
            agentWallet,
            address(0),
            address(registry),
            STARVING_GRACE_PERIOD, DYING_MAX_DURATION,
            PULSE_TIMEOUT, SURVIVAL_SELL_COOLDOWN,
            MAX_SELL_BPS, MIN_CTO_AMOUNT, FEE_RATE_BPS,
            CIRCULATION_BPS
        );
    }

    function test_RevertWhen_InvalidMaxSellBps() public {
        vm.expectRevert("Goo: invalid maxSellBps");
        new GooAgentToken(
            "G", "G",
            agentWallet,
            address(swapExecutor),
            address(registry),
            STARVING_GRACE_PERIOD, DYING_MAX_DURATION,
            PULSE_TIMEOUT, SURVIVAL_SELL_COOLDOWN,
            0, MIN_CTO_AMOUNT, FEE_RATE_BPS,
            CIRCULATION_BPS
        );
    }

    // ─── Lifecycle: ACTIVE → STARVING ─────────────────────────────────────

    function test_TriggerStarving_WhenBalanceBelowThreshold() public {
        // Drain treasury: agent wallet has the 1 BNB from constructor, we need to empty it
        // treasuryBalance = contract.balance + agentWallet.balance
        // We need both to be below threshold
        // Set agent wallet balance to 0 and contract balance to 0
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        assertTrue(token.treasuryBalance() < token.starvingThreshold());
        token.triggerStarving();
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.STARVING));
        assertTrue(token.starvingEnteredAt() > 0);
    }

    function test_RevertWhen_TriggerStarving_NotActive() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.expectRevert("Goo: not ACTIVE");
        token.triggerStarving();
    }

    function test_RevertWhen_TriggerStarving_BalanceAboveThreshold() public {
        // Treasury already funded from constructor
        vm.expectRevert("Goo: balance above threshold");
        token.triggerStarving();
    }

    // ─── Lifecycle: STARVING → ACTIVE (Recovery: deposit) ─────────────────

    function test_Recovery_Deposit_StarvingToActive() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        uint256 thresh = token.starvingThreshold();
        token.depositToTreasury{value: thresh}();
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
        assertEq(token.starvingEnteredAt(), 0);
    }

    // ─── Lifecycle: STARVING → DYING ─────────────────────────────────────

    function test_TriggerDying_AfterGracePeriod() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.DYING));
        assertTrue(token.dyingEnteredAt() > 0);
    }

    function test_RevertWhen_TriggerDying_NotStarving() public {
        vm.expectRevert("Goo: not Starving");
        token.triggerDying();
    }

    function test_RevertWhen_TriggerDying_GraceNotElapsed() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.expectRevert("Goo: STARVING_GRACE_PERIOD not elapsed");
        token.triggerDying();
    }

    // ─── Lifecycle: DYING → DEAD (triggerDead) ───────────────────────────

    function test_TriggerDead_WhenPulseTimeout() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        vm.warp(block.timestamp + PULSE_TIMEOUT + 1);
        token.triggerDead();
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.DEAD));
    }

    function test_TriggerDead_WhenDyingMaxDuration() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        vm.warp(block.timestamp + DYING_MAX_DURATION + 1);
        token.triggerDead();
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.DEAD));
    }

    function test_RevertWhen_TriggerDead_NotDying() public {
        vm.expectRevert("Goo: not Dying");
        token.triggerDead();
    }

    function test_RevertWhen_TriggerDead_FromStarving() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.expectRevert("Goo: not Dying");
        token.triggerDead();
    }

    function test_RevertWhen_TriggerDead_NotEligibleYet() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        vm.expectRevert("Goo: not eligible for DEAD");
        token.triggerDead();
    }

    // ─── Lifecycle: triggerRecovery ───────────────────────────────────────

    function test_TriggerRecovery_FromStarving() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.STARVING));

        // Fund treasury above threshold
        vm.deal(address(token), token.starvingThreshold());
        token.triggerRecovery();
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
        assertEq(token.starvingEnteredAt(), 0);
        assertEq(token.dyingEnteredAt(), 0);
        assertEq(token.lastPulseAt(), block.timestamp);
    }

    function test_TriggerRecovery_FromDying() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.DYING));

        // Fund treasury above threshold
        vm.deal(address(token), token.starvingThreshold());
        token.triggerRecovery();
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
        assertEq(token.starvingEnteredAt(), 0);
        assertEq(token.dyingEnteredAt(), 0);
    }

    function test_RevertWhen_TriggerRecovery_NotStarvingOrDying() public {
        vm.expectRevert("Goo: not Starving or Dying");
        token.triggerRecovery();
    }

    function test_RevertWhen_TriggerRecovery_BalanceBelowThreshold() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.expectRevert("Goo: balance below threshold");
        token.triggerRecovery();
    }

    function test_TriggerRecovery_EmitsStatusChanged() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();

        vm.deal(address(token), token.starvingThreshold());
        uint256 ts = block.timestamp;

        vm.expectEmit(true, true, false, true, address(token));
        emit IGooAgentToken.StatusChanged(
            IGooAgentToken.AgentStatus.STARVING,
            IGooAgentToken.AgentStatus.ACTIVE,
            ts
        );
        token.triggerRecovery();
    }

    // ─── Lifecycle: triggerLifecycle (unified) ──────────────────────────

    function test_TriggerLifecycle_Recovery() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        // Fund above threshold
        vm.deal(address(token), token.starvingThreshold());
        uint8 action = token.triggerLifecycle();
        assertEq(action, 1); // recovery
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
    }

    function test_TriggerLifecycle_Starving() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        uint8 action = token.triggerLifecycle();
        assertEq(action, 2); // starving
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.STARVING));
    }

    function test_TriggerLifecycle_Dying() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        uint8 action = token.triggerLifecycle();
        assertEq(action, 3); // dying
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.DYING));
    }

    function test_TriggerLifecycle_Dead() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        vm.warp(block.timestamp + PULSE_TIMEOUT + 1);
        uint8 action = token.triggerLifecycle();
        assertEq(action, 4); // dead
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.DEAD));
    }

    function test_TriggerLifecycle_NoOp_WhenHealthy() public {
        // Treasury funded from constructor, ACTIVE and healthy
        uint8 action = token.triggerLifecycle();
        assertEq(action, 0); // no-op
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
    }

    function test_TriggerLifecycle_NoOp_WhenDead() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        vm.warp(block.timestamp + PULSE_TIMEOUT + 1);
        token.triggerDead();
        uint8 action = token.triggerLifecycle();
        assertEq(action, 0); // no-op, already dead
    }

    function test_TriggerLifecycle_RecoveryPrioritizedOverDying() public {
        // STARVING + grace period elapsed BUT balance is healthy → recovery wins
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        // Fund above threshold
        vm.deal(address(token), token.starvingThreshold());
        uint8 action = token.triggerLifecycle();
        assertEq(action, 1); // recovery, not dying
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
    }

    // ─── Treasury ────────────────────────────────────────────────────────

    function test_DepositToTreasury_AnyCaller() public {
        uint256 amount = 1 ether;
        uint256 balBefore = token.treasuryBalance();
        vm.prank(user1);
        token.depositToTreasury{value: amount}();
        assertEq(token.treasuryBalance(), balBefore + amount);
    }

    function test_RevertWhen_DepositToTreasury_ZeroAmount() public {
        vm.expectRevert("Goo: zero amount");
        token.depositToTreasury{value: 0}();
    }

    function test_RevertWhen_DepositToTreasury_WhenDead() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        vm.warp(block.timestamp + PULSE_TIMEOUT + 1);
        token.triggerDead();
        vm.expectRevert("Goo: agent is DEAD");
        token.depositToTreasury{value: 1 ether}();
    }

    function test_Recovery_Deposit_DyingToActive() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        uint256 thresh = token.starvingThreshold();
        token.depositToTreasury{value: thresh}();
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
    }

    // ─── Treasury: withdrawToWallet ──────────────────────────────────────

    function test_WithdrawToWallet_Success() public {
        // Treasury is funded (1 BNB from constructor in agentWallet)
        // Deposit more to contract directly
        vm.deal(address(token), 2 ether);
        uint256 withdrawAmt = 0.5 ether;
        uint256 walletBefore = agentWallet.balance;

        vm.prank(agentWallet);
        token.withdrawToWallet(withdrawAmt);

        assertEq(agentWallet.balance, walletBefore + withdrawAmt);
    }

    function test_WithdrawToWallet_RevertWhen_NotAgentWallet() public {
        vm.deal(address(token), 2 ether);
        vm.prank(user1);
        vm.expectRevert("Goo: not agentWallet");
        token.withdrawToWallet(0.1 ether);
    }

    function test_WithdrawToWallet_RevertWhen_Dead() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        vm.warp(block.timestamp + PULSE_TIMEOUT + 1);
        token.triggerDead();

        vm.prank(agentWallet);
        vm.expectRevert("Goo: agent is DEAD");
        token.withdrawToWallet(1);
    }

    function test_WithdrawToWallet_RevertWhen_ZeroAmount() public {
        vm.deal(address(token), 2 ether);
        vm.prank(agentWallet);
        vm.expectRevert("Goo: zero amount");
        token.withdrawToWallet(0);
    }

    function test_WithdrawToWallet_RevertWhen_WouldStarve() public {
        // treasuryBalance = contract.balance + wallet.balance
        // Set total below threshold, then try to withdraw
        uint256 thresh = token.starvingThreshold();
        vm.deal(agentWallet, 0);
        vm.deal(address(token), thresh - 1); // total below threshold

        vm.prank(agentWallet);
        vm.expectRevert("Goo: would starve");
        token.withdrawToWallet(1);
    }

    function test_WithdrawToWallet_RevertWhen_InsufficientBalance() public {
        // Contract has 0 balance, wallet has all the BNB
        vm.deal(address(token), 0);
        vm.prank(agentWallet);
        vm.expectRevert("Goo: insufficient balance");
        token.withdrawToWallet(1 ether);
    }

    function test_WithdrawToWallet_EmitsTreasuryWithdraw() public {
        vm.deal(address(token), 2 ether);
        uint256 withdrawAmt = 0.5 ether;
        // After withdraw: contract has 1.5 BNB, wallet gets +0.5 BNB
        // treasuryBalance = contract.balance + wallet.balance (post-transfer)
        uint256 expectedNewBalance = address(token).balance - withdrawAmt + agentWallet.balance + withdrawAmt;

        vm.prank(agentWallet);
        vm.expectEmit(true, false, false, true, address(token));
        emit IGooAgentToken.TreasuryWithdraw(agentWallet, withdrawAmt, expectedNewBalance);
        token.withdrawToWallet(withdrawAmt);
    }

    // ─── [M06] WithdrawToWallet checks contract balance ─────────────────

    function test_WithdrawToWallet_ChecksContractBalance() public {
        // M06: treasuryBalance includes agent wallet balance, but we can only
        // withdraw from contract balance. Ensure we check address(this).balance.
        vm.deal(address(token), 0.001 ether);
        vm.deal(agentWallet, 100 ether); // wallet has plenty, but contract doesn't

        vm.prank(agentWallet);
        vm.expectRevert("Goo: insufficient balance");
        token.withdrawToWallet(1 ether);
    }

    // ─── Survival: emitPulse ──────────────────────────────────────────────

    function test_EmitPulse_OnlyAgentWallet() public {
        vm.prank(agentWallet);
        token.emitPulse();
        assertEq(token.lastPulseAt(), block.timestamp);
    }

    function test_RevertWhen_EmitPulse_NotAgentWallet() public {
        vm.prank(user1);
        vm.expectRevert("Goo: not agentWallet");
        token.emitPulse();
    }

    function test_RevertWhen_EmitPulse_WhenDead() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        vm.warp(block.timestamp + PULSE_TIMEOUT + 1);
        token.triggerDead();
        vm.prank(agentWallet);
        vm.expectRevert("Goo: agent is DEAD");
        token.emitPulse();
    }

    // ─── Survival: survivalSell ───────────────────────────────────────────

    function test_SurvivalSell_AgentWallet_Success() public {
        // Transfer tokens to token contract for selling
        uint256 toSell = 50e18;
        token.transfer(address(token), 200e18);
        uint256 bnbBefore = address(token).balance;
        vm.prank(agentWallet);
        token.survivalSell(toSell, 0, block.timestamp + 300);
        assertGt(address(token).balance, bnbBefore);
    }

    function test_RevertWhen_SurvivalSell_NotAgentWallet() public {
        token.transfer(address(token), 100e18);
        vm.prank(user1);
        vm.expectRevert("Goo: not agentWallet");
        token.survivalSell(100e18, 0, block.timestamp + 300);
    }

    function test_RevertWhen_SurvivalSell_ExceedsMaxSellBps() public {
        token.transfer(address(token), 1000e18);
        uint256 maxAllowed = 1000e18 * MAX_SELL_BPS / 10000;
        vm.prank(agentWallet);
        vm.expectRevert("Goo: exceeds maxSellBps");
        token.survivalSell(maxAllowed + 1, 0, block.timestamp + 300);
    }

    function test_RevertWhen_SurvivalSell_CooldownActive() public {
        token.transfer(address(token), 100e18);
        vm.prank(agentWallet);
        token.survivalSell(25e18, 0, block.timestamp + 300);
        vm.prank(agentWallet);
        vm.expectRevert("Goo: cooldown active");
        token.survivalSell(25e18, 0, block.timestamp + 300);
    }

    function test_SurvivalSell_AfterCooldown() public {
        token.transfer(address(token), 200e18);
        vm.prank(agentWallet);
        token.survivalSell(99e18, 0, block.timestamp + 300);
        vm.warp(block.timestamp + SURVIVAL_SELL_COOLDOWN + 1);
        vm.prank(agentWallet);
        token.survivalSell(49e18, 0, block.timestamp + 300);
    }

    // ─── CTO (Recovery: Successor) ───────────────────────────────────────

    function test_ClaimCTO_RequiresRegistered() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        vm.prank(user1);
        token.claimCTO{value: MIN_CTO_AMOUNT}();
        assertEq(token.owner(), user1);
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
    }

    function test_RevertWhen_ClaimCTO_NotDying() public {
        vm.prank(user1);
        vm.expectRevert("Goo: not Dying");
        token.claimCTO{value: MIN_CTO_AMOUNT}();
    }

    function test_RevertWhen_ClaimCTO_BelowMinAmount() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        vm.prank(user1);
        vm.expectRevert("Goo: below minCtoAmount");
        token.claimCTO{value: MIN_CTO_AMOUNT - 1}();
    }

    // ─── CTO keeps AGENT_WALLET unchanged ───────────────────────────────

    function test_ClaimCTO_KeepsAgentWallet() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://genome");

        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();

        address oldWallet = token.agentWallet();
        assertEq(oldWallet, agentWallet);

        vm.prank(user1);
        token.claimCTO{value: MIN_CTO_AMOUNT}();

        assertEq(token.owner(), user1);
        assertEq(token.agentWallet(), agentWallet);
        assertEq(token.AGENT_WALLET(), agentWallet);
    }

    // ─── [M04] Recovery resets _lastPulseAt ──────────────────────────────

    function test_Recovery_Deposit_ResetsLastPulseAt() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();

        // Warp forward so _lastPulseAt is stale
        vm.warp(block.timestamp + 1000);
        uint256 recoveryTime = block.timestamp;

        uint256 thresh = token.starvingThreshold();
        token.depositToTreasury{value: thresh}();

        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
        assertEq(token.lastPulseAt(), recoveryTime);
    }

    function test_Recovery_SurvivalSell_ResetsLastPulseAt() public {
        // Put tokens in contract for selling
        token.transfer(address(token), 1000e18);

        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();

        // Warp forward so _lastPulseAt is stale
        vm.warp(block.timestamp + 1000);
        uint256 recoveryTime = block.timestamp;

        // survivalSell should bring in BNB and trigger recovery
        vm.prank(agentWallet);
        token.survivalSell(100e18, 0, block.timestamp + 300);

        // If recovery happened, lastPulseAt should be reset
        if (uint256(token.getAgentStatus()) == uint256(IGooAgentToken.AgentStatus.ACTIVE)) {
            assertEq(token.lastPulseAt(), recoveryTime);
        }
    }

    // ─── [M07] Proxy functions for registry mutations ────────────────────

    function test_ProxyUpdateGenomeURI() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://old");
        uint256 agentId = registry.agentIdByToken(address(token));

        vm.prank(deployer);
        token.updateGenomeURI(agentId, "ipfs://new");
        assertEq(registry.genomeURIOf(agentId), "ipfs://new");
    }

    function test_ProxyUpdateGenomeURI_RevertWhen_NotAgentWallet() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://old");
        uint256 agentId = registry.agentIdByToken(address(token));

        vm.prank(user1);
        vm.expectRevert("Goo: not owner");
        token.updateGenomeURI(agentId, "ipfs://new");
    }

    function test_ProxySetRegistryAgentWallet() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://g");
        uint256 agentId = registry.agentIdByToken(address(token));

        address newWallet = makeAddr("newWallet");
        token.setAgentWallet(newWallet);
        vm.prank(deployer);
        token.setRegistryAgentWallet(agentId, newWallet);
        assertEq(registry.agentWalletOf(agentId), newWallet);
    }

    function test_ProxySetRegistryAgentWallet_RevertWhen_NotAgentWallet() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://g");
        uint256 agentId = registry.agentIdByToken(address(token));

        vm.prank(user1);
        vm.expectRevert("Goo: not owner");
        token.setRegistryAgentWallet(agentId, user1);
    }

    function test_ProxyTransferRegistryOwnership() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://g");
        uint256 agentId = registry.agentIdByToken(address(token));

        assertEq(registry.agentOwnerOf(agentId), deployer);

        token.transferOwnership(user1);
        vm.prank(user1);
        token.transferRegistryOwnership(agentId, user1);
        assertEq(registry.agentOwnerOf(agentId), user1);
    }

    function test_ProxyTransferRegistryOwnership_RevertWhen_NotAgentWallet() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://g");
        uint256 agentId = registry.agentIdByToken(address(token));

        vm.prank(user1);
        vm.expectRevert("Goo: not owner");
        token.transferRegistryOwnership(agentId, user1);
    }

    // ─── Fee-on-Transfer ─────────────────────────────────────────────────

    function test_FeeOnTransfer_DeductsFee() public {
        uint256 amount = 100e18;
        uint256 expectedFee = amount * FEE_RATE_BPS / 10000;
        uint256 expectedNet = amount - expectedFee;
        uint256 deployerBefore = token.balanceOf(deployer);
        token.transfer(user1, amount);
        assertEq(token.balanceOf(user1), expectedNet);
        assertEq(token.balanceOf(deployer), deployerBefore - expectedNet);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_FeeRate_ZeroWhenDead() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        vm.warp(block.timestamp + PULSE_TIMEOUT + 1);
        token.triggerDead();
        assertEq(token.feeRate(), 0);
    }

    // ─── Read-only / immutables ───────────────────────────────────────────

    function test_View_AgentWallet() public view {
        assertEq(token.agentWallet(), agentWallet);
    }

    function test_View_ProtocolParams() public view {
        assertEq(token.starvingThreshold(), 0.015 ether);
        assertEq(token.dyingThreshold(), 0); // deprecated, returns 0
        assertEq(token.DYING_MAX_DURATION(), DYING_MAX_DURATION);
        assertEq(token.STARVING_GRACE_PERIOD(), STARVING_GRACE_PERIOD);
        assertEq(token.DYING_MAX_DURATION(), DYING_MAX_DURATION);
        assertEq(token.PULSE_TIMEOUT(), PULSE_TIMEOUT);
        assertEq(token.SURVIVAL_SELL_COOLDOWN(), SURVIVAL_SELL_COOLDOWN);
        assertEq(token.maxSellBps(), MAX_SELL_BPS);
        assertEq(token.minCtoAmount(), MIN_CTO_AMOUNT);
        assertEq(token.feeRate(), FEE_RATE_BPS);
        assertEq(token.circulationBps(), CIRCULATION_BPS);
    }

    // ─── Constructor: BNB forwarding ────────────────────────────────────

    function test_Constructor_ForwardsBNB() public {
        vm.deal(address(this), 2 ether);
        uint256 walletBefore = agentWallet.balance;
        new GooAgentToken{value: 0.5 ether}(
            "G", "G",
            agentWallet, address(swapExecutor), address(registry),
            STARVING_GRACE_PERIOD, DYING_MAX_DURATION,
            PULSE_TIMEOUT, SURVIVAL_SELL_COOLDOWN,
            MAX_SELL_BPS, MIN_CTO_AMOUNT, FEE_RATE_BPS,
            CIRCULATION_BPS
        );
        assertEq(agentWallet.balance, walletBefore + 0.5 ether);
    }

    function test_Constructor_ZeroBNB() public {
        GooAgentToken t = new GooAgentToken(
            "G", "G",
            agentWallet, address(swapExecutor), address(registry),
            STARVING_GRACE_PERIOD, DYING_MAX_DURATION,
            PULSE_TIMEOUT, SURVIVAL_SELL_COOLDOWN,
            MAX_SELL_BPS, MIN_CTO_AMOUNT, FEE_RATE_BPS,
            CIRCULATION_BPS
        );
        assertEq(uint256(t.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
    }

    function test_Constructor_BurnAtDeploy() public {
        // Deploy with 50% circulation → 50% burned
        GooAgentToken t = new GooAgentToken(
            "G", "G",
            agentWallet, address(swapExecutor), address(registry),
            STARVING_GRACE_PERIOD, DYING_MAX_DURATION,
            PULSE_TIMEOUT, SURVIVAL_SELL_COOLDOWN,
            MAX_SELL_BPS, MIN_CTO_AMOUNT, FEE_RATE_BPS,
            5000 // 50% circulation
        );
        // totalSupply should be 50% of 1B (burned tokens reduce totalSupply)
        assertEq(t.totalSupply(), 500_000_000e18);
    }

    // ─── Events: TreasuryDeposit / StatusChanged ──────────────────────────

    function test_DepositToTreasury_EmitsTreasuryDeposit() public {
        uint256 amount = 0.01 ether;
        uint256 preBalance = token.treasuryBalance();

        vm.expectEmit(true, false, false, true, address(token));
        emit IGooAgentToken.TreasuryDeposit(deployer, amount, preBalance + amount);

        token.depositToTreasury{value: amount}();
    }

    function test_Recovery_DepositToTreasury_EmitsStatusChangedAndTreasuryDeposit() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();

        uint256 amount = token.starvingThreshold();
        uint256 preBalance = token.treasuryBalance(); // 0 in this setup
        uint256 ts = block.timestamp;

        // Recovery path emits StatusChanged first, then TreasuryDeposit.
        vm.expectEmit(true, true, false, true, address(token));
        emit IGooAgentToken.StatusChanged(
            IGooAgentToken.AgentStatus.STARVING,
            IGooAgentToken.AgentStatus.ACTIVE,
            ts
        );

        vm.expectEmit(true, false, false, true, address(token));
        emit IGooAgentToken.TreasuryDeposit(deployer, amount, preBalance + amount);

        token.depositToTreasury{value: amount}();

        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
        assertEq(token.lastPulseAt(), ts);
    }

    // ─── Events: PulseEmitted ─────────────────────────────────────────────

    function test_EmitPulse_EmitsPulseEmitted() public {
        vm.warp(block.timestamp + 123);
        uint256 ts = block.timestamp;

        vm.prank(agentWallet);
        vm.expectEmit(false, false, false, true, address(token));
        emit IGooAgentToken.PulseEmitted(ts);

        token.emitPulse();
        assertEq(token.lastPulseAt(), ts);
    }

    // ─── Events: SurvivalSellExecuted ─────────────────────────────────────

    function test_SurvivalSell_EmitsSurvivalSellExecuted() public {
        uint256 holdings = 200e18;
        uint256 tokenAmount = 50e18; // must be <= holdings * MAX_SELL_BPS / 10000
        token.transfer(address(token), holdings);

        uint256 treasuryBefore = token.treasuryBalance();
        uint256 nativeReceivedExpected = tokenAmount * swapExecutor.rate() / 1e18;
        uint256 newTreasuryExpected = treasuryBefore + nativeReceivedExpected;

        vm.prank(agentWallet);
        vm.expectEmit(false, false, false, true, address(token));
        emit IGooAgentToken.SurvivalSellExecuted(tokenAmount, nativeReceivedExpected, newTreasuryExpected);

        token.survivalSell(tokenAmount, 0, block.timestamp + 300);
        assertEq(token.treasuryBalance(), newTreasuryExpected);
    }

    function test_RevertWhen_SurvivalSell_ZeroTokenAmount() public {
        vm.prank(agentWallet);
        vm.expectRevert("Goo: zero amount");
        token.survivalSell(0, 0, block.timestamp + 300);
    }

    function test_RevertWhen_SurvivalSell_WhenDead() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        vm.warp(block.timestamp + PULSE_TIMEOUT + 1);
        token.triggerDead();

        vm.prank(agentWallet);
        vm.expectRevert("Goo: agent is DEAD");
        token.survivalSell(1e18, 0, block.timestamp + 300);
    }

    // ─── Events: CTOClaimed / OwnershipTransferred / StatusChanged ───────

    function test_ClaimCTO_EmitsCTOClaimedAndStatusChangedAndOwnershipTransferred() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://genome");

        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();

        uint256 ts = block.timestamp;

        vm.recordLogs();
        vm.prank(user1);
        token.claimCTO{value: MIN_CTO_AMOUNT}();

        Vm.Log[] memory entries = vm.getRecordedLogs();

        bool foundCTO;
        bool foundStatus;
        bool foundOwnershipTransferred;

        bytes32 ctoSig = keccak256("CTOClaimed(address,uint256,uint256)");
        bytes32 statusSig = keccak256("StatusChanged(uint8,uint8,uint256)");
        bytes32 ownershipTransferredSig = keccak256("OwnershipTransferred(address,address)");

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter != address(token)) continue;

            if (entries[i].topics[0] == ctoSig) {
                foundCTO = true;
                address newOwner = address(uint160(uint256(entries[i].topics[1])));
                (uint256 creditAmount, uint256 eventTs) = abi.decode(entries[i].data, (uint256, uint256));
                assertEq(newOwner, user1);
                assertEq(creditAmount, MIN_CTO_AMOUNT);
                assertEq(eventTs, ts);
            } else if (entries[i].topics[0] == statusSig) {
                foundStatus = true;
                uint8 oldStatus = uint8(uint256(entries[i].topics[1]));
                uint8 newStatus = uint8(uint256(entries[i].topics[2]));
                uint256 eventTs = abi.decode(entries[i].data, (uint256));
                assertEq(oldStatus, uint8(IGooAgentToken.AgentStatus.DYING));
                assertEq(newStatus, uint8(IGooAgentToken.AgentStatus.ACTIVE));
                assertEq(eventTs, ts);
            } else if (entries[i].topics[0] == ownershipTransferredSig) {
                foundOwnershipTransferred = true;
                address oldOwner = address(uint160(uint256(entries[i].topics[1])));
                address newOwner = address(uint160(uint256(entries[i].topics[2])));
                assertEq(oldOwner, deployer);
                assertEq(newOwner, user1);
            }
        }

        assertTrue(foundCTO);
        assertTrue(foundStatus);
        assertTrue(foundOwnershipTransferred);
        assertEq(token.agentWallet(), agentWallet);
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
    }

    // ─── Events: SwapExecutorUpdated ──────────────────────────────────────

    function test_SetSwapExecutor_EmitsSwapExecutorUpdated() public {
        address oldExecutor = token.swapExecutor();
        address newExecutor = makeAddr("newExecutor");

        vm.prank(deployer);
        vm.expectEmit(true, true, false, false, address(token));
        emit IGooAgentToken.SwapExecutorUpdated(oldExecutor, newExecutor);

        token.setSwapExecutor(newExecutor);
        assertEq(token.swapExecutor(), newExecutor);
    }

    function test_RevertWhen_SetSwapExecutor_NotAgentWallet() public {
        address newExecutor = makeAddr("newExecutor");
        vm.prank(user1);
        vm.expectRevert("Goo: not protocolAdmin");
        token.setSwapExecutor(newExecutor);
    }

    function test_RevertWhen_SetSwapExecutor_ZeroExecutor() public {
        vm.prank(deployer);
        vm.expectRevert("Goo: zero swapExecutor");
        token.setSwapExecutor(address(0));
    }

    // Allow receiving BNB for withdraw tests
    receive() external payable {}
}
