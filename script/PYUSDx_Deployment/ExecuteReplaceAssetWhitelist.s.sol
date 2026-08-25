// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";

import {UpgradeUSDatBase} from "./UpgradeUSDatBase.sol";

/**
 * @notice Step 2 of the replaceAsset whitelist restriction: execute the scheduled operation once its
 *         5-day delay has matured. EXECUTOR_ROLE on the asset-cap-manager timelock is held by address(0), so
 *         any EOA can broadcast this. The payload is rebuilt from the on-chain SOLVER constant, so it must
 *         match the one scheduled by `ProposeReplaceAssetWhitelist`.
 */
contract ExecuteReplaceAssetWhitelist is Script, UpgradeUSDatBase {
    function run() public {
        TimelockController timelock = TimelockController(payable(ASSET_CAP_TIMELOCK));

        bytes memory payload = _buildWhitelistSolverData();
        bytes32 id = timelock.hashOperation(USDAT_PROXY, 0, payload, PREDECESSOR, SALT);

        console.log("Operation id:");
        console.logBytes32(id);

        require(timelock.isOperationReady(id), "operation not ready: never scheduled or delay pending");

        vm.startBroadcast();

        timelock.execute(USDAT_PROXY, 0, payload, PREDECESSOR, SALT);

        vm.stopBroadcast();

        console.log("replaceAsset whitelist configured: solver is now the sole allowed caller.");
        console.log("Solver:", SOLVER);
    }
}
