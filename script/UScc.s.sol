// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {UScc} from "../src/UScc.sol";

contract USccScript is Script {
    function run() public {
        address initialOwner = vm.envAddress("INITIAL_OWNER"); // Read from .env

        vm.startBroadcast();
        new UScc(initialOwner);
        vm.stopBroadcast();
    }
}
