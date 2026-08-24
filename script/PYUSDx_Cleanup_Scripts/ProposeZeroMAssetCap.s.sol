// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";

interface ISetAssetCapForCleanup {
    function setAssetCap(address asset, uint256 cap) external;
}

/**
 * @notice Step 1 of the M→PYUSDX migration finalizer: schedule `USDat.setAssetCap(M_TOKEN, 0)` on the
 *         asset-cap-manager timelock. Once M is fully drained via `replaceAsset`, zeroing the cap makes
 *         `isAllowedAsset(M)` false, permanently disabling M wraps (and M `replaceAsset` / `claimMYield`).
 *         Since the ASSET_CAP_MANAGER_ROLE holder is a 5-day timelock, propose ahead of time so the delay
 *         matures around the point draining completes. Must be broadcast by PROPOSER. After the delay
 *         matures AND M is drained, run `ExecuteZeroMAssetCap`.
 */
contract ProposeZeroMAssetCap is Script {
    address constant USDAT_PROXY = 0x23238f20b894f29041f48D88eE91131C395Aaa71;
    address constant M_TOKEN = 0x866A2BF4E572CbcF37D5071A7a58503Bfb36be1b;

    address constant ASSET_CAP_MANAGER_TIMELOCK = 0x7D343D17896D2cd87A49b4fB8872298A883f78f7;
    address constant PROPOSER = 0xA18f34a03788CfC566Ce5CCB21b2715f072dA3Ad;

    /// @dev This operation has no dependency on another timelock operation.
    bytes32 constant NO_PREDECESSOR = bytes32(0);
    bytes32 constant SALT = bytes32(0);

    function run() public {
        TimelockController timelock = TimelockController(payable(ASSET_CAP_MANAGER_TIMELOCK));

        require(timelock.hasRole(timelock.PROPOSER_ROLE(), PROPOSER), "configured proposer lacks PROPOSER_ROLE");

        bytes memory payload = abi.encodeCall(ISetAssetCapForCleanup.setAssetCap, (M_TOKEN, 0));
        uint256 delay = timelock.getMinDelay();
        bytes memory scheduleCalldata =
            abi.encodeCall(timelock.schedule, (USDAT_PROXY, 0, payload, NO_PREDECESSOR, SALT, delay));

        console.log("M token:", M_TOKEN);
        console.log("Proposer:", PROPOSER);
        console.log("Via asset-cap-manager timelock:", ASSET_CAP_MANAGER_TIMELOCK);
        console.log("Operation id (track on-chain; needed to cancel):");
        console.logBytes32(timelock.hashOperation(USDAT_PROXY, 0, payload, NO_PREDECESSOR, SALT));
        console.log("--- schedule() call ---");
        console.log("To:", ASSET_CAP_MANAGER_TIMELOCK);
        console.log("Value: 0");
        console.log("Data:");
        console.logBytes(scheduleCalldata);
        console.log("Executable %s seconds after the schedule transaction lands.", delay);

        vm.startBroadcast();

        (, address proposer,) = vm.readCallers();
        require(proposer == PROPOSER, "sender is not the configured proposer");

        timelock.schedule(USDAT_PROXY, 0, payload, NO_PREDECESSOR, SALT, delay);

        vm.stopBroadcast();

        console.log("setAssetCap(M_TOKEN, 0) schedule call completed (simulated unless --broadcast was supplied).");
    }
}
