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

        _setupValidatorInStakingPrecompile(3);
        _advanceEpoch();
        vm.startPrank(admin);
        gvault.addValidator(3);
        gvault.changeValidatorCap(3, 5 ether);
        vm.stopPrank();
    }

    function getRequestIdCount() private view returns (uint256) {
        return uint256(vm.load(address(magma), bytes32(uint256(5))));
    }

    function depositHelper(uint256 assets) private returns (uint256) {
        uint256 shares = magma.convertToShares(assets);

        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();
        wmon.approve(address(magma), assets);
        assertEq(shares, magma.deposit(assets, user));
        vm.stopPrank();

        _activateAllStakes();

        return shares;
    }

    function requestRedeemHelper(uint256 assets) private returns (uint256) {
        uint256 shares = depositHelper(assets);
        magma.requestRedeem(shares, user, user);

        return shares;
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

    // No fees on deposits so convertToShares should equal previewMint and convertToAssets should equal previewDeposit
    function test_DepositHelpersRates() public view {
        uint256 assets = 5 ether;
        uint256 shares = magma.convertToShares(assets);
        assertEq(assets, magma.previewMint(shares));
        assertEq(assets, magma.convertToAssets(shares));
        assertEq(shares, magma.previewDeposit(assets));
    }

    function test_Mint() public {
        uint256 assetsBefore = magma.totalAssets();
        uint256 balanceBefore = address(magma).balance;
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
        assertEq(address(magma).balance, balanceBefore);
        assertEq(magma.totalAssets(), assetsBefore + assets);

        // User assertions
        assertEq(magma.balanceOf(user), shares);
        assertEq(wmon.balanceOf(user), 0);
        assertEq(user.balance, 0);

        vm.stopPrank();
    }

    function test_Deposit() public {
        uint256 assetsBefore = magma.totalAssets();
        uint256 balanceBefore = address(magma).balance;
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
        assertEq(address(magma).balance, balanceBefore);
        assertEq(wmon.balanceOf(address(magma)), 0);
        assertEq(magma.totalAssets(), assetsBefore + assets);

        // User assertions
        assertEq(magma.balanceOf(user), shares);
        assertEq(wmon.balanceOf(user), 0);
        assertEq(user.balance, 0);

        vm.stopPrank();
    }

    function test_DepositWMON() public {
        uint256 assetsBefore = magma.totalAssets();
        uint256 balanceBefore = address(magma).balance;
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
        assertEq(address(magma).balance, balanceBefore);
        assertEq(wmon.balanceOf(address(magma)), 0);
        assertEq(magma.totalAssets(), assetsBefore + assets);

        // User assertions
        assertEq(magma.balanceOf(user), shares);
        assertEq(wmon.balanceOf(user), 0);
        assertEq(user.balance, 0);

        vm.stopPrank();
    }

    function test_DepositMON() public {
        uint256 assetsBefore = magma.totalAssets();
        uint256 balanceBefore = address(magma).balance;
        uint256 assets = 5 ether;

        vm.deal(user, assets);
        vm.startPrank(user);

        uint256 shares = magma.convertToShares(assets);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), user, shares);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(user, user, assets, shares);
        vm.expectEmit(true, true, true, true);
        emit MagmaBase.DepositWithReferral(user, user, assets, shares, 3);

        // 7540 vault assertions
        assertEq(shares, magma.depositMON{value: assets}(user, 3));
        assertEq(address(magma).balance, balanceBefore);
        assertEq(wmon.balanceOf(address(magma)), 0);
        assertEq(magma.totalAssets(), assetsBefore + assets);

        // User assertions
        assertEq(magma.balanceOf(user), shares);
        assertEq(wmon.balanceOf(user), 0);
        assertEq(user.balance, 0);

        vm.stopPrank();
    }

    function test_DepositToGVault() public {
        uint256 assetsBefore = magma.totalAssets();
        uint256 balanceBefore = address(magma).balance;
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
        assertEq(address(magma).balance, balanceBefore);
        assertEq(magma.totalAssets(), assetsBefore + assets);

        vm.stopPrank();
    }

    function test_PendingRedeemRequest() public {}

    function test_ClaimableRedeemRequest() public {}

    function test_RequestRedeem() public {
        uint256 requestIdCountBefore = getRequestIdCount();
        uint256 assetsBefore = magma.totalAssets();
        uint256 assets = 5 ether;
        uint256 shares = depositHelper(assets);
        uint256 sharesUserBefore = magma.balanceOf(user);

        // Assertions before request
        (uint256 _pendingShares, uint256 _pendingAssets, uint256 _claimableTime) =
            magma.pendingRedeemRequests(user, requestIdCountBefore);
        assertEq(0, _pendingShares);
        assertEq(0, _pendingAssets);
        assertEq(0, _claimableTime);
        assertEq(0, magma.balanceOf(address(magma)));

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(user, address(magma), shares);
        vm.expectEmit(true, true, true, true);
        emit MagmaBase.RedeemRequest(user, user, getRequestIdCount(), user, shares);

        vm.prank(user);
        assertEq(requestIdCountBefore, magma.requestRedeem(shares, user, user));

        (uint256 pendingShares, uint256 pendingAssets, uint256 claimableTime) =
            magma.pendingRedeemRequests(user, requestIdCountBefore);

        // 7540 vault assertions
        assertEq(shares, pendingShares);
        assertEq(assets, pendingAssets);
        assertEq(block.timestamp + magma.DEFAULT_DELAY(), claimableTime);
        assertEq(requestIdCountBefore + 1, getRequestIdCount());
        assertEq(shares, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets());

        // user assertions
        assertEq(magma.balanceOf(user), sharesUserBefore - shares);
    }

    // function test_Redeem() public {
    //     uint256 requestIdCountBefore = getRequestIdCount();
    //     uint256 assetsBefore = magma.totalAssets();
    //     uint256 assets = 5 ether;
    //     uint256 shares = requestRedeemHelper(assets);
    // }

    function test_MultipleRequestIds() public {}

    // TODO: how do we know if the withdrawal is from gVault or not
    function test_RequestFromGVaultFlow() public {}

    // TODO: test claim in mon, test claim in wmon

    // TODO: test deposit0 or mint0 all of them should revert, also claim 0
    // TODO: test deposit to another receiver and withdraw to another receiver

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

    // function test_OperatorApproval() public {
    //     // Alice approves Bob as operator
    //     vm.prank(alice);
    //     assertTrue(magma.setOperator(bob, true));

    //     assertTrue(magma.isOperator(alice, bob));

    //     // Bob can now act on behalf of Alice
    //     vm.prank(alice);
    //     magma.deposit(1000e18, alice);

    //     // Activate the delegated stakes in the mock
    //     _activateStakes();

    //     vm.prank(bob);
    //     magma.requestWithdraw(500e18, alice, alice);

    //     assertEq(magma.pendingWithdrawRequest(alice), 500e18);
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
// TODO: reentrancy
// TODO: look at openzeppelin erc4626 tests
// TODO: test maxRedeem and all methods in https://eips.ethereum.org/EIPS/eip-4626#methods, based on openzeppelin erc4626
// TODO: Check events are being emitted across the whole code, we are not emitting events in functions like “setOperator”, “setAdmin”, “setVaults”,
// TODO: test all reverts
