#!/usr/bin/env bash
#
# Code-consistency proof for the USDat implementation contract.
#
# Proves — with a single hash on each side — that the contract deployed on
# Ethereum mainnet is exactly the audited source, and prints the commit it was
# built from.
#
#   local code hash  : the audited source, compiled and deployed in a local EVM
#                      with the production constructor arguments
#   prod  code hash  : EXTCODEHASH of the live mainnet implementation
#
# The two hashes are equal iff the on-chain code is the audited code.
#
# Requires: foundry (forge, cast), git, and a .env.production providing
#           RPC_URL, M_TOKEN, SWAP_FACILITY.
#
set -euo pipefail

IMPL=0x17cac25c6d6bbcb592837fea083a5c8eb4d1e52e          # mainnet implementation
AUDIT_COMMIT=8735152da4d5182f34cf29771757737d33894064    # audited final commit

# Load RPC_URL, M_TOKEN, SWAP_FACILITY (exported so `forge`/`cast` can read them)
set -a; source .env.production; set +a

COMMIT=$(git rev-parse HEAD)

# LOCAL: compile + deploy the audited source locally with the prod args, hash it
LOCAL=$(forge script script/VerifyCodeHash.s.sol 2>/dev/null \
          | grep -oiE '0x[0-9a-f]{64}' | tail -1)

# PRODUCTION: read the live on-chain runtime code hash
PROD=$(cast codehash "$IMPL" --rpc-url "$RPC_URL")

echo
echo "  commit (HEAD)        : $COMMIT"
echo "  audit commit         : $AUDIT_COMMIT"
echo "  local  code hash     : $LOCAL"
echo "  production code hash : $PROD"
echo
if [ "$COMMIT" = "$AUDIT_COMMIT" ] && [ -n "$LOCAL" ] && [ "$LOCAL" = "$PROD" ]; then
  echo "  MATCH - mainnet $IMPL runs the audited code (commit $AUDIT_COMMIT)"
else
  echo "  MISMATCH"; exit 1
fi
