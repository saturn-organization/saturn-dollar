# USDat

USDat is an upgradeable ERC20 stablecoin contract built with OpenZeppelin's upgradeable contracts. It features role-based access control, permit functionality (EIP-2612), and compliance features including address blacklisting.

## Features

- **ERC20 Standard**: Full ERC20 compatibility with 18 decimals
- **Upgradeable**: UUPS proxy pattern for contract upgrades
- **Permit (EIP-2612)**: Gasless approvals via signatures
- **Role-Based Access Control**:
  - `DEFAULT_ADMIN_ROLE`: Manages upgrades and role assignments
  - `PROCESSOR_ROLE`: Can mint new tokens
  - `COMPLIANCE_ROLE`: Manages blacklist and can rescue tokens
- **Blacklist**: Compliance can block addresses from sending/receiving tokens
- **Burn Blacklisted Tokens**: Compliance can burn tokens held by blacklisted addresses
- **Token Rescue**: Compliance can recover tokens accidentally sent to the contract

## Setup

```shell
forge install
```

## Build

```shell
forge build
```

## Test

```shell
forge test
```

## Deployment

### Environment Variables

Create a `.env` file with the following variables:

```env
# Deployer private key
PRIVATE_KEY=0x...

# Role addresses
DEFAULT_ADMIN=0x...
PROCESSOR=0x...
COMPLIANCE=0x...

# Salt for CREATE2 deterministic deployment (same salt = same address across chains)
DEPLOY_SALT=0x0000000000000000000000000000000000000000000000000000000000000001

# RPC URLs
RPC_URL=https://...
```

### Deploy

The deployment script uses CREATE2 for deterministic addresses across chains. Using the same salt, deployer address, and bytecode will result in the same contract addresses on every chain.

```shell
source .env
forge script script/USDat.s.sol:USDatScript --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

### Verify Contract

```shell
forge verify-contract <IMPLEMENTATION_ADDRESS> src/USDat.sol:USDat --chain <chain_id>
```

## Contract Architecture

```
ERC1967Proxy (User-facing address)
    │
    └── USDat Implementation
            ├── ERC20Upgradeable
            ├── ERC20BurnableUpgradeable
            ├── ERC20PermitUpgradeable
            ├── AccessControlUpgradeable
            ├── ReentrancyGuard
            └── UUPSUpgradeable
```

## Security

- The contract uses OpenZeppelin's battle-tested upgradeable contracts
- ReentrancyGuard protects the `rescueTokens` function
- Only `DEFAULT_ADMIN_ROLE` can authorize upgrades
- Blacklist checks are enforced on `mint`, `transfer`, and `transferFrom`
