// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapExecutor} from "../interfaces/ISwapExecutor.sol";

/// @title MockSwapExecutor — Test swap executor with fixed exchange rate
/// @dev Pulls tokens from caller, sends BNB to recipient at a fixed rate.
contract MockSwapExecutor is ISwapExecutor {
    address public override router;
    address public override wrappedNative;
    uint256 public rate; // BNB per 1e18 tokens

    constructor(address _router, address _wrappedNative, uint256 _rate) {
        router = _router;
        wrappedNative = _wrappedNative;
        rate = _rate;
    }

    function setRate(uint256 _newRate) external {
        rate = _newRate;
    }

    function executeSwap(
        address token,
        uint256 tokenAmount,
        uint256 minNativeOut,
        address recipient,
        uint256 /* deadline */
    ) external override returns (uint256 nativeReceived) {
        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);

        nativeReceived = tokenAmount * rate / 1e18;
        require(nativeReceived >= minNativeOut, "MockSwapExecutor: insufficient output");

        (bool sent,) = recipient.call{value: nativeReceived}("");
        require(sent, "MockSwapExecutor: BNB transfer failed");
    }

    receive() external payable {}
}
