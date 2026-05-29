#!/usr/bin/env bash
#
# Code-consistency proof for the USDat implementation contract.
#
# Confirms the source in this checkout is identical to the audited commit (a
# read-only `git diff` — nothing is checked out, moved, or modified), then
# compiles it, deploys it in a local EVM with the production constructor
# arguments, and checks its code hash equals the code hash live on mainnet:
#
#   local code hash : the audited source, deployed locally with the prod args
#   prod  code hash : EXTCODEHASH of the live mainnet implementation
#
# Equal hashes  <=>  mainnet runs the audited code.
#
# Requires: foundry (forge, cast), git, and a .env.production providing
#           RPC_URL, M_TOKEN, SWAP_FACILITY.
#
set -euo pipefail

# What we're verifying
IMPL=0x17cac25c6d6bbcb592837fea083a5c8eb4d1e52e          # mainnet implementation
NETWORK="Ethereum mainnet (chain id 1)"
AUDIT_COMMIT=8735152da4d5182f34cf29771757737d33894064    # audited commit

# Load RPC_URL, M_TOKEN, SWAP_FACILITY (exported so forge/cast can read them)
set -a; source .env.production; set +a

# 1. Read-only check: is the source here identical to the audited commit?
#    Only the files that affect the compiled bytecode are compared.
if ! git diff --quiet --ignore-submodules=dirty "$AUDIT_COMMIT" -- src lib foundry.toml remappings.txt; then
  echo "  ERROR: source differs from audited commit $AUDIT_COMMIT"
  echo "         inspect with: git diff $AUDIT_COMMIT -- src lib foundry.toml remappings.txt"
  exit 1
fi

# 2. LOCAL: compile + deploy the audited source with the prod args, hash the code
LOCAL=$(forge script script/VerifyCodeHash.s.sol 2>/dev/null \
          | grep -oiE '0x[0-9a-f]{64}' | tail -1)

# 3. PRODUCTION: read the live on-chain runtime code hash
PROD=$(cast codehash "$IMPL" --rpc-url "$RPC_URL")

echo
echo "  network              : $NETWORK"
echo "  implementation       : $IMPL"
echo "  audited commit       : $AUDIT_COMMIT  (source verified identical)"
echo "  local  code hash     : $LOCAL"
echo "  production code hash : $PROD"
echo

if [ -z "$LOCAL" ]; then
  echo "  ERROR: could not compute local code hash"; exit 1
fi

# The proof: does the locally built audited code equal the code live on-chain?
if [ "$LOCAL" = "$PROD" ]; then
  echo "  MATCH - mainnet $IMPL runs the audited code (commit $AUDIT_COMMIT)"
else
  echo "  MISMATCH - deployed code does NOT match the audited commit"; exit 1
fi
