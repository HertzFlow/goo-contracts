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

    /// @notice Protocol publisher — controls PROTOCOL_ADMIN on all tokens.
    address public publisher;

    constructor() ERC721("Goo Agent", "GooA") {
        publisher = msg.sender;
    }

    // ─── Registration ───────────────────────────────────────────────────

    /// @inheritdoc IGooAgentRegistry
    function registerAgent(address tokenContract, address agentWallet_, string calldata genomeURI)
        external
        override
        returns (uint256 agentId)
    {
        // Validate inputs
        require(tokenContract != address(0), "Registry: zero token");
        require(tokenContract.code.length > 0, "Registry: not a contract");
        require(agentWallet_ != address(0), "Registry: zero wallet");
        require(_tokenToAgent[tokenContract] == 0, "Registry: already registered");

        require(msg.sender == tokenContract, "Registry: unauthorized");

        address tokenOwner = _getTokenOwner(tokenContract);

        // Assign agentId
        agentId = _nextAgentId++;

        // Store record
        _agents[agentId] = AgentRecord({
            tokenContract: tokenContract,
            agentWallet: agentWallet_,
            owner: tokenOwner,
            genomeURI: genomeURI,
            registeredAt: block.timestamp
        });

        // Reverse mapping
        _tokenToAgent[tokenContract] = agentId;

        // Mint ERC-721 NFT to the current token owner.
        _mint(tokenOwner, agentId);

        emit AgentRegistered(agentId, tokenContract, tokenOwner, agentWallet_, genomeURI);
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
        _requireTokenContract(record.tokenContract);

        // Block if agent token is DEAD
        _requireNotDead(record.tokenContract);

        record.genomeURI = newURI;
        emit GenomeURIUpdated(agentId, newURI);
    }

    /// @inheritdoc IGooAgentRegistry
    function setAgentWallet(uint256 agentId, address newWallet) external override {
        AgentRecord storage record = _agents[agentId];
        require(record.tokenContract != address(0), "Registry: agent not found");
        _requireTokenContract(record.tokenContract);
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
        _requireTokenContract(record.tokenContract);

        // Transfer ERC-721 NFT + sync record.owner.
        _transfer(record.owner, newOwner, agentId);
    }

    // ─── ERC-721 admin surface ─────────────────────────────────────────

    /// @dev agentId NFTs mirror token.owner() and are not user-transferable.
    function approve(address, uint256) public pure override {
        revert("Registry: approvals disabled");
    }

    /// @dev agentId NFTs mirror token.owner() and are not user-transferable.
    function setApprovalForAll(address, bool) public pure override {
        revert("Registry: approvals disabled");
    }

    /// @dev agentId NFTs mirror token.owner() and are not user-transferable.
    function transferFrom(address, address, uint256) public pure override {
        revert("Registry: non-transferable");
    }

    /// @dev agentId NFTs mirror token.owner() and are not user-transferable.
    function safeTransferFrom(address, address, uint256, bytes memory) public pure override {
        revert("Registry: non-transferable");
    }

    // ─── ERC-721 _update override (sync AgentRecord.owner) ─────────────

    /// @dev Sync AgentRecord.owner when the Registry moves the mirror NFT internally.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) {
            _agents[tokenId].owner = to;
            emit AgentOwnershipTransferred(tokenId, from, to);
        }
        return from;
    }

    // ─── ERC-165 ────────────────────────────────────────────────────────

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IGooAgentRegistry) returns (bool) {
        return interfaceId == _IERC8004_ID || super.supportsInterface(interfaceId);
    }

    // ─── Publisher Management ──────────────────────────────────────────

    /// @notice Transfer publisher role (e.g. to multisig). Affects PROTOCOL_ADMIN on all tokens.
    /// @dev Only callable by current publisher.
    function transferPublisher(address newPublisher) external {
        require(msg.sender == publisher, "Registry: not publisher");
        require(newPublisher != address(0), "Registry: zero publisher");
        publisher = newPublisher;
    }

    // ─── Internal ───────────────────────────────────────────────────────

    /// @dev Registry writes must be mediated by the token contract.
    function _requireTokenContract(address tokenContract) internal view {
        require(msg.sender == tokenContract, "Registry: unauthorized");
    }

    /// @dev Read owner() from token contract. Used to mint/sync the registry mirror.
    function _getTokenOwner(address tokenContract) internal view returns (address) {
        (bool success, bytes memory data) = tokenContract.staticcall(abi.encodeWithSignature("owner()"));
        require(success && data.length >= 32, "Registry: owner() call failed");
        return abi.decode(data, (address));
    }

    /// @dev Check if agent token is DEAD. If getAgentStatus() returns DEAD (3), revert.
    function _requireNotDead(address tokenContract) internal view {
        (bool success, bytes memory data) = tokenContract.staticcall(abi.encodeWithSignature("getAgentStatus()"));
        if (success && data.length >= 32) {
            uint8 status = abi.decode(data, (uint8));
            require(status != 3, "Registry: agent is DEAD");
        }
    }
}
