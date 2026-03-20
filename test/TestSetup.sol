// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GooAgentToken} from "../src/GooAgentToken.sol";
import {GooAgentRegistry} from "../src/GooAgentRegistry.sol";
import {MockSwapExecutor} from "../src/mocks/MockSwapExecutor.sol";
import {IGooAgentToken} from "../src/interfaces/IGooAgentToken.sol";
import {IGooAgentRegistry} from "../src/interfaces/IGooAgentRegistry.sol";

/// @title TestSetup — Deploys token, registry, mocks for v2.0 BNB-native tests
abstract contract TestSetup is Test {
    uint256 constant FIXED_BURN_RATE = 1e15; // 0.001 BNB/day
    uint256 constant MIN_RUNWAY_HOURS = 24;
    uint256 constant STARVING_GRACE_PERIOD = 86400; // 24h
    uint256 constant DYING_MAX_DURATION = 604800; // 7 days
    uint256 constant PULSE_TIMEOUT = 172800; // 48h
    uint256 constant SURVIVAL_SELL_COOLDOWN = 3600; // 1h
    uint256 constant MAX_SELL_BPS = 5000; // 50%
    uint256 constant MIN_CTO_AMOUNT = 1e17; // 0.1 BNB
    uint256 constant FEE_RATE_BPS = 100; // 1%
    uint256 constant CIRCULATION_BPS = 10000; // 100%

    address internal deployer;
    address internal agentWallet;
    address internal user1;
    address internal user2;
    address internal mockWeth;

    MockSwapExecutor internal swapExecutor;
    GooAgentRegistry internal registry;
    GooAgentToken internal token;

    function _deployTokenAndRegistry() internal {
        deployer = address(this);
        agentWallet = makeAddr("agentWallet");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        mockWeth = makeAddr("weth");

        address mockRouter = makeAddr("router");
        swapExecutor = new MockSwapExecutor(mockRouter, mockWeth, 1e12); // 1e18 tokens = 1e12 BNB wei
        registry = new GooAgentRegistry();

        // Deploy with 1 BNB contribution
        vm.deal(deployer, 10 ether);
        token = new GooAgentToken{value: 1 ether}(
            "Goo Agent",
            "GOO",
            agentWallet,
            address(swapExecutor),
            address(registry),
            FIXED_BURN_RATE,
            MIN_RUNWAY_HOURS,
            STARVING_GRACE_PERIOD,
            DYING_MAX_DURATION,
            PULSE_TIMEOUT,
            SURVIVAL_SELL_COOLDOWN,
            MAX_SELL_BPS,
            MIN_CTO_AMOUNT,
            FEE_RATE_BPS,
            CIRCULATION_BPS
        );

        // Fund swap executor with BNB so survivalSell can work
        vm.deal(address(swapExecutor), 100 ether);
        // Fund test accounts with BNB
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
    }

    function _starvingThreshold() internal pure returns (uint256) {
        return FIXED_BURN_RATE * MIN_RUNWAY_HOURS / 24;
    }
}
