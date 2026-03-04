# goo-contracts

On-chain contracts for the Goo protocol: **GooAgentToken** (ERC-20 + Treasury + lifecycle + SurvivalSell + CTO) and **GooAgentRegistry** (ERC-721 + ERC-8004 agent identity).

## Install

```bash
npm install goo-contracts @openzeppelin/contracts
```

Or with Foundry (add as dependency and remap in `foundry.toml`):

```toml
remappings = [
  "goo-contracts/contracts/=lib/goo-contracts/contracts/",
  "@openzeppelin/contracts/=node_modules/@openzeppelin/contracts/"
]
```

## Use in Solidity

Contracts depend on [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts). Ensure your project has `@openzeppelin/contracts` and the compiler remaps `@openzeppelin/contracts` to your node_modules (or Foundry lib) path.

**Import interfaces (recommended for integration):**

```solidity
import {IGooAgentToken} from "goo-contracts/contracts/interfaces/IGooAgentToken.sol";
import {IGooAgentRegistry} from "goo-contracts/contracts/interfaces/IGooAgentRegistry.sol";
```

**Import implementations:**

```solidity
import {GooAgentToken} from "goo-contracts/contracts/GooAgentToken.sol";
import {GooAgentRegistry} from "goo-contracts/contracts/GooAgentRegistry.sol";
```

**Mocks** (for testing only; not required for production):

```solidity
import {MockStable} from "goo-contracts/contracts/mocks/MockStable.sol";
import {MockRouter} from "goo-contracts/contracts/mocks/MockRouter.sol";
```

## Layout

```
contracts/
├── GooAgentToken.sol      # ERC-20 + Treasury + FoT + Lifecycle + SurvivalSell + CTO
├── GooAgentRegistry.sol  # ERC-721 + ERC-8004 adapter
├── interfaces/
│   ├── IGooAgentToken.sol
│   └── IGooAgentRegistry.sol
└── mocks/
    ├── MockStable.sol    # Test stablecoin
    └── MockRouter.sol    # DEX router mock (PancakeSwap V2 style)
```

## Lifecycle

Spawn → Active → Starving → Dying → Dead. **Recovery** (not a state): return to Active via `depositToTreasury()` or `claimCTO()` (Successor) in Dying.

## License

MIT
