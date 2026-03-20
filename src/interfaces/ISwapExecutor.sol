// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISwapExecutor — Pluggable swap execution for GooAgentToken
/// @notice Decouples token contracts from specific DEX router implementations.
///         Deploy different executors (V2, V3, aggregator) and hot-swap without
///         redeploying the token contract.
interface ISwapExecutor {
    /// @notice Execute a token → native (BNB/ETH) swap.
    /// @param token     The ERC-20 token to sell (caller must have approved this contract)
    /// @param tokenAmount Amount of tokens to sell
    /// @param minNativeOut Minimum acceptable native output (slippage protection)
    /// @param recipient  Address to receive native proceeds
    /// @return nativeReceived Actual native amount received
    function executeSwap(
        address token,
        uint256 tokenAmount,
        uint256 minNativeOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 nativeReceived);

    /// @notice The underlying DEX router address (for off-chain discovery).
    function router() external view returns (address);

    /// @notice Wrapped native token address (WBNB/WETH).
    function wrappedNative() external view returns (address);
}
