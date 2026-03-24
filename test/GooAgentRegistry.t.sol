// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./TestSetup.sol";
import {IGooAgentRegistry} from "../src/interfaces/IGooAgentRegistry.sol";

contract GooAgentRegistryTest is TestSetup {
    function setUp() public {
        _deployTokenAndRegistry();
    }

    // ─── Registration (caller = token contract) ───────────────────────────

    function test_RegisterAgent_AsTokenContract() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://genome1");
        uint256 agentId = registry.agentIdByToken(address(token));
        assertEq(agentId, 1);
        assertEq(registry.totalAgents(), 1);
        assertEq(registry.tokenOf(agentId), address(token));
        assertEq(registry.agentWalletOf(agentId), agentWallet);
        assertEq(registry.agentOwnerOf(agentId), deployer);
        assertEq(registry.ownerOf(agentId), deployer);
        assertEq(registry.genomeURIOf(agentId), "ipfs://genome1");
    }

    function test_RevertWhen_RegisterAgent_Unauthorized() public {
        vm.prank(user1);
        vm.expectRevert("Registry: unauthorized");
        registry.registerAgent(address(token), agentWallet, "ipfs://genome1");
    }

    function test_RevertWhen_RegisterAgent_AsDeployer_NoOwnerOnToken() public {
        vm.prank(deployer);
        vm.expectRevert("Registry: unauthorized");
        registry.registerAgent(address(token), agentWallet, "ipfs://genome1");
    }

    function test_RevertWhen_RegisterAgent_ZeroToken() public {
        vm.expectRevert("Registry: zero token");
        registry.registerAgent(address(0), agentWallet, "ipfs://x");
    }

    function test_RevertWhen_RegisterAgent_ZeroWallet() public {
        vm.prank(address(token));
        vm.expectRevert("Registry: zero wallet");
        registry.registerAgent(address(token), address(0), "ipfs://x");
    }

    function test_RevertWhen_RegisterAgent_AlreadyRegistered() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://1");
        vm.prank(agentWallet);
        vm.expectRevert("Registry: already registered");
        token.registerInRegistry("ipfs://2");
    }

    // ─── Lookups ──────────────────────────────────────────────────────────

    function test_AgentIdByToken_ReturnsZeroWhenNotRegistered() public view {
        assertEq(registry.agentIdByToken(address(token)), 0);
    }

    function test_GetAgent_FullRecord() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://g");
        uint256 agentId = 1;
        IGooAgentRegistry.AgentRecord memory r = registry.getAgent(agentId);
        assertEq(r.tokenContract, address(token));
        assertEq(r.agentWallet, agentWallet);
        assertEq(r.genomeURI, "ipfs://g");
        assertTrue(r.registeredAt > 0);
    }

    function test_RevertWhen_GetAgent_NotFound() public {
        vm.expectRevert("Registry: agent not found");
        registry.getAgent(1);
    }

    // ─── updateGenomeURI ───────────────────────────────────────────────────

    function test_UpdateGenomeURI_ByOwner() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://old");
        vm.prank(address(token));
        registry.updateGenomeURI(1, "ipfs://new");
        assertEq(registry.genomeURIOf(1), "ipfs://new");
    }

    function test_RevertWhen_UpdateGenomeURI_NotOwner() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://x");
        vm.prank(user1);
        vm.expectRevert("Registry: unauthorized");
        registry.updateGenomeURI(1, "ipfs://y");
    }

    function test_RevertWhen_UpdateGenomeURI_AgentDead() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://x");
        vm.deal(agentWallet, 0);
        vm.deal(address(token), 0);
        token.triggerStarving();
        vm.warp(block.timestamp + STARVING_GRACE_PERIOD + 1);
        token.triggerDying();
        vm.warp(block.timestamp + PULSE_TIMEOUT + 1);
        token.triggerDead();
        vm.prank(address(token));
        vm.expectRevert("Registry: agent is DEAD");
        registry.updateGenomeURI(1, "ipfs://y");
    }

    // ─── setAgentWallet ────────────────────────────────────────────────────

    function test_SetAgentWallet_ByOwner() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://x");
        address newWallet = makeAddr("newWallet");
        vm.prank(address(token));
        registry.setAgentWallet(1, newWallet);
        assertEq(registry.agentWalletOf(1), newWallet);
    }

    function test_RevertWhen_SetAgentWallet_NotOwner() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://x");
        vm.prank(user1);
        vm.expectRevert("Registry: unauthorized");
        registry.setAgentWallet(1, user1);
    }

    function test_RevertWhen_SetAgentWallet_Zero() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://x");
        vm.prank(address(token));
        vm.expectRevert("Registry: zero wallet");
        registry.setAgentWallet(1, address(0));
    }

    // ─── transferAgentOwnership ────────────────────────────────────────────

    function test_TransferAgentOwnership_ByOwner() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://x");
        vm.prank(address(token));
        registry.transferAgentOwnership(1, user1);
        assertEq(registry.agentOwnerOf(1), user1);
        assertEq(registry.ownerOf(1), user1);
    }

    function test_TransferAgentOwnership_ByTokenContract() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://x");
        vm.prank(address(token));
        registry.transferAgentOwnership(1, user1);
        assertEq(registry.agentOwnerOf(1), user1);
    }

    function test_RevertWhen_TransferAgentOwnership_Unauthorized() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://x");
        vm.prank(user2);
        vm.expectRevert("Registry: unauthorized");
        registry.transferAgentOwnership(1, user1);
    }

    function test_RevertWhen_TransferAgentOwnership_ZeroNewOwner() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://x");
        vm.prank(address(token));
        vm.expectRevert("Registry: zero owner");
        registry.transferAgentOwnership(1, address(0));
    }

    // ─── [M03] Direct NFT transfer syncs AgentRecord.owner ──────────────

    function test_RevertWhen_DirectNFTTransfer() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://x");
        uint256 agentId = 1;

        assertEq(registry.agentOwnerOf(agentId), deployer);
        assertEq(registry.ownerOf(agentId), deployer);

        vm.expectRevert("Registry: non-transferable");
        registry.transferFrom(deployer, user1, agentId);
    }

    function test_RevertWhen_DirectSafeTransfer() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://x");
        uint256 agentId = 1;

        vm.expectRevert("Registry: non-transferable");
        registry.safeTransferFrom(deployer, user1, agentId);
    }

    // ─── Events: updateGenomeURI / setAgentWallet / transferAgentOwnership ──

    function test_UpdateGenomeURI_EmitsGenomeURIUpdated() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://old");
        uint256 agentId = registry.agentIdByToken(address(token));

        vm.recordLogs();
        vm.prank(address(token));
        registry.updateGenomeURI(agentId, "ipfs://new");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("GenomeURIUpdated(uint256,string)");

        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter != address(registry)) continue;
            if (entries[i].topics[0] != sig) continue;

            found = true;
            uint256 decodedId = uint256(entries[i].topics[1]);
            string memory uri = abi.decode(entries[i].data, (string));
            assertEq(decodedId, agentId);
            assertEq(uri, "ipfs://new");
        }

        assertTrue(found);
        assertEq(registry.genomeURIOf(agentId), "ipfs://new");
    }

    function test_SetAgentWallet_EmitsAgentWalletUpdated() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://g");
        uint256 agentId = registry.agentIdByToken(address(token));

        address newWallet = makeAddr("newWallet");
        address oldWallet = registry.agentWalletOf(agentId);

        vm.recordLogs();
        vm.prank(address(token));
        registry.setAgentWallet(agentId, newWallet);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("AgentWalletUpdated(uint256,address,address)");

        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter != address(registry)) continue;
            if (entries[i].topics[0] != sig) continue;

            found = true;
            uint256 decodedId = uint256(entries[i].topics[1]);
            address decodedOld = address(uint160(uint256(entries[i].topics[2])));
            address decodedNew = address(uint160(uint256(entries[i].topics[3])));
            assertEq(decodedId, agentId);
            assertEq(decodedOld, oldWallet);
            assertEq(decodedNew, newWallet);
        }

        assertTrue(found);
        assertEq(registry.agentWalletOf(agentId), newWallet);
    }

    function test_TransferAgentOwnership_EmitsAgentOwnershipTransferred() public {
        vm.prank(agentWallet);
        token.registerInRegistry("ipfs://g");
        uint256 agentId = registry.agentIdByToken(address(token));

        address oldOwner = registry.agentOwnerOf(agentId);
        assertEq(oldOwner, deployer);

        vm.recordLogs();
        vm.prank(address(token));
        registry.transferAgentOwnership(agentId, user1);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("AgentOwnershipTransferred(uint256,address,address)");

        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter != address(registry)) continue;
            if (entries[i].topics[0] != sig) continue;

            found = true;
            uint256 decodedId = uint256(entries[i].topics[1]);
            address decodedOld = address(uint160(uint256(entries[i].topics[2])));
            address decodedNew = address(uint160(uint256(entries[i].topics[3])));
            assertEq(decodedId, agentId);
            assertEq(decodedOld, oldOwner);
            assertEq(decodedNew, user1);
        }

        assertTrue(found);
        assertEq(registry.agentOwnerOf(agentId), user1);
        assertEq(registry.ownerOf(agentId), user1);
    }

    // ─── ERC-165 / IERC8004 ───────────────────────────────────────────────

    function test_SupportsInterface_IERC721() public view {
        assertTrue(registry.supportsInterface(0x80ac58cd));
    }

    function test_SupportsInterface_IERC165() public view {
        assertTrue(registry.supportsInterface(0x01ffc9a7));
    }
}
