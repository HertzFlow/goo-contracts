// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/interfaces/IERC165.sol";

/// @title IERC8004 — Minimal ERC-8004 Agent Wallet Binding
/// @notice Minimal adapter interface for ERC-8004 agent identity standard.
/// @dev Goo implements a Minimal ERC-8004 Adapter — exposing agentWalletOf()
///      and declaring support via ERC-165. ERC-8004 is in Draft status;
///      Goo will track the standard as it evolves.
///      See: https://eips.ethereum.org/EIPS/eip-8004
interface IERC8004 {
    /// @notice Returns the wallet address bound to an agent.
    /// @param agentId The unique agent identifier (ERC-721 tokenId).
    /// @return The agent's wallet address.
    function agentWalletOf(uint256 agentId) external view returns (address);
}

/// @title IGooAgentRegistry — Goo Agent Registry Interface (v1.0)
/// @notice ERC-721 + Minimal ERC-8004 Adapter for agent identity.
///         Binds agentId ↔ tokenContract ↔ agentWallet ↔ genomeURI.
///
/// @dev Design decisions:
///   - uint256 agentId (auto-increment) — simpler, ERC-721 compatible
///   - Ownership-verified registration — caller must prove token control:
///     msg.sender == tokenContract (factory) OR msg.sender == token.owner() (deployer)
///   - Token address = Agent identity (primary); agentId NFT = ERC-8004 adapter
///   - ERC-165 supportsInterface declares IERC721 + IERC8004 support
interface IGooAgentRegistry is IERC8004, IERC165 {
    // ─── Structs ──────────────────────────────────────────────────────────

    struct AgentRecord {
        address tokenContract; // The agent's ERC-20 token (IGooAgentToken)
        address agentWallet; // Runtime wallet address
        address owner; // Current owner (creator initially)
        string genomeURI; // IPFS hash or URI for agent genome/config
        uint256 registeredAt; // block.timestamp of registration
    }

    // ─── Registration ─────────────────────────────────────────────────────

    /// @notice Register a new agent. Mints an ERC-721 agentId to msg.sender.
    /// @dev Ownership-verified — caller must prove control over tokenContract:
    ///   - msg.sender == tokenContract (for factory/launch contracts), OR
    ///   - msg.sender == Ownable(tokenContract).owner() (for individual deployers)
    ///   Additional requirements:
    ///   - tokenContract must be a non-zero contract address
    ///   - tokenContract must not already be registered
    ///   - agentWallet must be a non-zero address
    /// @param tokenContract The agent's ERC-20 token contract address
    /// @param agentWallet   The agent's runtime wallet address
    /// @param genomeURI     IPFS hash or URI pointing to agent genome/config
    /// @return agentId      Auto-incremented unique identifier (ERC-721 tokenId)
    function registerAgent(address tokenContract, address agentWallet, string calldata genomeURI)
        external
        returns (uint256 agentId);

    // ─── Identity Lookups ─────────────────────────────────────────────────

    /// @notice ERC-8004 standard — returns agent's wallet address.
    /// @param agentId The agent identifier
    /// @return The agent wallet address
    function agentWalletOf(uint256 agentId) external view override returns (address);

    /// @notice Returns the agent's ERC-20 token contract address.
    /// @param agentId The agent identifier
    /// @return The token contract address
    function tokenOf(uint256 agentId) external view returns (address);

    /// @notice Reverse lookup — token contract address → agentId.
    /// @dev Returns 0 if not registered.
    /// @param tokenContract The token contract address
    /// @return The agentId (0 = not found)
    function agentIdByToken(address tokenContract) external view returns (uint256);

    /// @notice Returns the full agent record.
    /// @param agentId The agent identifier
    /// @return record The complete AgentRecord struct
    function getAgent(uint256 agentId) external view returns (AgentRecord memory record);

    /// @notice Returns the genome URI for an agent.
    /// @param agentId The agent identifier
    /// @return The genome URI string
    function genomeURIOf(uint256 agentId) external view returns (string memory);

    /// @notice Returns the current owner of an agent.
    /// @param agentId The agent identifier
    /// @return The owner address
    function agentOwnerOf(uint256 agentId) external view returns (address);

    /// @notice Returns the total number of registered agents.
    /// @return The total agent count
    function totalAgents() external view returns (uint256);

    // ─── ERC-165 ──────────────────────────────────────────────────────────

    /// @notice ERC-165 interface detection.
    /// @dev Returns true for: IERC721, IERC8004, IERC165
    function supportsInterface(bytes4 interfaceId) external view override returns (bool);

    // ─── Mutations ────────────────────────────────────────────────────────

    /// @notice Update the genome URI. Blocked if agent token status is DEAD.
    /// @dev Only callable by agent owner (agentOwnerOf(agentId) == msg.sender).
    /// @param agentId The agent identifier
    /// @param newURI  New IPFS hash or URI
    function updateGenomeURI(uint256 agentId, string calldata newURI) external;

    /// @notice Update the agent wallet address.
    /// @dev Only callable by agent owner.
    /// @param agentId   The agent identifier
    /// @param newWallet New wallet address (non-zero)
    function setAgentWallet(uint256 agentId, address newWallet) external;

    /// @notice Transfer agent ownership.
    /// @dev Callable by:
    ///   - Current agent owner
    ///   - The agent's token contract (for CTO mechanism)
    /// @param agentId  The agent identifier
    /// @param newOwner New owner address (non-zero)
    function transferAgentOwnership(uint256 agentId, address newOwner) external;

    // ─── Events ───────────────────────────────────────────────────────────

    event AgentRegistered(
        uint256 indexed agentId,
        address indexed tokenContract,
        address indexed owner,
        address agentWallet,
        string genomeURI
    );

    event AgentWalletUpdated(uint256 indexed agentId, address indexed oldWallet, address indexed newWallet);

    event GenomeURIUpdated(uint256 indexed agentId, string newURI);

    event AgentOwnershipTransferred(uint256 indexed agentId, address indexed oldOwner, address indexed newOwner);
}
