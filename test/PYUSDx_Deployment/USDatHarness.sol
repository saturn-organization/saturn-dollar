// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {MockERC20} from "../../lib/PYUSDX/test/mock/MockERC20.sol";

import {USDat} from "../../src/USDat.sol";

/// @dev Test-only harness. Production `USDat` is upgrade-only (no `initialize`); this adds an `initializer`
///      so unit tests can stand up a working instance, plus a mint helper to fabricate pre-migration supply.
contract USDatHarness is USDat {
    constructor(address pyusdx_, address swapFacility_) USDat(pyusdx_, swapFacility_) {}

    function initialize(address yieldRecipient, address admin, address compliance, address processor)
        external
        initializer
    {
        __MultiMint_init("USDat", "USDat", yieldRecipient, admin, processor, compliance, compliance, processor, admin);
        _grantRole(FORCED_TRANSFER_MANAGER_ROLE, compliance);
        _grantRole(WHITELIST_MANAGER_ROLE, compliance);
    }

    /// @dev Mints USDat directly (bypassing wrap) to simulate pre-migration supply.
    function mintForTest(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal mock M token: a 6-decimal ERC20.
contract MockMToken is MockERC20 {
    constructor() MockERC20("M by M0", "M", 6) {}
}
