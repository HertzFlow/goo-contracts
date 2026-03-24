// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./TestSetup.sol";
import {IGooAgentToken} from "../src/interfaces/IGooAgentToken.sol";

/// @title Integration tests: token + registry and lifecycle
contract IntegrationTest is TestSetup {
    function setUp() public {
        _deployTokenAndRegistry();
    }

    function test_FullLifecycle_ActiveToStarvingToDyingToDead() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
        token.triggerStarving();
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.STARVING));
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.DYING));
        vm.warp(block.timestamp + PULSE_TIMEOUT + 1);
        token.triggerDead();
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.DEAD));
    }

    function test_FullLifecycle_RecoveryByDeposit_Starving() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        uint256 thresh = token.starvingThreshold();
        token.depositToTreasury{value: thresh}();
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
    }

    function test_FullLifecycle_RecoveryByDeposit_Dying() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        uint256 thresh = token.starvingThreshold();
        token.depositToTreasury{value: thresh}();
        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
    }

    // CTO integration flow has been removed from the current token contract.

    function test_RegisterThenSurvivalSellThenRecovery() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://g");
        token.transfer(address(token), 200e18);
        vm.prank(agentWallet);
        token.survivalSell(50e18, 0, block.timestamp + 300);
        assertGt(token.treasuryBalance(), 0);
        if (token.treasuryBalance() >= token.starvingThreshold()) {
            assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
        }
    }

    // ─── [M04] Recovery resets _lastPulseAt (integration) ────────────────

    function test_Recovery_Deposit_ResetsLastPulseAt_Integration() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();

        // Warp forward — _lastPulseAt is now stale
        vm.warp(block.timestamp + PULSE_TIMEOUT - 100);
        uint256 recoveryTime = block.timestamp;

        // Deposit to recover
        uint256 thresh = token.starvingThreshold();
        token.depositToTreasury{value: thresh}();

        assertEq(uint256(token.getAgentStatus()), uint256(IGooAgentToken.AgentStatus.ACTIVE));
        assertEq(token.lastPulseAt(), recoveryTime);

        // Now even after PULSE_TIMEOUT, triggerDead should not work (we're ACTIVE, not DYING)
        vm.warp(block.timestamp + PULSE_TIMEOUT + 1);
        vm.expectRevert("Goo: not Dying");
        token.triggerDead();
    }

    function test_Event_StatusChanged() public {
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        vm.recordLogs();
        token.triggerStarving();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertEq(entries[0].topics[0], keccak256("StatusChanged(uint8,uint8,uint256)"));
    }

    function test_Event_TreasuryDeposit() public {
        vm.recordLogs();
        token.depositToTreasury{value: 0.01 ether}();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertGe(entries.length, 1);
        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("TreasuryDeposit(address,uint256,uint256)")) {
                found = true;
                break;
            }
        }
        assertTrue(found);
    }

    function test_Event_PulseEmitted() public {
        vm.recordLogs();
        vm.prank(agentWallet);
        token.emitPulse();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertEq(entries[0].topics[0], keccak256("PulseEmitted(uint256)"));
    }

    // Allow receiving BNB
    receive() external payable {}
}
