// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {USDat} from "../src/USDat.sol";

contract DeployUSDat is Script {
    bytes32 constant SALT_USDAT_IMPL = keccak256("saturn.USDat.impl.v1");
    bytes32 constant SALT_USDAT_PROXY = keccak256("saturn.USDat.proxy.v1");

    function run() public {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        address mToken = vm.envAddress("M_TOKEN");
        address swapFacility = vm.envAddress("SWAP_FACILITY");
        address yieldRecipient = vm.envAddress("YIELD_RECIPIENT");
        address admin = vm.envAddress("ADMIN");
        address compliance = vm.envAddress("COMPLIANCE");
        address processor = vm.envAddress("PROCESSOR");

        console.log("Deployer:", deployer);
        console.log("Predicted impl:", CREATE3.predictDeterministicAddress(SALT_USDAT_IMPL));
        console.log("Predicted proxy:", CREATE3.predictDeterministicAddress(SALT_USDAT_PROXY));

        vm.startBroadcast(deployer);

        address implementation = CREATE3.deployDeterministic(
            abi.encodePacked(type(USDat).creationCode, abi.encode(mToken, swapFacility)), SALT_USDAT_IMPL
        );

        bytes memory initData = abi.encodeCall(USDat.initialize, (yieldRecipient, admin, compliance, processor));

        address proxy = CREATE3.deployDeterministic(
            abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode, abi.encode(implementation, admin, initData)
            ),
            SALT_USDAT_PROXY
        );

        vm.stopBroadcast();

        console.log("Implementation:", implementation);
        console.log("Proxy:", proxy);
    }
}
