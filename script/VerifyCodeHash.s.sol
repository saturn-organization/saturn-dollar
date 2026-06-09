// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {USDat} from "../src/USDat.sol";
import {UpgradeUSDatBase} from "./UpgradeUSDatBase.sol";

/// @notice Deploys USDat in a local EVM with the production constructor
///         arguments and prints the resulting runtime code hash (EXTCODEHASH).
///
///         This hash is fully determined by (audited source + compiler settings
///         + the two immutable addresses PYUSDX / PYUSDX_SWAP_FACILITY). It must
///         therefore equal the on-chain implementation's code hash if — and
///         only if — the deployed code is the audited code built from this
///         commit with these arguments.
///
///         The immutables are sourced from `UpgradeUSDatBase` so this check uses
///         exactly the constructor arguments the upgrade itself deploys with.
contract VerifyCodeHash is Script, UpgradeUSDatBase {
    function run() external {
        USDat impl = new USDat(PYUSDX, PYUSDX_SWAP_FACILITY);

        console2.log("PYUSDX              ", PYUSDX);
        console2.log("PYUSDX_SWAP_FACILITY", PYUSDX_SWAP_FACILITY);
        console2.log("LOCAL IMPLEMENTATION CODEHASH:");
        console2.logBytes32(address(impl).codehash);
    }
}
