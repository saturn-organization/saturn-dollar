// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";

import {UpgradeUSDatBase} from "./UpgradeUSDatBase.sol";

/// @notice Step 3 of the timelock-routed USDat upgrade: execute the scheduled operation once its 5-day
///         delay has matured. EXECUTOR_ROLE is held by address(0), so any EOA can broadcast this. The
///         payload is rebuilt from the hardcoded `NEW_IMPLEMENTATION` — the same address the proposal
///         scheduled against, so the operation id matches what the timelock holds.
contract ExecuteUSDatUpgrade is Script, UpgradeUSDatBase {
    function run() public {
        require(NEW_IMPLEMENTATION != address(0), "NEW_IMPLEMENTATION not set: deploy then hardcode it");

        (address proxyAdmin, bytes memory payload) = _buildUpgradeAndCallData(NEW_IMPLEMENTATION);

        TimelockController timelock = TimelockController(payable(TIMELOCK));
        bytes32 id = timelock.hashOperation(proxyAdmin, 0, payload, PREDECESSOR, SALT);

        console.log("New implementation:", NEW_IMPLEMENTATION);
        console.log("Operation id:");
        console.logBytes32(id);

        // The timelock would reject this anyway; failing here names the reason instead of reverting opaquely.
        require(timelock.isOperationReady(id), "operation not ready: wrong impl, never scheduled, or delay pending");

        vm.startBroadcast();

        timelock.execute(proxyAdmin, 0, payload, PREDECESSOR, SALT);

        vm.stopBroadcast();

        console.log("Upgrade executed.");
    }
}
