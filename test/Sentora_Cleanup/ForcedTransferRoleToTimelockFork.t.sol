// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";

import {
    ProposeForcedTransferRoleToTimelock
} from "../../script/Sentora_Cleanup/ProposeForcedTransferRoleToTimelock.s.sol";
import {
    ExecuteForcedTransferRoleToTimelock
} from "../../script/Sentora_Cleanup/ExecuteForcedTransferRoleToTimelock.s.sol";

contract ProposeForcedTransferRoleToTimelockHarness is ProposeForcedTransferRoleToTimelock {
    function _startBroadcast() internal override {
        vm.startPrank(PROPOSER);
    }

    function _stopBroadcast() internal override {
        vm.stopPrank();
    }
}

contract ExecuteForcedTransferRoleToTimelockHarness is ExecuteForcedTransferRoleToTimelock {
    address constant EXECUTOR = address(0xA11CE);

    function _startBroadcast() internal override {
        vm.startPrank(EXECUTOR);
    }

    function _stopBroadcast() internal override {
        vm.stopPrank();
    }
}

contract ForcedTransferRoleToTimelockForkTest is Test {
    address constant USDAT_PROXY = 0x23238f20b894f29041f48D88eE91131C395Aaa71;
    address constant ADMIN_TIMELOCK = 0xfD5782E3BFF366601da3973aE30C583dE4F08A67;
    address constant CURRENT_ROLE_HOLDER = 0x10D59F776db12b4B271b2609CB8b7Ddd0A82703B;

    bytes32 constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 constant FORCED_TRANSFER_MANAGER_ROLE = keccak256("FORCED_TRANSFER_MANAGER_ROLE");
    bytes32 constant FREEZE_MANAGER_ROLE = keccak256("FREEZE_MANAGER_ROLE");
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant WHITELIST_MANAGER_ROLE = keccak256("WHITELIST_MANAGER_ROLE");

    bytes32 constant NO_PREDECESSOR = bytes32(0);
    bytes32 constant SALT = keccak256("USDat.FORCED_TRANSFER_MANAGER_ROLE.admin-timelock");

    IAccessControl internal usdat = IAccessControl(USDAT_PROXY);
    TimelockController internal timelock = TimelockController(payable(ADMIN_TIMELOCK));

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 25_741_375);
    }

    function test_proposeAndExecuteScripts_moveForcedTransferRoleToAdminTimelock() external {
        assertEq(usdat.getRoleAdmin(FORCED_TRANSFER_MANAGER_ROLE), DEFAULT_ADMIN_ROLE);
        assertTrue(usdat.hasRole(DEFAULT_ADMIN_ROLE, ADMIN_TIMELOCK));
        assertTrue(usdat.hasRole(FORCED_TRANSFER_MANAGER_ROLE, CURRENT_ROLE_HOLDER));
        assertFalse(usdat.hasRole(FORCED_TRANSFER_MANAGER_ROLE, ADMIN_TIMELOCK));

        // The role holder also manages other operational controls; this cleanup must not remove those roles.
        assertTrue(usdat.hasRole(FREEZE_MANAGER_ROLE, CURRENT_ROLE_HOLDER));
        assertTrue(usdat.hasRole(PAUSER_ROLE, CURRENT_ROLE_HOLDER));
        assertTrue(usdat.hasRole(WHITELIST_MANAGER_ROLE, CURRENT_ROLE_HOLDER));

        ProposeForcedTransferRoleToTimelockHarness proposer = new ProposeForcedTransferRoleToTimelockHarness();
        proposer.run();

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _expectedBatch();
        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, NO_PREDECESSOR, SALT);
        uint256 delay = timelock.getMinDelay();

        assertTrue(timelock.isOperationPending(id));
        assertFalse(timelock.isOperationReady(id));
        assertEq(timelock.getTimestamp(id), block.timestamp + delay);

        vm.warp(block.timestamp + delay + 1);
        assertTrue(timelock.isOperationReady(id));

        ExecuteForcedTransferRoleToTimelockHarness executor = new ExecuteForcedTransferRoleToTimelockHarness();
        executor.run();

        assertTrue(timelock.isOperationDone(id));
        assertTrue(usdat.hasRole(FORCED_TRANSFER_MANAGER_ROLE, ADMIN_TIMELOCK));
        assertFalse(usdat.hasRole(FORCED_TRANSFER_MANAGER_ROLE, CURRENT_ROLE_HOLDER));

        assertTrue(usdat.hasRole(FREEZE_MANAGER_ROLE, CURRENT_ROLE_HOLDER));
        assertTrue(usdat.hasRole(PAUSER_ROLE, CURRENT_ROLE_HOLDER));
        assertTrue(usdat.hasRole(WHITELIST_MANAGER_ROLE, CURRENT_ROLE_HOLDER));
    }

    function _expectedBatch()
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);

        targets[0] = USDAT_PROXY;
        targets[1] = USDAT_PROXY;

        payloads[0] = abi.encodeCall(IAccessControl.grantRole, (FORCED_TRANSFER_MANAGER_ROLE, ADMIN_TIMELOCK));
        payloads[1] = abi.encodeCall(IAccessControl.revokeRole, (FORCED_TRANSFER_MANAGER_ROLE, CURRENT_ROLE_HOLDER));
    }
}
