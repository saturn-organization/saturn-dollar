// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {USDat} from "../src/USDat.sol";

contract USDatScript is Script {
    function run() public {
        address initialOwner = vm.envAddress("INITIAL_OWNER"); // Read from .env

        vm.startBroadcast();
        new USDat(initialOwner);
        vm.stopBroadcast();
    }
}
