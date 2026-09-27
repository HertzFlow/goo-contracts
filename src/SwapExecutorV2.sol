// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapExecutor} from "./interfaces/ISwapExecutor.sol";

/// @title SwapExecutorV2 — PancakeSwap/Uniswap V2 swap executor
/// @notice Executes token → native swaps via a V2 router. Owner can update the
///         router address to migrate between DEX versions without redeploying tokens.
contract SwapExecutorV2 is ISwapExecutor {
    address public override router;
    address public override wrappedNative;
    address public owner;

    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    constructor(address _router) {
        require(_router != address(0), "SwapExecutor: zero router");
        owner = msg.sender;
        router = _router;

        // Derive wrapped native from router (PancakeSwap/Uniswap V2 expose WETH())
        (bool ok, bytes memory data) = _router.staticcall(abi.encodeWithSignature("WETH()"));
        require(ok && data.length >= 32, "SwapExecutor: WETH() failed");
        wrappedNative = abi.decode(data, (address));
    }

    /// @inheritdoc ISwapExecutor
    function executeSwap(
        address token,
        uint256 tokenAmount,
        uint256 minNativeOut,
        address recipient,
        uint256 deadline
    ) external override returns (uint256 nativeReceived) {
        require(recipient != address(0), "SwapExecutor: zero recipient");

        // Pull tokens from caller (GooAgentToken — its _feeExempt flag is active)
        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);

        // Approve router to spend tokens. The allowance is reset to 0 again further below
        // (right after the swap) so a partial pull or a router that returns early can never
        // leave a live standing allowance on this shared executor contract.
        IERC20(token).approve(router, tokenAmount);

        // Build swap path: token → WBNB
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = wrappedNative;

        uint256 balBefore = recipient.balance;

        // V2 FoT-safe swap: token → BNB, proceeds to recipient
        (bool ok,) = router.call(
            abi.encodeWithSignature(
                "swapExactTokensForETHSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)",
                tokenAmount,
                minNativeOut,
                path,
                recipient,
                deadline
            )
        );
        require(ok, "SwapExecutor: swap failed");

        // Clear the router allowance (defence-in-depth against residual allowances).
        IERC20(token).approve(router, 0);

        nativeReceived = recipient.balance - balBefore;

        // Reject a "successful" swap that produced no output. Without this check a router
        // returning early with ok == true would consume the agent's tokens while the
        // executor (and the treasury) reports a successful, zero-value sale.
        require(nativeReceived > 0, "SwapExecutor: zero output");
    }

    /// @notice Update the DEX router (e.g. migrate from V2 to V3 adapter).
    function setRouter(address _newRouter) external {
        require(msg.sender == owner, "SwapExecutor: not owner");
        require(_newRouter != address(0), "SwapExecutor: zero address");

        address oldRouter = router;
        router = _newRouter;

        // Re-derive wrapped native
        (bool ok, bytes memory data) = _newRouter.staticcall(abi.encodeWithSignature("WETH()"));
        require(ok && data.length >= 32, "SwapExecutor: WETH() failed");
        wrappedNative = abi.decode(data, (address));

        emit RouterUpdated(oldRouter, _newRouter);
    }

    /// @notice Transfer ownership of this executor.
    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "SwapExecutor: not owner");
        require(newOwner != address(0), "SwapExecutor: zero owner");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /// @notice Accept BNB (router may refund dust during swaps).
    receive() external payable {}
}
