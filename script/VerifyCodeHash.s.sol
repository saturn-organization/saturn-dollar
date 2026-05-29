// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {USDat} from "../src/USDat.sol";

/// @notice Deploys USDat in a local EVM with the production constructor
///         arguments and prints the resulting runtime code hash (EXTCODEHASH).
///
///         This hash is fully determined by (audited source + compiler settings
///         + the two immutable addresses M_TOKEN / SWAP_FACILITY). It must
///         therefore equal the on-chain implementation's code hash if — and
///         only if — the deployed code is the audited code built from this
///         commit with these arguments.
contract VerifyCodeHash is Script {
    function run() external {
        address mToken = vm.envAddress("M_TOKEN");
        address swapFacility = vm.envAddress("SWAP_FACILITY");

        USDat impl = new USDat(mToken, swapFacility);

        console2.log("M_TOKEN      ", mToken);
        console2.log("SWAP_FACILITY", swapFacility);
        console2.log("LOCAL IMPLEMENTATION CODEHASH:");
        console2.logBytes32(address(impl).codehash);
    }
}
