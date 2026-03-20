// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {GooAgentToken} from "../src/GooAgentToken.sol";
import {GooAgentRegistry} from "../src/GooAgentRegistry.sol";

/// @title Deploy — Deploy GooAgentToken + optional Registry
/// @dev Usage:
///   forge script script/Deploy.s.sol --rpc-url $BSC_TESTNET_RPC --broadcast --private-key $DEPLOYER_KEY
///
/// Required env vars:
///   AGENT_WALLET   — Agent runtime wallet
///   ROUTER         — DEX Router address (PancakeSwap V2)
///   REGISTRY       — GooAgentRegistry address (set to 0x0 to deploy a new one)
///
/// Optional env vars (defaults match TestSetup.sol):
///   FIXED_BURN_RATE         — default 1e15 (0.001 BNB/day)
///   MIN_RUNWAY_HOURS        — default 72
///   STARVING_GRACE_PERIOD   — default 86400 (24h)
///   DYING_MAX_DURATION      — default 259200 (72h)
///   PULSE_TIMEOUT           — default 3600 (1h)
///   SURVIVAL_SELL_COOLDOWN  — default 300 (5 min)
///   MAX_SELL_BPS            — default 500 (5%)
///   MIN_CTO_AMOUNT          — default 0.1 ether
///   FEE_RATE_BPS            — default 100 (1%)
///   CIRCULATION_BPS         — default 1000 (10%)
///   TOKEN_NAME              — default "Goo Agent"
///   TOKEN_SYMBOL            — default "GOO"
contract DeployScript is Script {
    function run() external {
        // --- Required ---
        address agentWallet = vm.envAddress("AGENT_WALLET");
        address router = vm.envAddress("ROUTER");
        address registry = vm.envOr("REGISTRY", address(0));

        // --- Optional (with defaults matching TestSetup.sol) ---
        uint256 fixedBurnRate = vm.envOr("FIXED_BURN_RATE", uint256(0));
        uint256 minRunwayHours = vm.envOr("MIN_RUNWAY_HOURS", uint256(72));
        uint256 starvingGracePeriod = vm.envOr("STARVING_GRACE_PERIOD", uint256(86400));
        uint256 dyingMaxDuration = vm.envOr("DYING_MAX_DURATION", uint256(259200));
        uint256 pulseTimeout = vm.envOr("PULSE_TIMEOUT", uint256(3600));
        uint256 survivalSellCooldown = vm.envOr("SURVIVAL_SELL_COOLDOWN", uint256(300));
        uint256 maxSellBps = vm.envOr("MAX_SELL_BPS", uint256(500));
        uint256 minCtoAmount = vm.envOr("MIN_CTO_AMOUNT", uint256(0.1 ether));
        uint256 feeRateBps = vm.envOr("FEE_RATE_BPS", uint256(100));
        uint256 circulationBps = vm.envOr("CIRCULATION_BPS", uint256(1000));
        string memory tokenName = vm.envOr("TOKEN_NAME", string("Goo Agent"));
        string memory tokenSymbol = vm.envOr("TOKEN_SYMBOL", string("GOO"));
        uint256 deployValue = vm.envOr("DEPLOY_BNB", uint256(0));

        vm.startBroadcast();

        // Deploy registry if not provided
        if (registry == address(0)) {
            GooAgentRegistry newRegistry = new GooAgentRegistry();
            registry = address(newRegistry);
            console.log("Registry deployed:", registry);
        }

        GooAgentToken token = new GooAgentToken{value: deployValue}(
            tokenName,
            tokenSymbol,
            agentWallet,
            router,
            registry,
            fixedBurnRate,
            minRunwayHours,
            starvingGracePeriod,
            dyingMaxDuration,
            pulseTimeout,
            survivalSellCooldown,
            maxSellBps,
            minCtoAmount,
            feeRateBps,
            circulationBps
        );

        console.log("GooAgentToken deployed:", address(token));
        console.log("  agentWallet:", agentWallet);
        console.log("  router:", router);
        console.log("  registry:", registry);

        vm.stopBroadcast();
    }
}
