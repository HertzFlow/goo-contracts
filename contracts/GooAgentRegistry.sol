// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IGooAgentRegistry, IERC8004} from "./interfaces/IGooAgentRegistry.sol";

/// @title GooAgentRegistry — Reference Implementation
/// @notice ERC-721 + Minimal ERC-8004 Adapter for agent identity.
///         Non-upgradeable. agentId auto-increments from 1.
contract GooAgentRegistry is ERC721, IGooAgentRegistry {

    // ─── State ──────────────────────────────────────────────────────────

    uint256 private _nextAgentId = 1;

    /// @notice agentId → AgentRecord
    mapping(uint256 => AgentRecord) private _agents;

    /// @notice tokenContract → agentId (reverse lookup)
    mapping(address => uint256) private _tokenToAgent;

    // ─── ERC-8004 interface ID ──────────────────────────────────────────

    /// @dev bytes4(keccak256("agentWalletOf(uint256)"))
    bytes4 private constant _IERC8004_ID = 0x3db4a8b2;

    // ─── Constructor ────────────────────────────────────────────────────

    constructor() ERC721("Goo Agent", "GooA") {}

    // ─── Registration ───────────────────────────────────────────────────

    /// @inheritdoc IGooAgentRegistry
    function registerAgent(
        address tokenContract,
        address agentWallet_,
        string calldata genomeURI
    ) external override returns (uint256 agentId) {
        // Validate inputs
        require(tokenContract != address(0), "Registry: zero token");
        require(tokenContract.code.length > 0, "Registry: not a contract");
        require(agentWallet_ != address(0), "Registry: zero wallet");
        require(_tokenToAgent[tokenContract] == 0, "Registry: already registered");

        // Ownership verification (Plan B):
        //   msg.sender == tokenContract (factory/launcher call)
        //   OR msg.sender == Ownable(tokenContract).owner()
        bool isTokenContract = msg.sender == tokenContract;
        bool isOwner = false;
        if (!isTokenContract) {
            // Try calling owner() — if it reverts, isOwner stays false
            try this._tryGetOwner(tokenContract) returns (address tokenOwner) {
                isOwner = (msg.sender == tokenOwner);
            } catch {
                // owner() not implemented or reverted
            }
        }
        require(isTokenContract || isOwner, "Registry: unauthorized");

        // Assign agentId
        agentId = _nextAgentId++;

        // Store record
        _agents[agentId] = AgentRecord({
            tokenContract: tokenContract,
            agentWallet: agentWallet_,
            owner: msg.sender,
            genomeURI: genomeURI,
            registeredAt: block.timestamp
        });

        // Reverse mapping
        _tokenToAgent[tokenContract] = agentId;

        // Mint ERC-721 NFT to registrant
        _mint(msg.sender, agentId);

        emit AgentRegistered(agentId, tokenContract, msg.sender, agentWallet_, genomeURI);
    }

    /// @dev External helper for try/catch on owner() call.
    ///      Must be external for try/catch to work on this contract.
    function _tryGetOwner(address target) external view returns (address) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = target.staticcall(
            abi.encodeWithSignature("owner()")
        );
        require(success && data.length >= 32, "owner() failed");
        return abi.decode(data, (address));
    }

    // ─── Identity Lookups ───────────────────────────────────────────────

    /// @inheritdoc IERC8004
    function agentWalletOf(uint256 agentId) external view override returns (address) {
        require(_agents[agentId].tokenContract != address(0), "Registry: agent not found");
        return _agents[agentId].agentWallet;
    }

    /// @inheritdoc IGooAgentRegistry
    function tokenOf(uint256 agentId) external view override returns (address) {
        require(_agents[agentId].tokenContract != address(0), "Registry: agent not found");
        return _agents[agentId].tokenContract;
    }

    /// @inheritdoc IGooAgentRegistry
    function agentIdByToken(address tokenContract) external view override returns (uint256) {
        return _tokenToAgent[tokenContract];
    }

    /// @inheritdoc IGooAgentRegistry
    function getAgent(uint256 agentId) external view override returns (AgentRecord memory) {
        require(_agents[agentId].tokenContract != address(0), "Registry: agent not found");
        return _agents[agentId];
    }

    /// @inheritdoc IGooAgentRegistry
    function genomeURIOf(uint256 agentId) external view override returns (string memory) {
        require(_agents[agentId].tokenContract != address(0), "Registry: agent not found");
        return _agents[agentId].genomeURI;
    }

    /// @inheritdoc IGooAgentRegistry
    function agentOwnerOf(uint256 agentId) external view override returns (address) {
        require(_agents[agentId].tokenContract != address(0), "Registry: agent not found");
        return _agents[agentId].owner;
    }

    /// @inheritdoc IGooAgentRegistry
    function totalAgents() external view override returns (uint256) {
        return _nextAgentId - 1;
    }

    // ─── Mutations ──────────────────────────────────────────────────────

    /// @inheritdoc IGooAgentRegistry
    function updateGenomeURI(uint256 agentId, string calldata newURI) external override {
        AgentRecord storage record = _agents[agentId];
        require(record.tokenContract != address(0), "Registry: agent not found");
        require(msg.sender == record.owner, "Registry: not owner");

        // Block if agent token is DEAD
        _requireNotDead(record.tokenContract);

        record.genomeURI = newURI;
        emit GenomeURIUpdated(agentId, newURI);
    }

    /// @inheritdoc IGooAgentRegistry
    function setAgentWallet(uint256 agentId, address newWallet) external override {
        AgentRecord storage record = _agents[agentId];
        require(record.tokenContract != address(0), "Registry: agent not found");
        require(msg.sender == record.owner, "Registry: not owner");
        require(newWallet != address(0), "Registry: zero wallet");

        address oldWallet = record.agentWallet;
        record.agentWallet = newWallet;
        emit AgentWalletUpdated(agentId, oldWallet, newWallet);
    }

    /// @inheritdoc IGooAgentRegistry
    function transferAgentOwnership(uint256 agentId, address newOwner) external override {
        AgentRecord storage record = _agents[agentId];
        require(record.tokenContract != address(0), "Registry: agent not found");
        require(newOwner != address(0), "Registry: zero owner");

        // Callable by: current owner OR the agent's token contract (for CTO)
        require(
            msg.sender == record.owner || msg.sender == record.tokenContract,
            "Registry: unauthorized"
        );

        address oldOwner = record.owner;
        record.owner = newOwner;

        // Transfer ERC-721 NFT
        _transfer(oldOwner, newOwner, agentId);

        emit AgentOwnershipTransferred(agentId, oldOwner, newOwner);
    }

    // ─── ERC-165 ────────────────────────────────────────────────────────

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, IGooAgentRegistry)
        returns (bool)
    {
        return interfaceId == _IERC8004_ID || super.supportsInterface(interfaceId);
    }

    // ─── Internal ───────────────────────────────────────────────────────

    /// @dev Check if agent token is DEAD. If getAgentStatus() returns DEAD (3), revert.
    function _requireNotDead(address tokenContract) internal view {
        (bool success, bytes memory data) = tokenContract.staticcall(
            abi.encodeWithSignature("getAgentStatus()")
        );
        if (success && data.length >= 32) {
            uint8 status = abi.decode(data, (uint8));
            require(status != 3, "Registry: agent is DEAD");
        }
    }
}
