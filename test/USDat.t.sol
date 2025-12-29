// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {USDat} from "../src/USDat.sol"; // Adjust the path based on your Foundry project structure
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract USDatTest is Test {
    USDat public token;
    address public admin;
    address public processor;
    address public user1;
    address public user2;
    address public compliance;
    uint256 internal constant USER1_PRIVATE_KEY = 0xA11CE;

    function setUp() public {
        admin = address(this); // Or use a specific address: makeAddr("admin");
        processor = makeAddr("processor");
        compliance = makeAddr("compliance");
        user1 = vm.addr(USER1_PRIVATE_KEY);
        user2 = makeAddr("user2");

        // Deploy implementation
        USDat implementation = new USDat();

        // Encode initialize call
        bytes memory initData = abi.encodeCall(USDat.initialize, (admin, processor, compliance));

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Wrap proxy in USDat interface
        token = USDat(address(proxy));
    }

    function testDeployment() public view {
        assertEq(token.name(), "USDat");
        assertEq(token.symbol(), "USDat");
        assertEq(token.decimals(), 18); // Default from ERC20
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(token.hasRole(token.PROCESSOR_ROLE(), processor));
        assertEq(token.totalSupply(), 0);
    }

    function testMintByProcessor() public {
        uint256 amount = 1000 * 10 ** 18;

        vm.prank(processor);
        token.mint(user1, amount);

        assertEq(token.balanceOf(user1), amount);
        assertEq(token.totalSupply(), amount);
    }

    function testMintByNonProcessorFails() public {
        uint256 amount = 1000 * 10 ** 18;

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, token.PROCESSOR_ROLE()
            )
        );
        vm.prank(user1);
        token.mint(user1, amount);
    }

    function testBurn() public {
        uint256 mintAmount = 1000 * 10 ** 18;
        uint256 burnAmount = 500 * 10 ** 18;

        vm.prank(processor);
        token.mint(user1, mintAmount);

        vm.prank(user1);
        token.burn(burnAmount);

        assertEq(token.balanceOf(user1), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function testBurnFrom() public {
        uint256 mintAmount = 1000 * 10 ** 18;
        uint256 burnAmount = 500 * 10 ** 18;

        vm.prank(processor);
        token.mint(user1, mintAmount);

        vm.prank(user1);
        token.approve(user2, burnAmount);

        vm.prank(user2);
        token.burnFrom(user1, burnAmount);

        assertEq(token.balanceOf(user1), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function testPermit() public {
        uint256 amount = 1000 * 10 ** 18;
        uint256 nonce = token.nonces(user1);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 domainSeparator = token.DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user1,
                user2,
                amount,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Simulate signing (in tests, we use vm.sign with a private key)
        vm.deal(user1, 1 ether); // Not necessary, but for completeness
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(USER1_PRIVATE_KEY, digest);

        // Apply the permit
        token.permit(user1, user2, amount, deadline, v, r, s);

        assertEq(token.allowance(user1, user2), amount);
        assertEq(token.nonces(user1), nonce + 1);
    }

    function testGrantProcessorRole() public {
        address newProcessor = makeAddr("newProcessor");

        // Only admin can grant roles
        vm.prank(admin);
        token.grantRole(token.PROCESSOR_ROLE(), newProcessor);

        assertTrue(token.hasRole(token.PROCESSOR_ROLE(), newProcessor));
    }

    function testRevokeProcessorRole() public {
        vm.prank(admin);
        token.revokeRole(token.PROCESSOR_ROLE(), processor);

        assertFalse(token.hasRole(token.PROCESSOR_ROLE(), processor));
    }
}
