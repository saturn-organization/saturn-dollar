// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {USDat} from "../src/USDatV1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract USDatScript is Script {
    function run() public {
        address minter = vm.envAddress("MINTER"); // Read from .env
        address defaultAdmin = vm.envAddress("DEFAULT_ADMIN"); // Read from .env
        address blacklistManager = vm.envAddress("BLACKLIST_MANAGER"); // Read from .env

        vm.startBroadcast();

        // Deploy implementation
        USDat implementation = new USDat();

        // Encode initialize call
        bytes memory initData = abi.encodeCall(USDat.initialize, (defaultAdmin, minter, blacklistManager));

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // The proxy address is what you'll use for the token
        // USDat token = USDat(address(proxy));

        vm.stopBroadcast();
    }
}
