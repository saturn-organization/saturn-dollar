// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {USDat} from "../src/USDat.sol";

contract USDatScript is Script {
    function run() public {
        address minter = vm.envAddress("MINTER"); // Read from .env
        address defaultAdmin = vm.envAddress("DEFAULT_ADMIN"); // Read from .env

        vm.startBroadcast();
        new USDat(defaultAdmin, minter);
        vm.stopBroadcast();
    }
}
