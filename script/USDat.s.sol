// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {USDat} from "../src/USDat.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract USDatScript is Script {
    function run() public {
        address defaultAdmin = vm.envAddress("DEFAULT_ADMIN");
        address processor = vm.envAddress("PROCESSOR");
        address compliance = vm.envAddress("COMPLIANCE");
        bytes32 salt = vm.envBytes32("DEPLOY_SALT");

        vm.startBroadcast();

        // Deploy implementation with CREATE2
        USDat implementation = new USDat{salt: salt}();

        // Encode initialize call
        bytes memory initData = abi.encodeCall(
            USDat.initialize,
            (defaultAdmin, processor, compliance)
        );

        // Deploy proxy with CREATE2
        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(
            address(implementation),
            initData
        );

        console.log("Implementation deployed at:", address(implementation));
        console.log("Proxy deployed at:", address(proxy));

        vm.stopBroadcast();
    }
}
