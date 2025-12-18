# Ember Vaults

The repo contains the Sui smart contracts for Ember Vaults.

## 🚀 Quick Start

### Prerequisites
- [Sui CLI](https://docs.sui.io/build/install) installed locally, or
- Docker with the `mysten/sui-tools:mainnet` image

### Local Development
```bash
# Build contracts
sui move build

# Run tests
sui move test

# Generate test coverage
sui move test --coverage
sui move coverage summary

# Run with linting
sui move build --lint

# Enable verbose logging for debugging
export RUST_LOG=debug
sui move test

# Or set for a single command
RUST_LOG=info sui move build
```

## 🏗️ Project Structure

```
ember-vaults/
├── sources/
│   ├── admin.move          # Admin capabilities and protocol config
│   ├── events.move         # Event definitions
│   ├── math.move           # Mathematical utilities
│   ├── queue.move          # FIFO queue implementation
│   └── vault.move          # Main vault logic
│   └── gateway.move        # Module for entry methods
├── tests/
│   ├── test_admin.move    # Admin functionality tests
│   ├── test_deposit.move  # Deposit operation tests
│   ├── test_integration_scenarios.move  # Integration tests
│   ├── test_math.move     # Math utility tests
│   ├── test_mint.move     # Share minting tests
│   ├── test_process_withdrawal.move     # Withdrawal processing tests
│   ├── test_queue.move    # Queue implementation tests
│   ├── test_redeem.move   # Share redemption tests
│   ├── test_utils.move    # Test utilities
│   └── test_vault.move    # Vault functionality tests
└── .github/workflows/     # CI/CD pipelines
```


## License

```
This repository is licensed under a Proprietary Smart Contract License held by Ember Protocol Inc.
The source code is published for transparency and verification purposes only and may not be reused, modified, 
or redeployed without written permission. For inquiries, contact support@ember.so.
```