// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {BaseTest} from "../BaseTest.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {WrappedMonad} from "monad/WrappedMonad.sol";
import {MagmaBase} from "src/MagmaBase.sol";
import {ICoreVault} from "interfaces/ICoreVault.sol";
import {ErrPaused} from "src/MagmaErrorsModule.sol";
import {MockStakingPrecompile} from "../mock/MockStakingPrecompile.sol";

contract MagmaAsyncModuleRevertTest is BaseTest {
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

    function requestRedeemHelper(uint256 assets) private returns (uint256, uint256) {
        uint256 shares = depositHelper(assets);
        vm.prank(user);
        uint256 requestId = magma.requestRedeem(shares, user, user);

        vm.warp(block.timestamp + magma.DEFAULT_DELAY());
        _advanceEpochsForWithdrawal();

        return (requestId, shares);
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

        vm.expectRevert(ErrPaused.selector);
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

        vm.expectRevert(ErrPaused.selector);
        vm.prank(user);
        magma.deposit(assets, user);

        vm.prank(admin);
        magma.unpause();

        vm.prank(user);
        assertEq(shares, magma.deposit(assets, user));
    }

    function test_PauseUnpauseDepositToGVault() public {
        uint256 assets = 5 ether;
        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();
        uint256 shares = magma.convertToShares(assets);
        wmon.approve(address(magma), assets);
        vm.stopPrank();

        vm.prank(admin);
        magma.pause();

        vm.expectRevert(ErrPaused.selector);
        vm.prank(user);
        magma.depositToGVault(assets, user, 3, 3);

        vm.prank(admin);
        magma.unpause();

        vm.prank(user);
        assertEq(shares, magma.depositToGVault(assets, user, 3, 3));
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

        vm.expectRevert(ErrPaused.selector);
        vm.prank(user);
        magma.depositWMON(assets, user, 3);

        vm.prank(admin);
        magma.unpause();

        vm.prank(user);
        assertEq(shares, magma.depositWMON(assets, user, 3));
    }

    function test_PauseUnpauseDepositMON() public {}

    function test_PauseUnpauseRequestRedeem() public {}

    function test_PauseUnpauseRequestRedeemFromGVault() public {}

    function test_PauseUnpauseRedeem() public {}

    function test_PauseUnpauseRedeemMON() public {}
}
