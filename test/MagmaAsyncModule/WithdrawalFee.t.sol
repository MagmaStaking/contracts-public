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

    function test_RedeemMONWithdrawalFee() public {
        _setWithdrawalFee(50);
        uint256 assets = 100 ether;
        uint256 assetsAfterFee = 95 ether;
        (uint256 requestId, uint256 shares) = _requestRedeemHelper(assets);
        uint256 userMONBefore = user.balance;
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
        emit IERC4626.Withdraw(user, user, address(magma), assetsAfterFee, shares);

        vm.prank(user);
        assertEq(assetsAfterFee, magma.redeemMON(requestId, user, user));

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

        // User assertions
        assertEq(user.balance, userMONBefore + assetsAfterFee);
        assertEq(magma.balanceOf(address(user)), 0);
        assertEq(wmon.balanceOf(address(user)), 0);
    }

    function test_RedeemWithdrawalSlashedWithdrawalFee() public {
        _setWithdrawalFee(50);
        uint256 assets = 120 ether;
        uint256 assetsAfterFee = 114 ether;
        uint256 expectedAssets = assetsAfterFee / 2;
        (uint256 requestId, uint256 shares) = _requestRedeemHelper(assets);
        uint256 userWMONBefore = wmon.balanceOf(address(user));
        uint256 assetsBefore = magma.totalAssets();
        uint256 sharesAfterSlash = magma.convertToShares(assets / 2);

        // Assertions before redeem
        (address owner, uint256 pendingShares, uint256 pendingAssets,,) = magma.pendingRedeemRequests(user, requestId);
        assertEq(user, owner);
        assertEq(shares, pendingShares);
        assertEq(assets, pendingAssets);

        MockStakingPrecompile(STAKING_PRECOMPILE).setSlashDivider(2);

        vm.expectEmit(true, true, true, true);
        emit UserWithdrawalCompleted(user, expectedAssets);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), user, shares - sharesAfterSlash);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Deposit(address(magma), expectedAssets);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(address(magma), user, expectedAssets);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(user, user, address(magma), expectedAssets, sharesAfterSlash);

        vm.prank(user);
        assertEq(expectedAssets, magma.redeem(requestId, user, user));

        // 7540 vault assertions
        (address _owner, uint256 _shares, uint256 _assets, uint256 _claimableTime,) =
            magma.pendingRedeemRequests(user, requestId);
        assertEq(address(0), _owner);
        assertEq(0, _shares);
        assertEq(0, _assets);
        assertEq(0, _claimableTime);

        assertEq(0, magma.balanceOf(address(magma)), "shares of magma should be 0");
        assertEq(assetsBefore, magma.totalAssets(), "total assets should be same as before");
        assertEq(address(magma).balance, 0, "balance of magma should be 0");
        assertEq(wmon.balanceOf(address(magma)), 0, "wmon balance of magma should be 0");

        // User assertions
        assertEq(
            wmon.balanceOf(address(user)),
            userWMONBefore + expectedAssets,
            "wmon balance of user should include the redeemed assets"
        );
        assertEq(
            magma.balanceOf(address(user)),
            shares - sharesAfterSlash,
            "user should still have some shares due to the slash"
        );
        assertEq(user.balance, 0, "user balance should be 0");
    }
}
