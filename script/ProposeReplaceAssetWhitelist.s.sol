// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";

import {UpgradeUSDatBase} from "./UpgradeUSDatBase.sol";

/**
 * @notice Step 1 of the (optional) replaceAsset whitelist restriction: schedule
 *         `USDat.setReplaceAssetWhitelistCaller(SOLVER, true)` on the asset-cap-manager timelock, gating
 *         `replaceAsset` to the M0 solver alone. Runs on a different timelock than the USDat upgrade, so it
 *         can — and should — be scheduled in parallel with the upgrade, letting both 5-day delays elapse
 *         concurrently. Must be broadcast by the ASSET_CAP_TIMELOCK PROPOSER EOA. Once the delay matures AND
 *         the upgrade has been executed, run `ExecuteReplaceAssetWhitelist`.
 */
contract ProposeReplaceAssetWhitelist is Script, UpgradeUSDatBase {
    function run() public {
        TimelockController timelock = TimelockController(payable(ASSET_CAP_TIMELOCK));

        bytes memory payload = _buildWhitelistSolverData();

        vm.startBroadcast();

        (, address proposer,) = vm.readCallers();
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer), "sender lacks PROPOSER_ROLE");

        uint256 delay = timelock.getMinDelay();
        timelock.schedule(USDAT_PROXY, 0, payload, PREDECESSOR, SALT, delay);

        vm.stopBroadcast();

        console.log("Scheduled setReplaceAssetWhitelistCaller(solver, true) on USDat.");
        console.log("Solver:", SOLVER);
        console.log("Via asset-cap-manager timelock:", ASSET_CAP_TIMELOCK);
        console.log("Operation id (track on-chain; needed to cancel):");
        console.logBytes32(timelock.hashOperation(USDAT_PROXY, 0, payload, PREDECESSOR, SALT));
        console.log("Executable in %s seconds.", delay);
    }
}
