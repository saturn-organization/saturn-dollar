// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";

contract TestSchedule is Script {
    address constant USDAT = 0x23238f20b894f29041f48D88eE91131C395Aaa71;
    address constant ADMIN_TIMELOCK = 0xfD5782E3BFF366601da3973aE30C583dE4F08A67;
    address constant CURRENT_HOLDER = 0x10D59F776db12b4B271b2609CB8b7Ddd0A82703B;

    bytes32 constant FORCED_TRANSFER_MANAGER_ROLE = keccak256("FORCED_TRANSFER_MANAGER_ROLE");

    function run() external {
        TimelockController timelock = TimelockController(payable(ADMIN_TIMELOCK));
        bytes memory revokeCall =
            abi.encodeCall(IAccessControl.revokeRole, (FORCED_TRANSFER_MANAGER_ROLE, CURRENT_HOLDER));
        uint256 delay = timelock.getMinDelay();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        targets[0] = USDAT;
        payloads[0] = revokeCall;

        vm.startBroadcast();
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), delay);
        vm.stopBroadcast();
    }
}
