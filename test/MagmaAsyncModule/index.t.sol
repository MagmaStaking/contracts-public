// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {BaseTest} from "../BaseTest.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {WrappedMonad} from "monad/WrappedMonad.sol";
import {MagmaBase} from "src/MagmaBase.sol";
import {ICoreVault} from "interfaces/ICoreVault.sol";
import {UserWithdrawalCompleted} from "src/MagmaErrorsModule.sol";
import {MockStakingPrecompile} from "../mock/MockStakingPrecompile.sol";

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

    function requestRedeemHelper(uint256 assets) private returns (uint256, uint256) {
        uint256 shares = depositHelper(assets);
        vm.prank(user);
        uint256 requestId = magma.requestRedeem(shares, user, user);

        vm.warp(block.timestamp + magma.DEFAULT_DELAY());
        _advanceEpochsForWithdrawal();

        return (requestId, shares);
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

        // 7540 vault assertions
        assertEq(assets, magma.depositToGVault(assets, user, 3, 3));
        assertEq(address(magma).balance, balanceBefore);
        assertEq(magma.totalAssets(), assetsBefore + assets);
        assertEq(wmon.balanceOf(address(magma)), 0);

        // User assertions
        assertEq(magma.balanceOf(user), shares);
        assertEq(wmon.balanceOf(user), 0);
        assertEq(user.balance, 0);

        vm.stopPrank();
    }

    function test_DepositToAnotherReceiver() public {
        address receiver = address(15);
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
        emit IERC20.Transfer(address(0), receiver, shares);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(user, receiver, assets, shares);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Withdrawal(address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit MagmaBase.DepositWithReferral(user, receiver, assets, shares, 0);

        // 7540 vault assertions
        assertEq(shares, magma.deposit(assets, receiver));
        assertEq(address(magma).balance, balanceBefore);
        assertEq(wmon.balanceOf(address(magma)), 0);
        assertEq(magma.totalAssets(), assetsBefore + assets);

        // Receiver assertions
        assertEq(magma.balanceOf(receiver), shares, "Receiver shares should equal to minted shares");
        assertEq(wmon.balanceOf(receiver), 0);
        assertEq(receiver.balance, 0);

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
        (uint256 requestId, uint256 shares) = requestRedeemHelper(assets);
        uint256 sharesBefore = magma.balanceOf(address(magma));
        uint256 userWMONBefore = wmon.balanceOf(address(user));
        uint256 assetsBefore = magma.totalAssets();

        // Assertions before redeem
        (address owner, uint256 pendingShares, uint256 pendingAssets,) = magma.pendingRedeemRequests(user, requestId);
        assertEq(user, owner);
        assertEq(shares, pendingShares);
        assertEq(assets, pendingAssets);

        vm.expectEmit(true, true, true, true);
        emit UserWithdrawalCompleted(user, assets);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(magma), address(0), shares);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Deposit(address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(address(magma), user, assets);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(user, user, address(magma), assets, shares);

        vm.prank(user);
        assertEq(assets, magma.redeem(requestId, user, user));

        // 7540 vault assertions
        (address _owner, uint256 _shares, uint256 _assets, uint256 _claimableTime) =
            magma.pendingRedeemRequests(user, requestId);
        assertEq(address(0), _owner);
        assertEq(0, _shares);
        assertEq(0, _assets);
        assertEq(0, _claimableTime);

        assertEq(sharesBefore - shares, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets());
        assertEq(address(magma).balance, 0);
        assertEq(wmon.balanceOf(address(magma)), 0);

        // User assertions
        assertEq(wmon.balanceOf(address(user)), userWMONBefore + assets);
        assertEq(magma.balanceOf(address(user)), 0);
        assertEq(user.balance, 0);
    }

    function test_RedeemMON() public {
        uint256 assets = 5 ether;
        (uint256 requestId, uint256 shares) = requestRedeemHelper(assets);
        uint256 sharesBefore = magma.balanceOf(address(magma));
        uint256 userMONBefore = user.balance;
        uint256 assetsBefore = magma.totalAssets();

        // Assertions before redeem
        (address owner, uint256 pendingShares, uint256 pendingAssets,) = magma.pendingRedeemRequests(user, requestId);
        assertEq(user, owner);
        assertEq(shares, pendingShares);
        assertEq(assets, pendingAssets);

        vm.expectEmit(true, true, true, true);
        emit UserWithdrawalCompleted(user, assets);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(magma), address(0), shares);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(user, user, address(magma), assets, shares);

        vm.prank(user);
        assertEq(assets, magma.redeemMON(requestId, user, user));

        // 7540 vault assertions
        (address _owner, uint256 _shares, uint256 _assets, uint256 _claimableTime) =
            magma.pendingRedeemRequests(user, requestId);
        assertEq(address(0), _owner);
        assertEq(0, _shares);
        assertEq(0, _assets);
        assertEq(0, _claimableTime);

        assertEq(sharesBefore - shares, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets());
        assertEq(address(magma).balance, 0);
        assertEq(wmon.balanceOf(address(magma)), 0);

        // User assertions
        assertEq(user.balance, userMONBefore + assets);
        assertEq(magma.balanceOf(address(user)), 0);
        assertEq(wmon.balanceOf(address(user)), 0);
    }

    function test_RedeemWithdrawalSlashed() public {
        uint256 assets = 6 ether;
        uint256 expectedAssets = assets / 2;
        (uint256 requestId, uint256 shares) = requestRedeemHelper(assets);
        uint256 sharesBefore = magma.balanceOf(address(magma));
        uint256 userWMONBefore = wmon.balanceOf(address(user));
        uint256 assetsBefore = magma.totalAssets();
        uint256 sharesAfterSlash = magma.convertToShares(expectedAssets);

        // Assertions before redeem
        (address owner, uint256 pendingShares, uint256 pendingAssets,) = magma.pendingRedeemRequests(user, requestId);
        assertEq(user, owner);
        assertEq(shares, pendingShares);
        assertEq(assets, pendingAssets);

        MockStakingPrecompile(STAKING_PRECOMPILE).setSlashDivider(2);

        vm.expectEmit(true, true, true, true);
        emit UserWithdrawalCompleted(user, expectedAssets);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(magma), user, shares - sharesAfterSlash);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(magma), address(0), sharesAfterSlash);

        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Deposit(address(magma), expectedAssets);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(address(magma), user, expectedAssets);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(user, user, address(magma), expectedAssets, sharesAfterSlash);

        vm.prank(user);
        assertEq(expectedAssets, magma.redeem(requestId, user, user));

        // 7540 vault assertions
        (address _owner, uint256 _shares, uint256 _assets, uint256 _claimableTime) =
            magma.pendingRedeemRequests(user, requestId);
        assertEq(address(0), _owner);
        assertEq(0, _shares);
        assertEq(0, _assets);
        assertEq(0, _claimableTime);

        assertEq(sharesBefore - shares, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets());
        assertEq(address(magma).balance, 0);
        assertEq(wmon.balanceOf(address(magma)), 0);

        // User assertions
        assertEq(wmon.balanceOf(address(user)), userWMONBefore + expectedAssets);
        assertEq(magma.balanceOf(address(user)), shares - sharesAfterSlash);
        assertEq(user.balance, 0);
    }

    // TODO: WIP test, wait for _delegatedNativeAssets to be removed and gVault to be integrated, also test for 2 deposits at the same time into gVault and CoreVault and check assets
    /*     function test_MultipleRequestIds() public {
        uint256 requestId1 = 0;
        uint256 requestId2 = 1;
        address user2 = address(15);
        address operator = address(25);
        uint256 assets = 5 ether;
        uint256 userWMONBefore = wmon.balanceOf(user);
        uint256 user2WMONBefore = wmon.balanceOf(user2);
        uint256 shares = depositHelper(assets);
        uint256 shares2 = _depositHelper(assets, user2, false);
        assertEq(shares, shares2, "When depositing asssets by 2 different users, share amount should be the same");

        vm.prank(user);
        magma.setOperator(operator, true);
        vm.prank(user2);
        magma.setOperator(operator, true);

        // Test operator of users requests redemptions that will be handled by a different controller
        vm.startPrank(operator);
        vm.expectEmit(true, true, true, true);
        emit MagmaBase.RedeemRequest(operator, user, requestId1, operator, shares);
        assertEq(requestId1, magma.requestRedeem(shares, operator, user));
        vm.expectEmit(true, true, true, true);
        emit MagmaBase.RedeemRequest(operator, user2, requestId2, operator, shares);
        assertEq(requestId2, magma.requestRedeem(shares, operator, user2));

        uint256 sharesBefore = magma.balanceOf(address(magma));
        uint256 assetsBefore = magma.totalAssets();

        vm.warp(block.timestamp + magma.DEFAULT_DELAY());
        _advanceEpochsForWithdrawal();

        assertEq(
            assets,
            magma.redeem(requestId1, operator, user),
            "Redeem amount should be same as assets depositted by user"
        );
        assertEq(
            assets,
            magma.redeem(requestId2, operator, user2),
            "Redeem amount should be same as assets depositted by user2"
        );
        // 7540 vault assertions
        assertEq(sharesBefore - shares, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets(), "Magma total Assets should not have changed");
        assertEq(address(magma).balance, 0, "MON balance of Magma should be 0");
        assertEq(wmon.balanceOf(address(magma)), 0, "WMON balance of Magma should be 0");

        // User assertions
        assertEq(
            wmon.balanceOf(user),
            userWMONBefore + assets,
            "WMON balance of Magma should be equal to pass balance + assets redeemed"
        );
        assertEq(magma.balanceOf(user), 0);
        assertEq(user.balance, 0);

        // User2 assertions
        assertEq(
            wmon.balanceOf(user2),
            user2WMONBefore + assets,
            "WMON balance of Magma should be equal to pass balance + assets redeemed"
        );
        assertEq(magma.balanceOf(user2), 0);
        assertEq(user2.balance, 0);

        vm.stopPrank();
    } */

    function test_SetOperator() public {
        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit MagmaBase.OperatorSet(user, address(15), true);
        magma.setOperator(address(15), true);
    }

    function test_ControllerReceiverOperatorFlow() public {
        address userOperator = address(15);
        address controller = address(25);
        address controllerOperator = address(35);
        address receiver = address(35);
        uint256 assets = 5 ether;
        uint256 receiverWMONBefore = wmon.balanceOf(receiver);
        uint256 shares = depositHelper(assets);

        vm.prank(user);
        magma.setOperator(userOperator, true);
        vm.prank(controller);
        magma.setOperator(controllerOperator, true);

        // Test operator of users requests redemptions that will be handled by a different controller
        vm.prank(userOperator);
        uint256 requestId = magma.requestRedeem(shares, controller, user);
        uint256 sharesBefore = magma.balanceOf(address(magma));
        uint256 assetsBefore = magma.totalAssets();

        vm.warp(block.timestamp + magma.DEFAULT_DELAY());
        _advanceEpochsForWithdrawal();

        // Test controller operator will handle redemption to a different receiver
        vm.prank(controllerOperator);
        assertEq(assets, magma.redeem(requestId, controller, receiver));

        // 7540 vault assertions
        assertEq(sharesBefore - shares, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets(), "Magma total Assets should not have changed");
        assertEq(address(magma).balance, 0, "MON balance of Magma should be 0");
        assertEq(wmon.balanceOf(address(magma)), 0, "WMON balance of Magma should be 0");

        // Receiver assertions
        assertEq(
            wmon.balanceOf(receiver),
            receiverWMONBefore + assets,
            "WMON balance of Magma should be equal to pass balance + assets redeemed"
        );
        assertEq(magma.balanceOf(receiver), 0);
        assertEq(receiver.balance, 0);
    }
}

// TODO: reentrancy
// TODO: test maxRedeem and all methods in https://eips.ethereum.org/EIPS/eip-4626#methods, based on openzeppelin erc4626
// TODO: test depositGVault, redeem and claim from gVault
// TODO: test deposit, redeem and claim from gVault and viceversa depositGVault redeem and claim from coreVault
