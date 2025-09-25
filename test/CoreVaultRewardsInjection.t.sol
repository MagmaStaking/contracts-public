// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseTest} from "./BaseTest.t.sol";
import {MockStakingPrecompile} from "./mock/MockStakingPrecompile.sol";
import {CoreVault} from "../src/CoreVault.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ErrNotAuthorized, ErrNoValidators, ErrZeroAmount} from "../src/MagmaErrorsModule.sol";

contract CoreVaultRewardsInjectionTest is BaseTest {
    uint64 constant VAL_1 = 1;
    uint64 constant VAL_2 = 2;

    function setUp() public override {
        BaseTest.setUp();
    }

    function testInjectRewardsOnlyAuthorized() public {
        // unauthorized caller
        vm.expectRevert(ErrNotAuthorized.selector);
        coreVault.injectRewards{value: 1 ether}();

        // feeReceiver (admin by default in BaseTest) can call
        vm.deal(admin, 1 ether);
        vm.prank(admin);
        coreVault.injectRewards{value: 1 ether}();

        // admin (same as feeReceiver) already covered; if feeReceiver changes, admin should still be authorized
    }

    function testInjectRewardsThresholdZeroSendsAllToFirst() public {
        // BaseTest already added validators 1 and 2 to CoreVault; active stake is zero initially
        uint256 before1 = coreVault.delegatedAmount(VAL_1);
        uint256 before2 = coreVault.delegatedAmount(VAL_2);
        uint256 beforeBal = address(coreVault).balance;

        vm.deal(admin, 3 ether);
        vm.prank(admin);
        coreVault.injectRewards{value: 3 ether}();

        // With _onetwentiethThreshold == 0, all goes to the first (lowest-stake) validator
        assertEq(coreVault.delegatedAmount(VAL_1), before1 + 3 ether);
        assertEq(coreVault.delegatedAmount(VAL_2), before2);
        assertEq(address(coreVault).balance, beforeBal);
    }

    function testInjectRewardsNoValidators() public {
        // Deploy a fresh CoreVault with no validators and call injectRewards to confirm ErrNoValidators
        address coreImpl = address(new CoreVault());
        address coreProxy = UnsafeUpgrades.deployUUPSProxy(
            coreImpl, abi.encodeCall(CoreVault.initialize, (address(magma), uint256(0), uint64(10)))
        );
        CoreVault fresh = CoreVault(payable(coreProxy));

        vm.deal(admin, 1 ether);
        vm.prank(admin);
        vm.expectRevert(ErrNoValidators.selector);
        fresh.injectRewards{value: 1 ether}();
    }

    function testInjectRewardsZeroAmount() public {
        // With validators present, zero amount should revert ErrZeroAmount
        vm.prank(admin);
        vm.expectRevert(ErrZeroAmount.selector);
        coreVault.injectRewards{value: 0}();
    }
}
