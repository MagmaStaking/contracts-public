// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseTest} from "./BaseTest.t.sol";
import {MockStakingPrecompile} from "./mock/MockStakingPrecompile.sol";
import {ErrNotAuthorized, ErrZeroAmount, ErrNotWhitelisted} from "../src/MagmaErrorsModule.sol";

contract GVaultRewardsInjectionTest is BaseTest {
    uint64 constant VAL_1 = 1;
    uint64 constant VAL_2 = 2;

    function setUp() public override {
        BaseTest.setUp();

        // gVault maintains its own whitelist; add VAL_1 and VAL_2
        vm.startPrank(admin);
        gvault.addValidator(VAL_1);
        gvault.addValidator(VAL_2);
        // Ensure non-zero and generous caps so deposits/injections don't revert
        gvault.changeValidatorCap(VAL_1, type(uint256).max);
        gvault.changeValidatorCap(VAL_2, type(uint256).max);
        vm.stopPrank();
    }

    function testInjectRewardsAuthorizationAndGuards() public {
        // Unauthorized caller
        vm.expectRevert(ErrNotAuthorized.selector);
        gvault.injectRewards{value: 1 ether}(VAL_1);

        // Zero amount
        vm.prank(admin);
        vm.expectRevert(ErrZeroAmount.selector);
        gvault.injectRewards{value: 0}(VAL_1);

        // Not whitelisted
        vm.deal(admin, 1 ether);
        vm.prank(admin);
        vm.expectRevert(ErrNotWhitelisted.selector);
        gvault.injectRewards{value: 1 ether}(9999);
    }

    function testInjectRewardsToSpecificValidator_SharesUnchanged_HoldersGain() public {
        // Deposit to VAL_1 for a user
        address user = address(0xBEEF);
        uint256 depositAmt = 1 ether;
        vm.deal(user, depositAmt);
        vm.startPrank(user);
        // Route via Magma 4626 path to gVault
        wmon.deposit{value: depositAmt}();
        wmon.approve(address(magma), depositAmt);
        magma.depositGVault(depositAmt, user, VAL_1, 0);
        vm.stopPrank();

        // Activate stakes for cleaner accounting in mock
        _activateAllStakes();

        uint256 sharesBefore = gvault.delegatedSharesOf(user, VAL_1);
        uint256 userAssetsBefore = gvault.delegatedAmountOf(user, VAL_1);

        // Inject MEV to VAL_1 as admin
        vm.deal(admin, 1 ether);
        vm.prank(admin);
        gvault.injectRewards{value: 1 ether}(VAL_1);

        // Shares unchanged, user asset value increased
        assertEq(gvault.delegatedSharesOf(user, VAL_1), sharesBefore);
        uint256 userAssetsAfter = gvault.delegatedAmountOf(user, VAL_1);
        assertGt(userAssetsAfter, userAssetsBefore);

        // Other validator unaffected
        uint256 val2Assets = gvault.delegatedAmountOf(user, VAL_2);
        assertEq(val2Assets, 0);
    }
}
