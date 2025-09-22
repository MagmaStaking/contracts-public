// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {MagmaAsyncModuleTest} from "./index.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {WrappedMonad} from "monad/WrappedMonad.sol";
import {MagmaBase} from "src/MagmaBase.sol";
import {Magma} from "src/Magma.sol";
import {ICoreVault} from "interfaces/ICoreVault.sol";
import "src/MagmaErrorsModule.sol";
import {MockStakingPrecompile} from "../mock/MockStakingPrecompile.sol";

contract MagmaAsyncModuleWithdrawalFeeTest is MagmaAsyncModuleTest {
    function setUp() public override {
        MagmaAsyncModuleTest.setUp();
    }

    function test_RedeemWithdrawalFee() public {
        // TODO: if in basis points change to 500 everywhere
        _setWithdrawalFee(50);
        uint256 assets = 100 ether;
        uint256 assetsAfterFee = 95 ether;
        (uint256 requestId, uint256 shares) = _requestRedeemHelper(assets);
        uint256 userWMONBefore = wmon.balanceOf(address(user));
        uint256 assetsBefore = magma.totalAssets();

        // Assertions before redeem
        (address owner, uint256 pendingShares, uint256 pendingAssets,, bool isGVault) =
            magma.pendingRedeemRequests(user, requestId);
        assertEq(user, owner);
        assertEq(shares, pendingShares);
        assertEq(assets, pendingAssets);
        assertEq(false, isGVault);

        vm.expectEmit(true, true, true, true);
        emit UserWithdrawalCompleted(user, assetsAfterFee);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Deposit(address(magma), assetsAfterFee);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(address(magma), user, assetsAfterFee);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(user, user, address(magma), assetsAfterFee, shares);

        vm.prank(user);
        assertEq(assetsAfterFee, magma.redeem(requestId, user, user));

        // 7540 vault assertions
        (address _owner, uint256 _shares, uint256 _assets, uint256 _claimableTime,) =
            magma.pendingRedeemRequests(user, requestId);
        assertEq(address(0), _owner);
        assertEq(0, _shares);
        assertEq(0, _assets);
        assertEq(0, _claimableTime);

        assertEq(0, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets(), "Assets before should equal magma total assets");
        assertEq(address(magma).balance, 0);
        assertEq(wmon.balanceOf(address(magma)), 0);

        // User assertions
        assertEq(wmon.balanceOf(address(user)), userWMONBefore + assetsAfterFee);
        assertEq(magma.balanceOf(address(user)), 0);
        assertEq(user.balance, 0);
    }

    function test_RedeemGVaultWithdrawalFee() public {
        _setWithdrawalFee(50);
        uint256 assets = 1 ether;
        uint256 assetsAfterFee = 950000000000000000;
        (uint256 requestId, uint256 shares) = _requestRedeemGVaultHelper(assets);
        uint256 userWMONBefore = wmon.balanceOf(address(user));
        uint256 assetsBefore = magma.totalAssets();

        // Assertions before redeem
        (address owner, uint256 pendingShares, uint256 pendingAssets,, bool isGVault) =
            magma.pendingRedeemRequests(user, requestId);
        assertEq(user, owner);
        assertEq(shares, pendingShares);
        assertEq(assets, pendingAssets);
        assertEq(true, isGVault);

        vm.expectEmit(true, true, true, true);
        emit UserWithdrawalCompleted(user, assetsAfterFee);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Deposit(address(magma), assetsAfterFee);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(address(magma), user, assetsAfterFee);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(user, user, address(magma), assetsAfterFee, shares);

        vm.prank(user);
        assertEq(assetsAfterFee, magma.redeem(requestId, user, user));

        // 7540 vault assertions
        (address _owner, uint256 _shares, uint256 _assets, uint256 _claimableTime,) =
            magma.pendingRedeemRequests(user, requestId);
        assertEq(address(0), _owner);
        assertEq(0, _shares);
        assertEq(0, _assets);
        assertEq(0, _claimableTime);

        assertEq(0, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets());
        assertEq(address(magma).balance, 0);
        assertEq(wmon.balanceOf(address(magma)), 0);

        // gVault assertions
        assertEq(0, gvault.delegatedAmountOf(user, 3));
        assertEq(0, gvault.delegatedSharesOf(user, 3));
        assertEq(0, gvault.maxWithdrawableFromGVault(user, 3));

        // User assertions
        assertEq(wmon.balanceOf(address(user)), userWMONBefore + assetsAfterFee);
        assertEq(magma.balanceOf(address(user)), 0);
        assertEq(user.balance, 0);
    }

    // function test_RedeemMONWithdrawalFee() public {
    //     uint256 assets = 5 ether;
    //     (uint256 requestId, uint256 shares) = _requestRedeemHelper(assets);
    //     uint256 userMONBefore = user.balance;
    //     uint256 assetsBefore = magma.totalAssets();

    //     // Assertions before redeem
    //     (address owner, uint256 pendingShares, uint256 pendingAssets,, bool isGVault) =
    //         magma.pendingRedeemRequests(user, requestId);
    //     assertEq(user, owner);
    //     assertEq(shares, pendingShares);
    //     assertEq(assets, pendingAssets);
    //     assertEq(false, isGVault);

    //     vm.expectEmit(true, true, true, true);
    //     emit UserWithdrawalCompleted(user, assets);
    //     vm.expectEmit(true, true, true, true);
    //     emit IERC4626.Withdraw(user, user, address(magma), assets, shares);

    //     vm.prank(user);
    //     assertEq(assets, magma.redeemMON(requestId, user, user));

    //     // 7540 vault assertions
    //     (address _owner, uint256 _shares, uint256 _assets, uint256 _claimableTime,) =
    //         magma.pendingRedeemRequests(user, requestId);
    //     assertEq(address(0), _owner);
    //     assertEq(0, _shares);
    //     assertEq(0, _assets);
    //     assertEq(0, _claimableTime);

    //     assertEq(0, magma.balanceOf(address(magma)));
    //     assertEq(assetsBefore, magma.totalAssets());
    //     assertEq(address(magma).balance, 0);
    //     assertEq(wmon.balanceOf(address(magma)), 0);

    //     // User assertions
    //     assertEq(user.balance, userMONBefore + assets);
    //     assertEq(magma.balanceOf(address(user)), 0);
    //     assertEq(wmon.balanceOf(address(user)), 0);
    // }

    // function test_RedeemWithdrawalSlashedWithdrawalFee() public {
    //     uint256 assets = 6 ether;
    //     uint256 expectedAssets = assets / 2;
    //     (uint256 requestId, uint256 shares) = _requestRedeemHelper(assets);
    //     uint256 userWMONBefore = wmon.balanceOf(address(user));
    //     uint256 assetsBefore = magma.totalAssets();
    //     uint256 sharesAfterSlash = magma.convertToShares(expectedAssets);

    //     // Assertions before redeem
    //     (address owner, uint256 pendingShares, uint256 pendingAssets,,) = magma.pendingRedeemRequests(user, requestId);
    //     assertEq(user, owner);
    //     assertEq(shares, pendingShares);
    //     assertEq(assets, pendingAssets);

    //     MockStakingPrecompile(STAKING_PRECOMPILE).setSlashDivider(2);

    //     vm.expectEmit(true, true, true, true);
    //     emit UserWithdrawalCompleted(user, expectedAssets);
    //     vm.expectEmit(true, true, true, true);
    //     emit IERC20.Transfer(address(0), user, shares - sharesAfterSlash);
    //     vm.expectEmit(true, true, true, true);
    //     emit WrappedMonad.Deposit(address(magma), expectedAssets);
    //     vm.expectEmit(true, true, true, true);
    //     emit WrappedMonad.Transfer(address(magma), user, expectedAssets);
    //     vm.expectEmit(true, true, true, true);
    //     emit IERC4626.Withdraw(user, user, address(magma), expectedAssets, sharesAfterSlash);

    //     vm.prank(user);
    //     assertEq(expectedAssets, magma.redeem(requestId, user, user));

    //     // 7540 vault assertions
    //     (address _owner, uint256 _shares, uint256 _assets, uint256 _claimableTime,) =
    //         magma.pendingRedeemRequests(user, requestId);
    //     assertEq(address(0), _owner);
    //     assertEq(0, _shares);
    //     assertEq(0, _assets);
    //     assertEq(0, _claimableTime);

    //     assertEq(0, magma.balanceOf(address(magma)));
    //     assertEq(assetsBefore, magma.totalAssets());
    //     assertEq(address(magma).balance, 0);
    //     assertEq(wmon.balanceOf(address(magma)), 0);

    //     // User assertions
    //     assertEq(wmon.balanceOf(address(user)), userWMONBefore + expectedAssets);
    //     assertEq(magma.balanceOf(address(user)), shares - sharesAfterSlash);
    //     assertEq(user.balance, 0);
    // }

    // function test_GVaultRedeemFlowWhenRebalanceWithdrawalFee() public {
    //     uint256 assets = 5 ether;
    //     // CoreVault stake so user can redeem from corevault with his remaining shares after redeeming from gVault
    //     _depositHelper(assets * 100, address(1000), false);
    //     uint256 assetsBefore = magma.totalAssets();
    //     uint256 shares = _depositGVaultHelper(assets);
    //     uint256 userWMONBefore = wmon.balanceOf(address(user));

    //     vm.prank(admin);
    //     gvault.adminInitiateRebalanceBps(5_000);

    //     uint256 assetsGVault = gvault.maxWithdrawableFromGVault(user, 3);
    //     uint256 sharesGVault = magma.convertToAssets(assetsGVault);

    //     assertEq(assets / 2, assetsGVault);
    //     assertEq(assets, magma.convertToAssets(shares));

    //     vm.startPrank(user);
    //     uint256 requestId1 = magma.requestRedeemGVault(sharesGVault, user, user, 3);
    //     vm.warp(block.timestamp + magma.DEFAULT_DELAY());
    //     _advanceEpochsForWithdrawal();
    //     assertEq(assets / 2, magma.redeem(requestId1, user, user));

    //     // 7540 vault assertions
    //     (address _owner, uint256 _shares, uint256 _assets, uint256 _claimableTime,) =
    //         magma.pendingRedeemRequests(user, requestId1);
    //     assertEq(address(0), _owner);
    //     assertEq(0, _shares);
    //     assertEq(0, _assets);
    //     assertEq(0, _claimableTime);

    //     assertEq(0, magma.balanceOf(address(magma)));
    //     assertEq(
    //         assetsBefore + assets / 2,
    //         magma.totalAssets(),
    //         "Total assets should be equal to assets before + 1/2 of depositted assets"
    //     );
    //     assertEq(address(magma).balance, 0);
    //     assertEq(wmon.balanceOf(address(magma)), 0);

    //     // gVault assertions
    //     assertEq(assets / 2, gvault.delegatedAmountOf(user, 3), "Delegated amount in gVault should be 0");
    //     assertEq(shares - sharesGVault, gvault.delegatedSharesOf(user, 3), "Delegates shares in gVault should be 0");
    //     assertEq(0, gvault.maxWithdrawableFromGVault(user, 3), "maxWithdrawableFromGVault should be 0");

    //     // User assertions
    //     assertEq(wmon.balanceOf(address(user)), userWMONBefore + assets / 2);
    //     assertEq(
    //         magma.balanceOf(address(user)),
    //         shares - sharesGVault,
    //         "Shares to be redeemed on corevault should be consistent with the balance of the user"
    //     );
    //     assertEq(user.balance, 0);

    //     uint256 requestId2 = magma.requestRedeem(shares - sharesGVault, user, user);
    //     vm.warp(block.timestamp + magma.DEFAULT_DELAY());
    //     _advanceEpochsForWithdrawal();
    //     assertEq(
    //         assets / 2, magma.redeem(requestId2, user, user), "Redeem from coreVault should return half the assets"
    //     );

    //     vm.stopPrank();

    //     // 7540 vault assertions
    //     (address _owner_, uint256 _shares_, uint256 _assets_, uint256 _claimableTime_,) =
    //         magma.pendingRedeemRequests(user, requestId2);
    //     assertEq(address(0), _owner_);
    //     assertEq(0, _shares_);
    //     assertEq(0, _assets_);
    //     assertEq(0, _claimableTime_);

    //     assertEq(0, magma.balanceOf(address(magma)));
    //     assertEq(
    //         assetsBefore,
    //         magma.totalAssets(),
    //         "Assets before depositing should equal assets after depositing and redeeming"
    //     );
    //     assertEq(address(magma).balance, 0);
    //     assertEq(wmon.balanceOf(address(magma)), 0);

    //     // gVault assertions
    //     assertEq(assets / 2, gvault.delegatedAmountOf(user, 3), "Delegated amount should be 0");
    //     assertEq(shares - sharesGVault, gvault.delegatedSharesOf(user, 3), "Delegated shares should be 0");
    //     assertEq(0, gvault.maxWithdrawableFromGVault(user, 3), "maxWithdrawableFromGVault should be 0");

    //     // User assertions
    //     assertEq(wmon.balanceOf(address(user)), userWMONBefore + assets);
    //     assertEq(magma.balanceOf(address(user)), 0);
    //     assertEq(user.balance, 0);
    // }
}
// // TODO: uppercase the other tests
