// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";

import {UpgradeUSDatBase} from "./UpgradeUSDatBase.sol";

/**
 * @notice Step 1 of the timelock-routed USDat upgrade: deploy the new implementation and schedule the
 *         upgrade operation. Must be broadcast by the PROPOSER EOA. After the 5-day delay matures,
 *         run `ExecuteUSDatUpgrade` with the implementation address printed here.
 */
contract ProposeUSDatUpgrade is Script, UpgradeUSDatBase {
    function run() public {
        TimelockController timelock = TimelockController(payable(TIMELOCK));

        vm.startBroadcast();

        (, address proposer,) = vm.readCallers();
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer), "sender lacks PROPOSER_ROLE");

        uint256 delay = timelock.getMinDelay();
        address impl = _deployImplementation();

        vm.stopBroadcast();

        (address proxyAdmin, bytes memory payload) = _buildUpgradeAndCallData(impl);

        // Dry-run the exact bytes we are about to schedule, as the timelock, against current state.
        // Scheduling does NOT execute the payload — it is inert calldata until `execute` five days from
        // now — so without this a broken payload would only surface after the full delay had elapsed.
        // Simulation-only: broadcasting is stopped, so this call is never recorded.
        vm.prank(TIMELOCK);
        (bool ok,) = proxyAdmin.call(payload);
        require(ok, "upgradeAndCall payload would revert");

        vm.startBroadcast();

        timelock.schedule(proxyAdmin, 0, payload, PREDECESSOR, SALT, delay);

        vm.stopBroadcast();

        console.log("New implementation:", impl);
        console.log("ProxyAdmin:", proxyAdmin);
        console.log("Operation id (track on-chain; needed to cancel):");
        console.logBytes32(timelock.hashOperation(proxyAdmin, 0, payload, PREDECESSOR, SALT));
        console.log("Scheduled. Executable in %s seconds.", delay);
        console.log("Then run execute-upgrade with NEW_IMPLEMENTATION=%s", impl);
    }
}
