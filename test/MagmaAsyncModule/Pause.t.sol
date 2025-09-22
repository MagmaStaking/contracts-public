// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {MagmaAsyncModuleTest} from "./index.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {WrappedMonad} from "monad/WrappedMonad.sol";
import {MagmaBase} from "src/MagmaBase.sol";
import {ICoreVault} from "interfaces/ICoreVault.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {MockStakingPrecompile} from "../mock/MockStakingPrecompile.sol";

contract MagmaAsyncModuleRevertTest is MagmaAsyncModuleTest {
    function setUp() public override {
        MagmaAsyncModuleTest.setUp();
    }

    function test_PauseUnpauseMint() public {
        uint256 assets = 5 ether;
        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();
        uint256 shares = magma.convertToShares(assets);
        wmon.approve(address(magma), assets);
        vm.stopPrank();

        vm.prank(admin);
        magma.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user);
        magma.mint(shares, user);

        vm.prank(admin);
        magma.unpause();

        vm.prank(user);
        assertEq(assets, magma.mint(shares, user));
    }

    function test_PauseUnpauseDeposit() public {
        uint256 assets = 5 ether;
        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();
        uint256 shares = magma.convertToShares(assets);
        wmon.approve(address(magma), assets);
        vm.stopPrank();

        vm.prank(admin);
        magma.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user);
        magma.deposit(assets, user);

        vm.prank(admin);
        magma.unpause();

        vm.prank(user);
        assertEq(shares, magma.deposit(assets, user));
    }

    function test_PauseUnpauseDepositGVault() public {
        uint256 assets = 5 ether;
        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();
        uint256 shares = magma.convertToShares(assets);
        wmon.approve(address(magma), assets);
        vm.stopPrank();

        vm.prank(admin);
        magma.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user);
        magma.depositGVault(assets, user, 3, 3);

        vm.prank(admin);
        magma.unpause();

        vm.prank(user);
        assertEq(shares, magma.depositGVault(assets, user, 3, 3));
    }

    function test_PauseUnpauseDepositWMON() public {
        uint256 assets = 5 ether;
        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();
        uint256 shares = magma.convertToShares(assets);
        wmon.approve(address(magma), assets);
        vm.stopPrank();

        vm.prank(admin);
        magma.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user);
        magma.depositWMON(assets, user, 3);

        vm.prank(admin);
        magma.unpause();

        vm.prank(user);
        assertEq(shares, magma.depositWMON(assets, user, 3));
    }

    function test_PauseUnpauseDepositMON() public {
        uint256 assets = 5 ether;
        vm.deal(user, assets);
        uint256 shares = magma.convertToShares(assets);

        vm.prank(admin);
        magma.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user);
        magma.depositMON{value: assets}(user, 3);

        vm.prank(admin);
        magma.unpause();

        vm.prank(user);
        assertEq(shares, magma.depositMON{value: assets}(user, 3));
    }

    function test_PauseUnpauseRequestRedeem() public {
        uint256 assets = 5 ether;
        uint256 shares = _depositHelper(assets);

        vm.prank(admin);
        magma.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user);
        magma.requestRedeem(shares, user, user);

        vm.prank(admin);
        magma.unpause();

        vm.prank(user);
        assertEq(0, magma.requestRedeem(shares, user, user));
    }

    function test_PauseUnpauseRequestRedeemGVault() public {
        uint256 assets = 5 ether;
        uint256 shares = _depositGVaultHelper(assets);

        vm.prank(admin);
        magma.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user);
        magma.requestRedeemGVault(shares, user, user, 3);

        vm.prank(admin);
        magma.unpause();

        vm.prank(user);
        assertEq(0, magma.requestRedeemGVault(shares, user, user, 3));
    }

    function test_PauseUnpauseRedeem() public {
        uint256 assets = 5 ether;
        (uint256 requestId,) = _requestRedeemHelper(assets);

        vm.prank(admin);
        magma.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user);
        magma.redeem(requestId, user, user);

        vm.prank(admin);
        magma.unpause();

        vm.prank(user);
        assertEq(assets, magma.redeem(requestId, user, user));
    }

    function test_PauseUnpauseRedeemMON() public {
        uint256 assets = 5 ether;
        (uint256 requestId,) = _requestRedeemHelper(assets);

        vm.prank(admin);
        magma.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user);
        magma.redeemMON(requestId, user, user);

        vm.prank(admin);
        magma.unpause();

        vm.prank(user);
        assertEq(assets, magma.redeemMON(requestId, user, user));
    }
}
