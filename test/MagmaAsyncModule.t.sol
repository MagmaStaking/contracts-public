// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {BaseTest} from "./BaseTest.t.sol";

contract MagmaAsyncModuleTest is BaseTest {
    function setUp() public override {
        BaseTest.setUp();
    }

    function test_ERC165Support() public view {
        bytes4 erc7540InterfaceId = 0x620ee8e4;
        assertTrue(magma.supportsInterface(erc7540InterfaceId));
    }

    function test_Metadata() public view {
        assertEq(magma.name(), "gMON");
        assertEq(magma.symbol(), "gMON");
        assertEq(magma.decimals(), 18);
    }

    function test_RevertWhen_PreviewWithdraw() public {
        vm.expectRevert();
        magma.previewWithdraw(1);
    }

    function test_RevertWhen_PreviewRedeem() public {
        vm.expectRevert();
        magma.previewRedeem(1);
    }

    function test_RevertWhen_Withdraw() public {
        vm.expectRevert();
        magma.withdraw(1, address(1), address(1));
    }

    function test_RevertWhen_Redeem() public {
        vm.expectRevert();
        magma.redeem(1, address(1), address(1));
    }

    function test_Mint() public {
        // test shares
        // test assets
    }

    // function testSynchronousDeposit() public {
    //     uint256 depositAmount = 1000e18;

    //     // Alice deposits using wrapped tokens (WMON) - indirect approach
    //     vm.prank(alice);
    //     uint256 shares = magma.deposit(depositAmount, alice);

    //     assertEq(magma.balanceOf(alice), shares);
    //     // ERC4626 deposit unwraps WMON and delegates native; vault holds no WMON after deposit
    //     assertEq(wmon.balanceOf(address(magma)), 0);
    //     assertEq(magma.totalAssets(), depositAmount);
    // }
    // function testDepositComparison() public {
    //     uint256 depositAmount = 1 ether;

    //     // Method 1: Direct native deposit using depositMon
    //     vm.prank(alice);
    //     uint256 nativeShares = magma.depositMon{value: depositAmount}();

    //     // Method 2: Indirect deposit via WrappedMonad -> deposit
    //     vm.prank(bob);
    //     uint256 wrappedShares = magma.deposit(depositAmount, bob);

    //     // Both methods should give same result (1:1 initially)
    //     assertEq(nativeShares, wrappedShares);
    //     assertEq(magma.balanceOf(alice), depositAmount);
    //     assertEq(magma.balanceOf(bob), depositAmount);
    //     assertEq(magma.totalAssets(), depositAmount * 2);
    // }

    // function testSynchronousMint() public {
    //     uint256 sharesToMint = 1000e18;

    //     vm.prank(alice);
    //     uint256 assets = magma.mint(sharesToMint, alice);

    //     assertEq(magma.balanceOf(alice), sharesToMint);
    //     // Mint unwraps WMON and delegates native; vault holds no WMON after mint
    //     assertEq(wmon.balanceOf(address(magma)), 0);
    //     assertEq(magma.totalAssets(), assets);
    // }

    // function testAsset() public {
    //     assertEq(address(magma.asset()), address(wmon));
    // }

    // function testMaxWithdrawRedeem() public {
    //     // Setup: Alice deposits first
    //     vm.prank(alice);
    //     magma.deposit(1000e18, alice);

    //     // Max withdraw/redeem should return 0 to force async flow
    //     assertEq(magma.maxWithdraw(alice), 0);
    //     assertEq(magma.maxRedeem(alice), 0);
    // }
}

// TODO: think about tests in magmabase needed
// TODO: see how to order all these tests and order MagmaAsyncModule as well
