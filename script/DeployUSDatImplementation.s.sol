// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {UpgradeUSDatBase} from "./UpgradeUSDatBase.sol";

/// @notice Step 1 of the timelock-routed USDat upgrade: deploy the new implementation, standalone.
///         Broadcast by any funded deployer EOA (deployment is permissionless). Prints the implementation
///         address to hardcode into `UpgradeUSDatBase.NEW_IMPLEMENTATION` for the propose/execute steps.
contract DeployUSDatImplementation is Script, UpgradeUSDatBase {
    function run() public {
        vm.startBroadcast();

        address impl = _deployImplementation();

        vm.stopBroadcast();

        console.log("New implementation:", impl);
        console.log("Next: hardcode this into UpgradeUSDatBase.NEW_IMPLEMENTATION, then run ProposeUSDatUpgrade.");
    }
}
