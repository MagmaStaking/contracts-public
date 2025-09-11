// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {BaseTest} from "./BaseTest.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {WrappedMonad} from "monad/WrappedMonad.sol";
import {MagmaBase} from "src/MagmaBase.sol";
import "src/MagmaErrorsModule.sol";

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

    function _depositHelper(uint256 assets, address depositor, bool toGVault) private returns (uint256) {
        uint256 shares = magma.convertToShares(assets);
        vm.deal(depositor, shares);
        vm.startPrank(depositor);
        wmon.deposit{value: shares}();
        wmon.approve(address(magma), shares);
        assertEq(shares, toGVault ? magma.depositToGVault(assets, user, 3, 0) : magma.deposit(shares, depositor));
        vm.stopPrank();
        return shares;
    }

    function depositHelper(uint256 assets) private returns (uint256) {
        /**
         * As a helper deposit 100 more stake so the original amount can easily be withdrawn taking into account the
         * _onetwentiethThreshold
         */
        _depositHelper(assets * 100, address(1000), false);
        uint256 shares = _depositHelper(assets, user, false);

        _activateAllStakes();

        return shares;
    }

    function depositToGVaultHelper(uint256 assets) private returns (uint256) {
        uint256 shares = _depositHelper(assets, user, true);
        _activateAllStakes();
        return shares;
    }

    function requestRedeemHelper(uint256 assets) private returns (uint256) {
        uint256 shares = depositHelper(assets);
        vm.prank(user);
        uint256 requestId = magma.requestRedeem(shares, user, user);

        return requestId;
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

    function test_PendingRedeemRequest() public {
        uint256 assets = 5 ether;
        address controller = address(123);
        uint256 shares = depositHelper(assets);

        vm.prank(user);
        uint256 requestId = magma.requestRedeem(shares, controller, user);
        assertEq(shares, magma.pendingRedeemRequest(requestId, controller));
    }

    function test_ClaimableRedeemRequest() public {
        uint256 assets = 5 ether;
        address controller = address(123);
        uint256 shares = depositHelper(assets);
        vm.warp(2);
        vm.prank(user);
        uint256 requestId = magma.requestRedeem(shares, controller, user);
        assertEq(0, magma.claimableRedeemRequest(requestId, controller));
        vm.warp(block.timestamp + (magma.DEFAULT_DELAY() / 2));
        assertEq(0, magma.claimableRedeemRequest(requestId, controller));
        vm.warp(block.timestamp + (magma.DEFAULT_DELAY() / 2));
        assertEq(shares, magma.claimableRedeemRequest(requestId, controller));
    }

    function test_RequestRedeem() public {
        uint256 requestIdCountBefore = 0;
        uint256 assets = 5 ether;
        uint256 shares = depositHelper(assets);
        uint256 sharesUserBefore = magma.balanceOf(user);
        uint256 assetsBefore = magma.totalAssets();

        // Assertions before request
        (address _owner, uint256 _pendingShares, uint256 _pendingAssets, uint256 _claimableTime) =
            magma.pendingRedeemRequests(user, requestIdCountBefore);
        assertEq(address(0), _owner);
        assertEq(0, _pendingShares);
        assertEq(0, _pendingAssets);
        assertEq(0, _claimableTime);
        assertEq(0, magma.balanceOf(address(magma)));

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(user, address(magma), shares);
        vm.expectEmit(true, true, true, true);
        emit MagmaBase.RedeemRequest(user, user, requestIdCountBefore, user, shares);

        vm.prank(user);
        assertEq(0, magma.requestRedeem(shares, user, user));

        (address owner, uint256 pendingShares, uint256 pendingAssets, uint256 claimableTime) =
            magma.pendingRedeemRequests(user, requestIdCountBefore);

        // 7540 vault assertions
        assertEq(user, owner);
        assertEq(shares, pendingShares);
        assertEq(assets, pendingAssets);
        assertEq(block.timestamp + magma.DEFAULT_DELAY(), claimableTime);
        assertEq(shares, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets() + assets);

        // user assertions
        assertEq(magma.balanceOf(user), sharesUserBefore - shares);
    }

    function test_RequestRedeemFromGVault() public {
        uint256 requestIdCountBefore = 0;
        uint256 assets = 5 ether;
        uint256 shares = depositToGVaultHelper(assets);
        uint256 sharesUserBefore = magma.balanceOf(user);
        uint256 assetsBefore = magma.totalAssets();

        // Assertions before request
        (address _owner, uint256 _pendingShares, uint256 _pendingAssets, uint256 _claimableTime) =
            magma.pendingRedeemRequests(user, requestIdCountBefore);
        assertEq(address(0), _owner);
        assertEq(0, _pendingShares);
        assertEq(0, _pendingAssets);
        assertEq(0, _claimableTime);
        assertEq(0, magma.balanceOf(address(magma)));

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(user, address(magma), shares);
        vm.expectEmit(true, true, true, true);
        emit MagmaBase.RedeemRequest(user, user, requestIdCountBefore, user, shares);

        vm.prank(user);
        assertEq(0, magma.requestRedeemFromGVault(shares, user, user, 3));

        (address owner, uint256 pendingShares, uint256 pendingAssets, uint256 claimableTime) =
            magma.pendingRedeemRequests(user, requestIdCountBefore);

        // 7540 vault assertions
        assertEq(user, owner);
        assertEq(shares, pendingShares);
        assertEq(assets, pendingAssets);
        assertEq(block.timestamp + magma.DEFAULT_DELAY(), claimableTime);
        assertEq(shares, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets() + assets);

        // user assertions
        assertEq(magma.balanceOf(user), sharesUserBefore - shares);
    }

    function test_Redeem() public {
        uint256 assets = 5 ether;
        uint256 requestId = requestRedeemHelper(assets);
        vm.prank(user);
        //magma.redeem(requestId, user, user);
    }

    function test_RedeemMON() public {}

    function test_MultipleRequestIds() public {}

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

    function test_RevertWhen_Deposit0Assets() public {
        uint256 assets = 0;
        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();
        wmon.approve(address(magma), assets);
        vm.expectRevert(ErrZeroAmount.selector);
        magma.deposit(assets, user);
        vm.stopPrank();
    }

    function test_RevertWhen_RequestRedeemPending() public {
        uint256 assets = 6 ether;
        uint256 shares = depositHelper(assets);

        vm.startPrank(user);
        assertEq(0, magma.requestRedeem(shares / 2, user, user));
        vm.expectRevert(ErrRequestPending.selector);
        magma.requestRedeem(shares / 2, user, user);

        vm.stopPrank();
    }

    function test_RevertWhen_RequestRedeem0Shares() public {
        vm.prank(user);
        vm.expectRevert(ErrZeroShares.selector);
        magma.requestRedeem(0, user, user);
    }

    function test_RevertWhen_RequestRedeemNotAuthorized() public {
        vm.expectRevert(ErrNotAuthorized.selector);
        magma.requestRedeem(5, user, user);
    }

    function test_RevertWhen_RequestRedeemInsufficientShares() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ErrInsufficientShares.selector, 5, 0));
        magma.requestRedeem(5, user, user);
    }

    function test_RevertWhen_RedeemNotAuthorized() public {
        uint256 assets = 5 ether;
        uint256 requestId = requestRedeemHelper(assets);
        vm.prank(user);
        vm.expectRevert(ErrNotAuthorized.selector);
        magma.redeem(requestId, address(2), user);
    }

    function test_RevertWhen_RedeemPending() public {
        uint256 assets = 5 ether;
        uint256 shares = depositHelper(assets);
        vm.startPrank(user);
        uint256 requestId = magma.requestRedeem(shares, user, user);
        vm.expectRevert(ErrRequestPending.selector);
        magma.redeem(requestId, user, user);
        vm.stopPrank();
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
// TODO: test maxRedeem and all methods in https://eips.ethereum.org/EIPS/eip-4626#methods, based on openzeppelin erc4626
// TODO: Check events are being emitted across the whole code, we are not emitting events in functions like “setOperator”, “setAdmin”, “setVaults”,
// TODO: test deposit to another receiver and withdraw to another receiver
