// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";

import {UpgradeUSDatBase} from "./UpgradeUSDatBase.sol";

/**
 * @notice Step 1 of the M→PYUSDX migration finalizer: schedule `USDat.setAssetCap(M_TOKEN, 0)` on the
 *         asset-cap-manager timelock. Once M is fully drained via `replaceAsset`, zeroing the cap makes
 *         `isAllowedAsset(M)` false, permanently disabling M wraps (and M `replaceAsset` / `claimMYield`).
 *         Since the ASSET_CAP_MANAGER_ROLE holder is a 5-day timelock, propose ahead of time so the delay
 *         matures around the point draining completes. Must be broadcast by the ASSET_CAP_TIMELOCK PROPOSER
 *         EOA. After the delay matures AND M is drained, run `ExecuteZeroMAssetCap`.
 */
contract ProposeZeroMAssetCap is Script, UpgradeUSDatBase {
    function run() public {
        TimelockController timelock = TimelockController(payable(ASSET_CAP_TIMELOCK));

        bytes memory payload = _buildZeroMAssetCapData();

        vm.startBroadcast();

        (, address proposer,) = vm.readCallers();
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer), "sender lacks PROPOSER_ROLE");

        uint256 delay = timelock.getMinDelay();
        timelock.schedule(USDAT_PROXY, 0, payload, PREDECESSOR, SALT, delay);

        vm.stopBroadcast();

        console.log("Scheduled setAssetCap(M_TOKEN, 0) on USDat.");
        console.log("M token:", M_TOKEN);
        console.log("Via asset-cap-manager timelock:", ASSET_CAP_TIMELOCK);
        console.log("Operation id (track on-chain; needed to cancel):");
        console.logBytes32(timelock.hashOperation(USDAT_PROXY, 0, payload, PREDECESSOR, SALT));
        console.log("Executable in %s seconds.", delay);
    }
}
