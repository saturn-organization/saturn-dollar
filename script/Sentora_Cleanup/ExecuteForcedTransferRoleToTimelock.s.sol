// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";

/// @notice Executes the matured atomic transfer of USDat's forced-transfer-manager role from the current
///         EOA to the admin timelock.
contract ExecuteForcedTransferRoleToTimelock is Script {
    address constant USDAT_PROXY = 0x23238f20b894f29041f48D88eE91131C395Aaa71;
    address constant ADMIN_TIMELOCK = 0xfD5782E3BFF366601da3973aE30C583dE4F08A67;
    address constant CURRENT_ROLE_HOLDER = 0x10D59F776db12b4B271b2609CB8b7Ddd0A82703B;

    bytes32 constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 constant FORCED_TRANSFER_MANAGER_ROLE = keccak256("FORCED_TRANSFER_MANAGER_ROLE");

    /// @dev Must match the proposal exactly.
    bytes32 constant NO_PREDECESSOR = bytes32(0);
    bytes32 constant SALT = keccak256("USDat.FORCED_TRANSFER_MANAGER_ROLE.admin-timelock");

    function run() public {
        TimelockController timelock = TimelockController(payable(ADMIN_TIMELOCK));
        IAccessControl usdat = IAccessControl(USDAT_PROXY);

        require(
            usdat.getRoleAdmin(FORCED_TRANSFER_MANAGER_ROLE) == DEFAULT_ADMIN_ROLE,
            "unexpected forced-transfer role admin"
        );
        require(usdat.hasRole(DEFAULT_ADMIN_ROLE, ADMIN_TIMELOCK), "timelock lacks DEFAULT_ADMIN_ROLE");
        require(usdat.hasRole(FORCED_TRANSFER_MANAGER_ROLE, CURRENT_ROLE_HOLDER), "current EOA does not hold role");
        require(!usdat.hasRole(FORCED_TRANSFER_MANAGER_ROLE, ADMIN_TIMELOCK), "timelock already holds role");

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildBatch();
        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, NO_PREDECESSOR, SALT);

        console.log("Operation id:");
        console.logBytes32(id);

        require(timelock.isOperationReady(id), "operation not ready: never scheduled or delay pending");

        _startBroadcast();

        timelock.executeBatch(targets, values, payloads, NO_PREDECESSOR, SALT);

        _stopBroadcast();

        require(usdat.hasRole(FORCED_TRANSFER_MANAGER_ROLE, ADMIN_TIMELOCK), "timelock role grant failed");
        require(!usdat.hasRole(FORCED_TRANSFER_MANAGER_ROLE, CURRENT_ROLE_HOLDER), "EOA role revocation failed");

        console.log("FORCED_TRANSFER_MANAGER_ROLE moved to the admin timelock.");
    }

    function _startBroadcast() internal virtual {
        vm.startBroadcast();
    }

    function _stopBroadcast() internal virtual {
        vm.stopBroadcast();
    }

    function _buildBatch()
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
