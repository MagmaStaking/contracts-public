// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseTest} from "./BaseTest.t.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {CoreVault} from "../src/CoreVault.sol";

contract CoreVaultTest is BaseTest {
    function setUp() public override {
        BaseTest.setUp();
        // Redeploy CoreVault with epochSeconds = 0 to bypass epoch guard for this unit test
        address coreImpl = address(new CoreVault());
        address coreProxy = UnsafeUpgrades.deployUUPSProxy(
            coreImpl, abi.encodeCall(CoreVault.initialize, (address(magma), uint256(0), uint256(0)))
        );
        coreVault = CoreVault(payable(coreProxy));
        // Wire magma to new coreVault
        vm.prank(admin);
        magma.setVaults(address(coreVault), address(gvault));
    }

    function testAddAndRemoveValidator() public {
        uint64 v1 = uint64(uint160(address(0x101)));

        // Add validator
        vm.prank(admin);
        coreVault.addValidator(v1);
        assertTrue(coreVault.isWhitelisted(v1));

        // Set up some mock stake for the validator
        _setupValidatorStake(v1, 100 ether);

        // Remove validator - should use precompile to get actual stake
        vm.prank(admin);
        coreVault.removeValidator(v1);
        assertFalse(coreVault.isWhitelisted(v1));
    }

    function testRemoveValidatorWithStake() public {
        uint64 v1 = uint64(uint160(address(0x101)));
        uint64 v2 = uint64(uint160(address(0x102)));

        // Add validators
        vm.prank(admin);
        coreVault.addValidator(v1);
        vm.prank(admin);
        coreVault.addValidator(v2);

        // Set up mock stakes
        _setupValidatorStake(v1, 100 ether);
        _setupValidatorStake(v2, 50 ether);

        // Fund the CoreVault with ETH so it can redistribute stakes
        vm.deal(address(coreVault), 1000 ether);

        // Remove validator with stake
        vm.prank(admin);
        coreVault.removeValidator(v1);

        assertFalse(coreVault.isWhitelisted(v1));
        assertTrue(coreVault.isWhitelisted(v2));
    }

    function testGetDelegatorStakeFunction() public {
        uint64 v1 = uint64(uint160(address(0x101)));

        // Add validator
        vm.prank(admin);
        coreVault.addValidator(v1);

        // Set up mock stake
        _setupValidatorStake(v1, 123 ether);

        // Test that we can read the stake amount from the precompile
        // This tests the _getDelegatorStake function indirectly
        vm.prank(admin);
        coreVault.removeValidator(v1);

        // Should have removed without reverting, meaning _getDelegatorStake worked
        assertFalse(coreVault.isWhitelisted(v1));
    }
}
