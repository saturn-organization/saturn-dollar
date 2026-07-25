// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {IUSDat} from "../src/IUSDat.sol";

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUSDatLike is IERC20Like {
    function whitelist(address account) external;
    function isWhitelisted(address account) external view returns (bool);
    function isWhitelistEnabled() external view returns (bool);
}

interface IUniswapV3SwapAdapterLike {
    function swapOut(
        address extensionIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        address recipient,
        bytes calldata path
    ) external;
}

/**
 * @notice Mainnet fork tests for redeeming USDat directly to USDC in one
 *         transaction via M0's UniswapV3SwapAdapter
 *         (USDat -> Wrapped $M via SwapFacility, then Wrapped $M -> USDC via Uniswap V3).
 *
 *         Run with:
 *         forge test --match-contract SwapOutForkTest -vvv
 *
 *         Uses a public mainnet RPC by default; set RPC_URL to override.
 */
contract SwapOutForkTest is Test {
    IUniswapV3SwapAdapterLike constant ADAPTER =
        IUniswapV3SwapAdapterLike(0x023bd2F0A95373C55FC8D1c5F8e60cC3B9Bc4f4b);

    IUSDatLike constant USDAT = IUSDatLike(0x23238f20b894f29041f48D88eE91131C395Aaa71);
    IERC20Like constant USDC = IERC20Like(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // Holds WHITELIST_MANAGER_ROLE on USDat (compliance address from deployment)
    address constant WHITELIST_MANAGER = 0x10D59F776db12b4B271b2609CB8b7Ddd0A82703B;

    // Existing USDat holder on mainnet impersonated as the user (yield recipient)
    address constant USER = 0x3dc0Aa75a6FD01c3DCF9F6FDaf08308B6489F5b5;

    uint256 constant AMOUNT_IN = 100e6; // 100 USDat (6 decimals)
    uint256 constant MIN_AMOUNT_OUT = 99e6; // 1% slippage tolerance

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_URL", string("https://ethereum-rpc.publicnode.com")));

        assertTrue(USDAT.isWhitelistEnabled(), "expected USDat whitelist to be enabled");
        assertGe(USDAT.balanceOf(USER), AMOUNT_IN, "USER does not hold enough USDat");
    }

    /// @notice Current mainnet state: the adapter is not whitelisted on USDat,
    ///         so the SwapFacility unwrap inside swapOut reverts.
    function test_swapOut_revertsWhenAdapterNotWhitelisted() public {
        assertFalse(USDAT.isWhitelisted(address(ADAPTER)));

        vm.startPrank(USER);

        USDAT.approve(address(ADAPTER), AMOUNT_IN);

        vm.expectRevert(abi.encodeWithSelector(IUSDat.AccountNotWhitelisted.selector, address(ADAPTER)));
        ADAPTER.swapOut(address(USDAT), AMOUNT_IN, address(USDC), MIN_AMOUNT_OUT, USER, "");

        vm.stopPrank();
    }

    /// @notice Whitelisting the adapter on USDat first allows the one-transaction
    ///         USDat -> USDC redemption to succeed.
    function test_swapOut_succeedsAfterWhitelistingAdapter() public {
        vm.prank(WHITELIST_MANAGER);
        USDAT.whitelist(address(ADAPTER));

        uint256 usdatBefore = USDAT.balanceOf(USER);
        uint256 usdcBefore = USDC.balanceOf(USER);

        vm.startPrank(USER);

        USDAT.approve(address(ADAPTER), AMOUNT_IN);
        ADAPTER.swapOut(address(USDAT), AMOUNT_IN, address(USDC), MIN_AMOUNT_OUT, USER, "");

        vm.stopPrank();

        uint256 usdatSpent = usdatBefore - USDAT.balanceOf(USER);
        uint256 usdcReceived = USDC.balanceOf(USER) - usdcBefore;

        console.log("USDat spent:  ", usdatSpent);
        console.log("USDC received:", usdcReceived);

        assertEq(usdatSpent, AMOUNT_IN);
        assertGe(usdcReceived, MIN_AMOUNT_OUT);
    }
}
