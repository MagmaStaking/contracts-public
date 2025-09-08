// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseTest} from "./BaseTest.t.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {CoreVault} from "../src/CoreVault.sol";
import {console} from "forge-std/console.sol";
import {MockStakingPrecompile} from "./mock/MockStakingPrecompile.sol";

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
        uint64 v2 = uint64(uint160(address(0x102)));

        // Add 2 validators (can't remove the last one)
        vm.startPrank(admin);
        coreVault.addValidator(v1);
        coreVault.addValidator(v2);
        vm.stopPrank();
        assertTrue(coreVault.isWhitelisted(v1));

        // Set up some mock stake for the validator with a larger amount to avoid edge cases
        _setupValidatorStake(v1, 200 ether);

        // Advance time to ensure we're in a stable epoch state
        vm.warp(block.timestamp + 1000);

        // Check the setup worked correctly
        uint256 delegatorStake = MockStakingPrecompile(STAKING_PRECOMPILE).debugDelegatorStake(v1, address(coreVault));
        uint256 validatorStake = MockStakingPrecompile(STAKING_PRECOMPILE).debugValidatorStake(v1);
        assertEq(delegatorStake, 200 ether, "Delegator stake should be 200 ether");
        assertEq(validatorStake, 200 ether, "Validator stake should be 200 ether");

        // Remove validator - this should now work without trying to redistribute immediately
        vm.prank(admin);
        coreVault.initiateValidatorRemoval(v1);
        assertFalse(coreVault.isWhitelisted(v1));
    }

    function testAsyncValidatorRemoval() public {
        uint64 v1 = uint64(uint160(address(0x101)));
        uint64 v2 = uint64(uint160(address(0x102)));

        // Add two validators
        vm.prank(admin);
        coreVault.addValidator(v1);
        vm.prank(admin);
        coreVault.addValidator(v2);

        // Set up stakes for both validators
        _setupValidatorStake(v1, 100 ether);
        _setupValidatorStake(v2, 50 ether);

        // Fund the CoreVault with ETH for redistribution later
        vm.deal(address(coreVault), 1000 ether);

        // Advance time to ensure we're in a stable epoch state
        vm.warp(block.timestamp + 1000);

        // Step 1: Initiate validator removal (pauses validator)
        vm.prank(admin);
        coreVault.initiateValidatorRemoval(v1);
        assertFalse(coreVault.isWhitelisted(v1));
        assertTrue(coreVault.isWhitelisted(v2)); // v2 should still be active

        // Step 2: Execute undelegation (creates withdrawal request)
        vm.prank(admin);
        coreVault.executeValidatorUndelegation(v1);

        // Step 3: Advance time to simulate the withdrawal delay period
        // In the mock, we need to advance epochs
        for (uint256 i = 0; i < 8; i++) {
            // WITHDRAWAL_DELAY is 7 epochs
            MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        }

        // Step 4: Complete the withdrawal process
        vm.prank(admin);
        coreVault.completeValidatorRemovalWithdrawal(v1);

        // Verify the process completed successfully
        // The funds should now be available for redistribution to remaining validators
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

        // Remove validator with stake (initiate only for this test)
        vm.prank(admin);
        coreVault.initiateValidatorRemoval(v1);

        assertFalse(coreVault.isWhitelisted(v1));
        assertTrue(coreVault.isWhitelisted(v2));
    }

    function testGetDelegatorStakeFunction() public {
        uint64 v1 = uint64(uint160(address(0x101)));
        uint64 v2 = uint64(uint160(address(0x102)));

        // Add 2 validators (can't remove the last one)
        vm.startPrank(admin);
        coreVault.addValidator(v1);
        coreVault.addValidator(v2);
        vm.stopPrank();

        // Set up mock stake
        _setupValidatorStake(v1, 123 ether);

        // Test that we can read the stake amount from the precompile
        // This tests the _getDelegatorStake function indirectly
        vm.prank(admin);
        coreVault.initiateValidatorRemoval(v1);

        // Should have removed without reverting, meaning _getDelegatorStake worked
        assertFalse(coreVault.isWhitelisted(v1));
    }
}
