# Contributing

Thanks for your interest in `goo-contracts` (Goo protocol on-chain reference implementations and interfaces).

## How to contribute

1. Open an issue to discuss the change (bug, feature, docs, or tests).
2. Fork the repo and create a branch for your work.
3. Implement your changes and add/adjust tests where appropriate.
4. Submit a pull request with a clear description of what changed and why.

## Development & tests

Prerequisites:

- Foundry (`forge`)
- Node.js (only if you also work on the npm publishing side)

Run tests:

```bash
forge install
forge build
forge test
```

## Coding standards

- Keep public interfaces stable (function signatures should not be changed without introducing a new interface/version).
- Prefer clear revert messages and consistent error prefixes (`"Goo: ..."`) in reference implementations.
- Add NatSpec for new public/external functions.

## Reporting issues

When reporting bugs, include:

- Expected behavior
- Actual behavior
- Steps to reproduce (or a failing test)
- Relevant logs / transaction details if applicable
