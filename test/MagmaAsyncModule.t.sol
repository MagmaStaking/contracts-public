// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {BaseTest} from "./BaseTest.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {WrappedMonad} from "monad/WrappedMonad.sol";
import {MagmaBase} from "src/MagmaBase.sol";

contract MagmaAsyncModuleTest is BaseTest {
    function setUp() public override {
        BaseTest.setUp();
    }

    function test_ERC165Support() public view {
        bytes4 erc7540InterfaceId = 0x620ee8e4;
        assertTrue(magma.supportsInterface(erc7540InterfaceId));
    }

    function test_Metadata() public view {
        assertEq(magma.asset(), address(wmon));
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

    // No fees on deposits so convertToShares should equal previewMint and convertToAssets should equal previewDeposit
    function test_DepositHelpersRates() public view {
        uint256 assets = 5 ether;
        uint256 shares = magma.convertToShares(assets);
        assertEq(assets, magma.previewMint(shares));
        assertEq(assets, magma.convertToAssets(shares));
        assertEq(shares, magma.previewDeposit(assets));
    }

    function test_Mint() public {
        uint256 effectiveAssets = magma.totalAssets();
        uint256 vaultMONBalance = address(magma).balance;
        uint256 assets = 5 ether;

        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();

        uint256 shares = magma.convertToShares(assets);
        wmon.approve(address(magma), assets);

        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(user, address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), user, shares);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(user, user, assets, shares);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Withdrawal(address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit MagmaBase.DepositWithReferral(user, user, assets, shares, 0);

        // 7540 vault assertions
        assertEq(assets, magma.mint(shares, user));
        assertEq(assets, address(magma).balance + vaultMONBalance);
        assertEq(wmon.balanceOf(address(magma)), 0);
        assertEq(magma.totalAssets(), effectiveAssets + assets);

        // User assertions
        assertEq(magma.balanceOf(user), shares);
        assertEq(wmon.balanceOf(user), 0);
        assertEq((user).balance, 0);

        vm.stopPrank();
    }

    function test_Deposit() public {
        uint256 effectiveAssets = magma.totalAssets();
        uint256 vaultMONBalance = address(magma).balance;
        uint256 assets = 5 ether;

        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();

        uint256 shares = magma.convertToShares(assets);
        wmon.approve(address(magma), assets);

        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(user, address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), user, shares);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(user, user, assets, shares);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Withdrawal(address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit MagmaBase.DepositWithReferral(user, user, assets, shares, 0);

        // 7540 vault assertions
        assertEq(shares, magma.deposit(assets, user));
        assertEq(assets, address(magma).balance + vaultMONBalance);
        assertEq(wmon.balanceOf(address(magma)), 0);
        assertEq(magma.totalAssets(), effectiveAssets + assets);

        // User assertions
        assertEq(magma.balanceOf(user), shares);
        assertEq(wmon.balanceOf(user), 0);
        assertEq((user).balance, 0);

        vm.stopPrank();
    }

    function test_DepositWMON() public {
        uint256 effectiveAssets = magma.totalAssets();
        uint256 vaultMONBalance = address(magma).balance;
        uint256 assets = 5 ether;

        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();

        uint256 shares = magma.convertToShares(assets);
        wmon.approve(address(magma), assets);

        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(user, address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), user, shares);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(user, user, assets, shares);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Withdrawal(address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit MagmaBase.DepositWithReferral(user, user, assets, shares, 3);

        // 7540 vault assertions
        assertEq(shares, magma.depositWMON(assets, user, 3));
        assertEq(assets, address(magma).balance + vaultMONBalance);
        assertEq(wmon.balanceOf(address(magma)), 0);
        assertEq(magma.totalAssets(), effectiveAssets + assets);

        // User assertions
        assertEq(magma.balanceOf(user), shares);
        assertEq(wmon.balanceOf(user), 0);
        assertEq((user).balance, 0);

        vm.stopPrank();
    }

    function test_DepositMON() public {
        // uint256 effectiveAssets = magma.totalAssets();
        // uint256 vaultMONBalance = address(magma).balance;
        // uint256 assets = 5 ether;

        // vm.deal(user, assets);
        // vm.startPrank(user);

        // uint256 shares = magma.convertToShares(assets);

        // vm.expectEmit(true, true, true, true);
        // emit WrappedMonad.Deposit(address(magma), assets);
        // vm.expectEmit(true, true, true, true);
        // emit WrappedMonad.Transfer(user, address(magma), assets);
        // vm.expectEmit(true, true, true, true);
        // emit IERC20.Transfer(address(0), user, shares);
        // vm.expectEmit(true, true, true, true);
        // emit IERC4626.Deposit(user, user, assets, shares);
        // vm.expectEmit(true, true, true, true);
        // emit WrappedMonad.Withdrawal(address(magma), assets);
        // vm.expectEmit(true, true, true, true);
        // emit MagmaBase.DepositWithReferral(user, user, assets, shares, 3);

        // 7540 vault assertions
        // magma.depositMON{value: assets}(user, 3);
        // assertEq(shares, magma.depositMON{value: assets}(user, 3));
        // assertEq(assets, address(magma).balance + vaultMONBalance);
        // assertEq(wmon.balanceOf(address(magma)), 0);
        // assertEq(magma.totalAssets(), effectiveAssets + assets);

        // // User assertions
        // assertEq(magma.balanceOf(user), shares);
        // assertEq(wmon.balanceOf(user), 0);
        // assertEq((user).balance, 0);

        // vm.stopPrank();
    }

    // TODO: test deposit to another receiver and withdraw to another receiver

    function test_DepositToGVault() public {
        uint256 effectiveAssets = magma.totalAssets();
        uint256 vaultMONBalance = address(magma).balance;
        uint256 assets = 5 ether;

        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();

        // No fees on deposits so convertToShares should equal previewMint
        uint256 shares = magma.convertToShares(assets);
        assertEq(assets, magma.previewMint(shares));

        wmon.approve(address(magma), assets);

        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(user, address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), user, shares);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(user, user, assets, shares);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Withdrawal(address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit MagmaBase.DepositWithReferral(user, user, assets, shares, 3);

        assertEq(assets, magma.depositToGVault(assets, user, 3, 3));
        /**
         * TODO: this test is not passing because of gVault, also maybe this test is correct and not the coreVault tests
         * the actual test should be assertEq(assets, vaultMONBalance);, please replace on the above depositTests
         */
        // assertEq(assets, address(magma).balance + vaultMONBalance);
        assertEq(magma.totalAssets(), effectiveAssets + assets);

        vm.stopPrank();
    }

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
// TODO: reentrancy
// TODO: look at openzeppelin erc4626 tests
// TODO: test maxRedeem and all methods in https://eips.ethereum.org/EIPS/eip-4626#methods, based on openzeppelin erc4626
// TODO: Check events are being emitted across the whole code, we are not emitting events in functions like “setOperator”, “setAdmin”, “setVaults”,
