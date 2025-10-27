// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IUSDat {
    error CantRenounceOwnership();
    error OnlyMinter();

    event MinterUpdated(address indexed newMinter, address indexed oldMinter);

    function setMinter(address newMinter) external;
    function mint(address to, uint256 amount) external;
}
