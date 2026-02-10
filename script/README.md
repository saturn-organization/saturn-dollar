# USDat Deployment

## Deployer
```
0x8CBA689B49f15E0a3c8770496Df8E88952d6851d
```

## Deterministic Proxy Address
```
0x23238f20b894f29041f48D88eE91131C395Aaa71
```
This address is the same on all chains when using the deployer above with salt `"USDat"`.

## Deploy Command
```bash
source .env && forge script script/USDat.s.sol:DeployUSDat --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
```

## Required Environment Variables
```
PRIVATE_KEY=<deployer private key>
RPC_URL=<rpc endpoint>
M_TOKEN=<M token address>
SWAP_FACILITY=<swap facility address>
ADMIN=<admin address>
COMPLIANCE=<compliance address>
PROCESSOR=<processor address>
YIELD_RECIPIENT=<yield recipient address>
```

## Deployed Contracts

The deployment creates three contracts:

| Contract | Description |
|----------|-------------|
| **Implementation** | USDat logic contract (deployed via CREATE) |
| **Proxy** | User-facing address, holds all state and funds (deployed via CREATE3) |
| **ProxyAdmin** | Controls proxy upgrades, owned by admin |

## CREATE3 via CreateX

The proxy is deployed using [CreateX](https://github.com/pcaversaccio/createx) factory at:
```
0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed
```
This factory is deployed at the same address on all major chains.
