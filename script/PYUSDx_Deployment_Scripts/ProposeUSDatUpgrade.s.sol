// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";

import {UpgradeUSDatBase} from "./UpgradeUSDatBase.sol";

/// @notice Step 2 of the timelock-routed USDat upgrade: schedule the upgrade against the hardcoded
///         NEW_IMPLEMENTATION. Prints the `schedule` calldata to submit through the Fireblocks proposer
///         wallet; also broadcasts directly when run with `--broadcast` by a signer holding PROPOSER_ROLE.
///         After the 5-day delay, run `ExecuteUSDatUpgrade`.
contract ProposeUSDatUpgrade is Script, UpgradeUSDatBase {
    function run() public {
        require(NEW_IMPLEMENTATION != address(0), "NEW_IMPLEMENTATION not set: deploy then hardcode it");

        TimelockController timelock = TimelockController(payable(TIMELOCK));
        (address proxyAdmin, bytes memory payload) = _buildUpgradeAndCallData(NEW_IMPLEMENTATION);
        uint256 delay = timelock.getMinDelay();

        // Dry-run the exact bytes we schedule, as the timelock, against current state. Scheduling stores
        // inert calldata — the payload does not run until `execute` five days out — so without this a broken
        // payload would only surface after the delay. Simulation-only; never broadcast.
        vm.prank(TIMELOCK);
        (bool ok,) = proxyAdmin.call(payload);
        require(ok, "upgradeAndCall payload would revert");

        (, address proposer,) = vm.readCallers();
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer), "sender lacks PROPOSER_ROLE");

        // Calldata for the Fireblocks proposer to submit through custody: `to` is the timelock, `value` is 0.
        bytes memory scheduleCalldata =
            abi.encodeCall(timelock.schedule, (proxyAdmin, 0, payload, PREDECESSOR, SALT, delay));

        console.log("New implementation:", NEW_IMPLEMENTATION);
        console.log("ProxyAdmin:", proxyAdmin);
        console.log("Operation id (track on-chain; needed to cancel):");
        console.logBytes32(timelock.hashOperation(proxyAdmin, 0, payload, PREDECESSOR, SALT));
        console.log("--- schedule() call for the Fireblocks proposer wallet ---");
        console.log("To:", TIMELOCK);
        console.log("Value: 0");
        console.log("Data:");
        console.logBytes(scheduleCalldata);
        console.log("Executable %s seconds after the schedule tx lands.", delay);

        // No-op without --broadcast: the schedule below is simulated only, so the calldata path above stands
        // alone. With --broadcast (signer holds PROPOSER_ROLE) it also submits schedule() directly.
        vm.startBroadcast();

        timelock.schedule(proxyAdmin, 0, payload, PREDECESSOR, SALT, delay);

        vm.stopBroadcast();

        console.log("After the delay matures, run ExecuteUSDatUpgrade.");
    }
}
