// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockRouter — PancakeSwap V2 Router mock for testing
/// @dev Fixed exchange rate. Supports token→token and token→ETH swaps.
contract MockRouter {
    address public immutable WETH;
    uint256 public stablePerToken; // how many stable units per 1e18 agent token

    constructor(address weth_, uint256 stablePerToken_) {
        WETH = weth_;
        stablePerToken = stablePerToken_;
    }

    /// @notice Update exchange rate (for test scenarios)
    function setRate(uint256 newRate) external {
        stablePerToken = newRate;
    }

    /// @notice PancakeSwap V2 compatible swap (FoT-safe variant)
    /// @dev path[0] = tokenIn, path[last] = tokenOut
    ///      Transfers tokenIn from msg.sender, mints tokenOut to `to`.
    ///      For testing: MockStable must have sufficient balance or be mintable.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external {
        require(path.length >= 2, "MockRouter: invalid path");

        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];

        // Pull tokenIn from sender
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Calculate output based on fixed rate
        uint256 amountOut = amountIn * stablePerToken / 1e18;
        require(amountOut >= amountOutMin, "MockRouter: insufficient output");

        // Transfer tokenOut to recipient
        IERC20(tokenOut).transfer(to, amountOut);
    }

    /// @notice PancakeSwap V2 compatible swap: token → ETH/BNB (FoT-safe variant)
    /// @dev path[0] = tokenIn, path[last] = WETH. Pulls tokens, sends BNB to `to`.
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external {
        require(path.length >= 2, "MockRouter: invalid path");

        address tokenIn = path[0];

        // Pull tokenIn from sender
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Calculate BNB output based on fixed rate
        uint256 amountOut = amountIn * stablePerToken / 1e18;
        require(amountOut >= amountOutMin, "MockRouter: insufficient output");

        // Send BNB to recipient
        (bool sent,) = to.call{value: amountOut}("");
        require(sent, "MockRouter: BNB transfer failed");
    }

    /// @notice Get amounts out (for price quotes)
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        // Simplified: each hop uses same rate
        for (uint256 i = 1; i < path.length; i++) {
            amounts[i] = amounts[i - 1] * stablePerToken / 1e18;
        }
    }

    /// @notice Receive BNB (for seeding liquidity in tests)
    receive() external payable {}
}
