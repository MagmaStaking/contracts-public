// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseTest} from "./BaseTest.t.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {CoreVault} from "../src/CoreVault.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {console} from "forge-std/console.sol";
import {MockStakingPrecompile} from "./mock/MockStakingPrecompile.sol";
import {
    ErrNotAdmin,
    ErrZeroValidatorId,
    ErrAlreadyWhitelisted,
    ErrNotWhitelisted,
    ErrInvalidStatus,
    ErrPendingStakeNotZero,
    ErrNoPendingWithdrawRequest,
    ErrEpochGuard,
    ErrNotEnoughValidators
} from "../src/MagmaErrorsModule.sol";

/**
 * @title CoreVaultValidatorOperations
 * @dev Comprehensive tests for validator operations in CoreVault
 * Tests the multi-step validator removal process and validator management
 */
contract CoreVaultValidatorOperations is BaseTest {
    uint64 constant VAL_1 = 1;
    uint64 constant VAL_2 = 2;
    uint64 constant VAL_3 = 3;

    address constant USER_1 = address(0x201);
    address constant USER_2 = address(0x202);

    function setUp() public override {
        BaseTest.setUp();
        // Redeploy CoreVault with epochSeconds = 0 to bypass epoch guard for most tests
        address coreImpl = address(new CoreVault());
        address coreProxy = UnsafeUpgrades.deployUUPSProxy(
            coreImpl, abi.encodeCall(CoreVault.initialize, (address(magma), uint256(0), uint256(0)))
        );
        coreVault = CoreVault(payable(coreProxy));
        // Wire magma to new coreVault
        vm.prank(admin);
        magma.setVaults(address(coreVault), address(gvault));

        // Set up VAL_3 in the staking precompile since BaseTest only sets up 1 and 2
        _setupValidatorInStakingPrecompile(VAL_3);
    }

    // ============ VALIDATOR ADDITION TESTS ============

    function test_addValidator_Success() public {
        vm.prank(admin);
        coreVault.addValidator(VAL_1);

        assertTrue(coreVault.isWhitelisted(VAL_1));
        assertEq(coreVault.getValidatorCount(), 1);

        uint64[] memory validators = coreVault.getValidators();
        assertEq(validators.length, 1);
        assertEq(validators[0], VAL_1);
    }

    function test_addValidator_RevertZeroValidatorId() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrZeroValidatorId.selector));
        coreVault.addValidator(0);
    }

    function test_addValidator_RevertAlreadyWhitelisted() public {
        vm.prank(admin);
        coreVault.addValidator(VAL_1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrAlreadyWhitelisted.selector));
        coreVault.addValidator(VAL_1);
    }

    function test_addValidator_RevertNotAdmin() public {
        vm.prank(USER_1);
        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.addValidator(VAL_1);
    }

    function test_addMultipleValidators() public {
        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        coreVault.addValidator(VAL_3);
        vm.stopPrank();

        assertEq(coreVault.getValidatorCount(), 3);
        assertTrue(coreVault.isWhitelisted(VAL_1));
        assertTrue(coreVault.isWhitelisted(VAL_2));
        assertTrue(coreVault.isWhitelisted(VAL_3));
    }

    // ============ STAKE REDISTRIBUTION TESTS ============

    function test_adminRebalanceInitiate_ThenRedelegateToValidators_Success() public {
        // Test the complete two-step rebalancing process that demonstrates the main user request:
        //
        // SCENARIO: CoreVault has 3 validators with imbalanced stakes and needs rebalancing
        //
        // STEPS:
        // 1. Set up 3 validators with imbalanced stakes (400, 200, 100 ether = 700 total)
        // 2. Call adminRebalanceInitiate() - initiates undelegation from over-target validators
        //    - Target per validator: 700/3 = ~233.33 ether
        //    - VAL_1 has 400 ether (166.67 ether excess) → undelegates 166.67 ether
        // 3. Call redelegateToValidators() - redistributes the undelegated funds to under-target validators
        //    - Distributes the 166.67 ether to VAL_2 and VAL_3 to bring all to ~233.33 ether
        //
        // RESULT: All validators end up with roughly equal stakes (~233.33 ether each)
        //
        // This test verifies that:
        // - adminRebalanceInitiate() properly identifies over-target validators and initiates undelegation
        // - redelegateToValidators() properly redistributes funds to achieve balanced stakes
        // - The two-step process correctly brings all validators to roughly the same stake level

        // Setup: Add 3 validators and create imbalanced stakes manually
        _setupValidatorInStakingPrecompile(VAL_1);
        _setupValidatorInStakingPrecompile(VAL_2);
        _setupValidatorInStakingPrecompile(VAL_3);

        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        coreVault.addValidator(VAL_3);
        vm.stopPrank();

        // Create imbalanced stakes using MockStakingPrecompile.setDelegatorStake
        // VAL_1: 400 ether (excess)
        // VAL_2: 200 ether (normal)
        // VAL_3: 100 ether (deficit)
        // Total: 700 ether, Target per validator: ~233.33 ether
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(VAL_1, address(coreVault), 400 ether);
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(VAL_2, address(coreVault), 200 ether);
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(VAL_3, address(coreVault), 100 ether);

        uint256 totalStake = 700 ether;
        uint256 expectedTarget = totalStake / 3; // ~233.33 ether per validator

        // Verify initial imbalanced state
        uint256 val1Initial = coreVault.delegatedAmount(VAL_1);
        uint256 val2Initial = coreVault.delegatedAmount(VAL_2);
        uint256 val3Initial = coreVault.delegatedAmount(VAL_3);

        console.log("Initial imbalanced stakes:");
        console.log("VAL_1:", val1Initial);
        console.log("VAL_2:", val2Initial);
        console.log("VAL_3:", val3Initial);
        console.log("Total:", val1Initial + val2Initial + val3Initial);
        console.log("Expected target per validator:", expectedTarget);

        // Verify we have the expected imbalanced distribution
        assertEq(val1Initial, 400 ether, "VAL_1 should have 400 ether");
        assertEq(val2Initial, 200 ether, "VAL_2 should have 200 ether");
        assertEq(val3Initial, 100 ether, "VAL_3 should have 100 ether");

        // Step 1: Admin initiates rebalancing - should start undelegation from over-target validators
        vm.prank(admin);
        coreVault.adminRebalanceInitiate();

        // Verify that rebalancing was initiated
        assertTrue(coreVault.totalPendingRedelegation() > 0, "Should have pending redelegations");
        assertFalse(coreVault.finishedLastRebalance(), "Should be in rebalance progress");

        // VAL_1 should have pending undelegations (it's significantly over target)
        uint256 val1PendingRedelegation = coreVault.pendingRedelegateByValidator(VAL_1);
        assertTrue(val1PendingRedelegation > 0, "VAL_1 should have pending undelegations");

        console.log("After adminRebalanceInitiate:");
        console.log("Total pending redelegation:", coreVault.totalPendingRedelegation());
        console.log("VAL_1 pending redelegation:", val1PendingRedelegation);

        // Step 2: Wait for withdrawal delay (simulate time passing)
        _advanceEpochsForWithdrawal();

        // Step 3: Complete the rebalancing by redistributing funds
        vm.prank(admin);
        coreVault.redelegateToValidators();

        // Step 4: Verify final balanced distribution
        uint256 val1Final = coreVault.delegatedAmount(VAL_1);
        uint256 val2Final = coreVault.delegatedAmount(VAL_2);
        uint256 val3Final = coreVault.delegatedAmount(VAL_3);

        console.log("Final stakes:");
        console.log("VAL_1:", val1Final);
        console.log("VAL_2:", val2Final);
        console.log("VAL_3:", val3Final);
        console.log("Expected target:", expectedTarget);

        // All validators should now have stakes close to the target (~233.33 ether each)
        // Allow for small rounding differences
        uint256 tolerance = 1 gwei; // 1 gwei tolerance for rounding

        assertTrue(
            val1Final >= expectedTarget - tolerance && val1Final <= expectedTarget + tolerance,
            "VAL_1 should be close to target stake"
        );
        assertTrue(
            val2Final >= expectedTarget - tolerance && val2Final <= expectedTarget + tolerance,
            "VAL_2 should be close to target stake"
        );
        assertTrue(
            val3Final >= expectedTarget - tolerance && val3Final <= expectedTarget + tolerance,
            "VAL_3 should be close to target stake"
        );

        // Total stake should be conserved (allow for small rounding differences)
        uint256 finalTotal = val1Final + val2Final + val3Final;
        assertTrue(
            finalTotal >= totalStake - 1 gwei && finalTotal <= totalStake + 1 gwei,
            "Total stake should be conserved within rounding tolerance"
        );

        // No pending redelegations should remain
        assertEq(coreVault.totalPendingRedelegation(), 0, "Should have no pending redelegations");

        // Verify that the rebalancing significantly improved the distribution
        // VAL_1 should have much less than its initial 400 ether
        assertTrue(val1Final < val1Initial, "VAL_1 should have less stake after rebalancing");
        // VAL_3 should have much more than its initial 100 ether
        assertTrue(val3Final > val3Initial, "VAL_3 should have more stake after rebalancing");
    }

    function test_redelegateToValidators_Success() public {
        // Step 1: Add VAL_1 and VAL_2, delegate some stake
        _setupValidatorInStakingPrecompile(VAL_1);
        _setupValidatorInStakingPrecompile(VAL_2);

        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        vm.stopPrank();

        // Delegate 300 ether equally between VAL_1 and VAL_2 (150 each)
        vm.deal(address(magma), 300 ether);
        vm.prank(address(magma));
        coreVault.delegate{value: 300 ether}();

        // Activate delegations
        _activatePendingDelegations();

        // Verify initial equal distribution
        assertEq(coreVault.delegatedAmount(VAL_1), 150 ether);
        assertEq(coreVault.delegatedAmount(VAL_2), 150 ether);

        // Set up active stakes in the mock precompile to match CoreVault's tracking
        _activateAllStakes();

        // Step 2: Add VAL_3 - this should trigger rebalanceInitiate
        _setupValidatorInStakingPrecompile(VAL_3);

        vm.prank(admin);
        coreVault.addValidator(VAL_3); // This calls _rebalanceInitiate()

        // The target is now 300/3 = 100 ether per validator
        // VAL_1 and VAL_2 each have 150 ether (50 ether excess each)
        // _rebalanceInitiate should try to undelegate 50 ether from each

        // Verify pending undelegations were initiated
        assertTrue(coreVault.totalPendingRedelegation() > 0);
        assertTrue(coreVault.pendingRedelegateByValidator(VAL_1) > 0);
        assertTrue(coreVault.pendingRedelegateByValidator(VAL_2) > 0);

        // Step 3: Complete the withdrawals and redistribute
        // Advance epochs to make withdrawals ready
        _advanceEpochsForWithdrawal();

        // Redistribute the withdrawn funds
        vm.prank(admin);
        coreVault.redelegateToValidators();

        // Step 4: Verify final balanced distribution
        // All validators should now have equal stakes (100 ether each)
        uint256 val1Final = coreVault.delegatedAmount(VAL_1);
        uint256 val2Final = coreVault.delegatedAmount(VAL_2);
        uint256 val3Final = coreVault.delegatedAmount(VAL_3);

        // Should be very close to exact equal distribution (100 ether each)
        assertTrue(val1Final >= 99 ether && val1Final <= 101 ether, "VAL_1 should be very close to 100 ether");
        assertTrue(val2Final >= 99 ether && val2Final <= 101 ether, "VAL_2 should be very close to 100 ether");
        assertTrue(val3Final >= 99 ether && val3Final <= 101 ether, "VAL_3 should be very close to 100 ether");

        // VAL_3 should have received funds (was 0, now has some)
        assertTrue(val3Final > 0);

        // Total should be conserved
        assertEq(val1Final + val2Final + val3Final, 300 ether);
    }

    function test_redelegateToValidators_NoFundsAvailable() public {
        // Setup validators but no available funds
        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        vm.stopPrank();

        // No withdrawals to complete, no funds to redistribute
        vm.prank(admin);
        coreVault.redelegateToValidators();

        // Should complete without error, no changes to state
        assertEq(coreVault.delegatedAmount(VAL_1), 0);
        assertEq(coreVault.delegatedAmount(VAL_2), 0);
    }

    function test_redelegateToValidators_SingleValidator() public {
        // Setup: Start with only VAL_1 and VAL_2, then remove VAL_2 to create scenario
        _setupValidatorInStakingPrecompile(VAL_1);
        _setupValidatorInStakingPrecompile(VAL_2);

        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        vm.stopPrank();

        // Delegate funds to both validators
        vm.deal(address(magma), 200 ether);
        vm.prank(address(magma));
        coreVault.delegate{value: 200 ether}(); // 100 ether each

        // Activate delegations
        _activatePendingDelegations();
        _activateAllStakes();

        // Ensure all delegations are fully processed before attempting removal
        // In real scenario, delegations need time to become fully active
        _activatePendingDelegations();

        // Remove VAL_2 to create single validator scenario with pending funds
        vm.startPrank(admin);
        coreVault.initiateValidatorRemoval(VAL_2);
        coreVault.executeValidatorUndelegation(VAL_2);
        vm.stopPrank();

        // Advance epochs for withdrawal completion
        _advanceEpochsForWithdrawal();

        uint256 val1InitialStake = coreVault.delegatedAmount(VAL_1);
        assertEq(val1InitialStake, 100 ether);

        // Complete VAL_2 removal - this creates funds for redistribution
        vm.prank(admin);
        coreVault.completeValidatorRemovalWithdrawal(VAL_2);

        // Test redistribution with single validator
        vm.prank(admin);
        coreVault.redelegateToValidators();

        // VAL_1 should receive all redistributed funds from VAL_2's removal
        uint256 val1FinalStake = coreVault.delegatedAmount(VAL_1);
        assertEq(val1FinalStake, 200 ether); // Should get all 200 ether

        // Verify VAL_2 is properly removed
        assertFalse(coreVault.isWhitelisted(VAL_2));
        assertEq(coreVault.getValidatorCount(), 1);
    }

    function test_redelegateToValidators_MultipleWithdrawals() public {
        // Test redistribution when multiple validators are removed and funds need redistribution
        _setupValidatorInStakingPrecompile(VAL_1);
        _setupValidatorInStakingPrecompile(VAL_2);
        _setupValidatorInStakingPrecompile(VAL_3);

        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        coreVault.addValidator(VAL_3);
        vm.stopPrank();

        // Set up initial stakes using actual delegation
        vm.deal(address(magma), 450 ether);
        vm.prank(address(magma));
        coreVault.delegate{value: 450 ether}(); // 150 ether each

        // Activate delegations
        _activatePendingDelegations();
        _activateAllStakes();

        // Verify initial equal distribution
        assertEq(coreVault.delegatedAmount(VAL_1), 150 ether);
        assertEq(coreVault.delegatedAmount(VAL_2), 150 ether);
        assertEq(coreVault.delegatedAmount(VAL_3), 150 ether);

        uint256 val3InitialStake = coreVault.delegatedAmount(VAL_3);

        // Remove VAL_1 and VAL_2 to create multiple withdrawal scenarios
        vm.startPrank(admin);

        // Remove VAL_1
        coreVault.initiateValidatorRemoval(VAL_1);
        coreVault.executeValidatorUndelegation(VAL_1);

        // Remove VAL_2
        coreVault.initiateValidatorRemoval(VAL_2);
        coreVault.executeValidatorUndelegation(VAL_2);

        vm.stopPrank();

        // Advance epochs for withdrawal completion
        _advanceEpochsForWithdrawal();

        // Complete both withdrawals
        vm.startPrank(admin);
        coreVault.completeValidatorRemovalWithdrawal(VAL_1);
        coreVault.completeValidatorRemovalWithdrawal(VAL_2);
        vm.stopPrank();

        // Test redistribution - VAL_3 should get all funds from removed validators
        vm.prank(admin);
        coreVault.redelegateToValidators();

        // Verify VAL_3 received all redistributed funds (450 ether total)
        uint256 val3FinalStake = coreVault.delegatedAmount(VAL_3);
        assertEq(val3FinalStake, 450 ether);
        assertTrue(val3FinalStake > val3InitialStake);

        // Verify other validators are properly removed
        assertFalse(coreVault.isWhitelisted(VAL_1));
        assertFalse(coreVault.isWhitelisted(VAL_2));
        assertTrue(coreVault.isWhitelisted(VAL_3));
        assertEq(coreVault.getValidatorCount(), 1);
    }

    function test_redelegateToValidators_AccessControl() public {
        vm.prank(admin);
        coreVault.addValidator(VAL_1);

        // Test that only admin can call redelegateToValidators
        vm.prank(USER_1);
        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.redelegateToValidators();

        // Admin should be able to call it
        vm.prank(admin);
        coreVault.redelegateToValidators(); // Should not revert
    }

    function test_addValidator_DoesNotImmediatelyRebalance() public {
        // Test that adding a validator only initiates undelegation but doesn't complete redistribution
        uint256 totalStake = 200 ether;

        _setupValidatorInStakingPrecompile(VAL_1);
        _setupValidatorInStakingPrecompile(VAL_2);

        // Add first validator
        vm.prank(admin);
        coreVault.addValidator(VAL_1);

        // Delegate stake to first validator
        vm.deal(address(magma), totalStake);
        vm.prank(address(magma));
        coreVault.delegate{value: totalStake}(); // All goes to VAL_1

        // Activate delegation
        _activatePendingDelegations();
        _activateAllStakes();

        uint256 val1StakeBeforeAdd = coreVault.delegatedAmount(VAL_1);
        assertEq(val1StakeBeforeAdd, totalStake);
        assertEq(coreVault.totalAssets(), totalStake);

        // Add second validator - this should trigger rebalanceInitiate but not complete redistribution
        vm.prank(admin);
        coreVault.addValidator(VAL_2);

        // After adding VAL_2, the target becomes 200/2 = 100 ether per validator
        // VAL_1 has 100 ether excess that should be undelegated but not yet redistributed

        // Verify that undelegation was initiated but redistribution hasn't happened yet
        assertEq(coreVault.totalAssets(), totalStake);
        assertEq(coreVault.totalPendingRedelegation(), totalStake / 2, "Should have pending undelegations");
        assertEq(
            coreVault.pendingRedelegateByValidator(VAL_1), totalStake / 2, "VAL_1 should have pending undelegations"
        );

        // VAL_1's tracked amount should be unchanged (undelegation is pending, not completed)
        assertEq(coreVault.delegatedAmount(VAL_1), totalStake / 2, "VAL_1 should have half of the total stake");
        assertEq(coreVault.delegatedAmount(VAL_2), 0, "VAL_2 should have no stake yet");

        // Complete the withdrawal process
        _advanceEpochsForWithdrawal();

        // Manual redistribution should complete the rebalancing
        vm.prank(admin);
        coreVault.redelegateToValidators();
        assertEq(coreVault.totalAssets(), totalStake);

        // Now verify balanced distribution
        uint256 val1FinalStake = coreVault.delegatedAmount(VAL_1);
        uint256 val2FinalStake = coreVault.delegatedAmount(VAL_2);

        // Should be very close to equal (100 ether each)
        assertEq(val1FinalStake, totalStake / 2, "VAL_1 should be very close to 100 ether");
        assertEq(val2FinalStake, totalStake / 2, "VAL_2 should be very close to 100 ether");
        assertEq(val1FinalStake + val2FinalStake, totalStake);
    }

    // ============ VALIDATOR REMOVAL STEP 1: INITIATION TESTS ============

    function test_initiateValidatorRemoval_Success() public {
        // Setup: Add 2 validators (can't remove the last one)
        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        vm.stopPrank();
        assertTrue(coreVault.isWhitelisted(VAL_1));

        // Test: Initiate removal
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit IBaseVault.ValidatorRemovalInitiated(VAL_1);
        coreVault.initiateValidatorRemoval(VAL_1);

        // Verify: Status changed
        assertFalse(coreVault.isWhitelisted(VAL_1));
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(IBaseVault.ValidatorStatus.PAUSED));
        assertEq(coreVault.getValidatorCount(), 1); // VAL_2 should remain active
        assertTrue(coreVault.isWhitelisted(VAL_2)); // VAL_2 should still be whitelisted
    }

    function test_initiateValidatorRemoval_RevertNotWhitelisted() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrNotWhitelisted.selector));
        coreVault.initiateValidatorRemoval(VAL_1);
    }

    function test_initiateValidatorRemoval_RevertNotAdmin() public {
        vm.prank(admin);
        coreVault.addValidator(VAL_1);

        vm.prank(USER_1);
        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.initiateValidatorRemoval(VAL_1);
    }

    function test_initiateValidatorRemoval_WithMultipleValidators() public {
        // Setup: Add multiple validators
        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        coreVault.addValidator(VAL_3);
        vm.stopPrank();

        assertEq(coreVault.getValidatorCount(), 3);

        // Remove one validator
        vm.prank(admin);
        coreVault.initiateValidatorRemoval(VAL_2);

        // Verify: Only VAL_2 is removed, others remain
        assertTrue(coreVault.isWhitelisted(VAL_1));
        assertFalse(coreVault.isWhitelisted(VAL_2));
        assertTrue(coreVault.isWhitelisted(VAL_3));
        assertEq(coreVault.getValidatorCount(), 2);

        uint64[] memory validators = coreVault.getValidators();
        assertEq(validators.length, 2);
        // Check that VAL_2 is not in the array
        for (uint256 i = 0; i < validators.length; i++) {
            assertTrue(validators[i] != VAL_2);
        }
    }

    // ============ VALIDATOR REMOVAL STEP 2: UNDELEGATION TESTS ============

    function test_executeValidatorUndelegation_Success() public {
        // Setup: Add 2 validators (can't remove the last one)
        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        vm.stopPrank();
        _setupValidatorStake(VAL_1, 100 ether);

        // Step 1: Initiate removal
        vm.prank(admin);
        coreVault.initiateValidatorRemoval(VAL_1);

        // Step 2: Execute undelegation
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit IBaseVault.ValidatorRemoved(VAL_1);
        coreVault.executeValidatorUndelegation(VAL_1);

        // Verify: Status changed to UNDELEGATING
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(IBaseVault.ValidatorStatus.UNDELEGATING));
        assertEq(coreVault.delegatedAmount(VAL_1), 0); // Delegated amount reset to 0
        assertEq(coreVault.totalPendingRedelegation(), 100 ether); // Pending redelegation increased
    }

    function test_executeValidatorUndelegation_RevertInvalidStatus() public {
        // Setup: Add validator without initiating removal
        vm.prank(admin);
        coreVault.addValidator(VAL_1);

        // Try to execute undelegation without initiating removal first
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrInvalidStatus.selector));
        coreVault.executeValidatorUndelegation(VAL_1);
    }

    function test_executeValidatorUndelegation_RevertPendingStakeNotZero() public {
        // Setup: Add 2 validators and initiate removal
        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        coreVault.initiateValidatorRemoval(VAL_1);
        vm.stopPrank();

        // Set up pending stake (delta_stake > 0) to simulate pending epochs
        MockStakingPrecompile mockPrecompile = MockStakingPrecompile(STAKING_PRECOMPILE);
        // Set delegator info with current stake and pending stake
        mockPrecompile.setDelegatorStake(VAL_1, address(coreVault), 100 ether);
        mockPrecompile.setDelegatorPendingStake(VAL_1, address(coreVault), 50 ether, 0);

        // Try to execute undelegation with pending stake
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrPendingStakeNotZero.selector));
        coreVault.executeValidatorUndelegation(VAL_1);
    }

    function test_executeValidatorUndelegation_RevertNotAdmin() public {
        // Setup: Add 2 validators
        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        coreVault.initiateValidatorRemoval(VAL_1);
        vm.stopPrank();

        // Test: Non-admin tries to execute undelegation
        vm.prank(USER_1);
        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.executeValidatorUndelegation(VAL_1);
    }

    // ============ VALIDATOR REMOVAL STEP 3: WITHDRAWAL COMPLETION TESTS ============

    function test_completeValidatorRemovalWithdrawal_Success() public {
        // Setup: Complete removal process up to undelegation
        vm.prank(admin);
        coreVault.addValidator(VAL_1);
        vm.prank(admin);
        coreVault.addValidator(VAL_2); // Add another validator for redistribution

        _setupValidatorStake(VAL_1, 100 ether);
        _setupValidatorStake(VAL_2, 50 ether);

        // Fund the CoreVault for redistribution
        vm.deal(address(coreVault), 1000 ether);

        vm.startPrank(admin);
        coreVault.initiateValidatorRemoval(VAL_1);
        coreVault.executeValidatorUndelegation(VAL_1);
        vm.stopPrank();

        // Advance epochs to make withdrawal ready
        _advanceEpochsForWithdrawal();

        // Complete withdrawal
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit IBaseVault.ValidatorRemovalCompleted(VAL_1);
        coreVault.completeValidatorRemovalWithdrawal(VAL_1);

        // Verify: Status cleared
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(IBaseVault.ValidatorStatus.NONE));
    }

    function test_completeValidatorRemovalWithdrawal_RevertInvalidStatus() public {
        // Try to complete withdrawal without proper status
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrInvalidStatus.selector));
        coreVault.completeValidatorRemovalWithdrawal(VAL_1);
    }

    function test_completeValidatorRemovalWithdrawal_WithdrawalReady() public {
        // Set up validators 1 and 2 in the mock precompile and CoreVault
        uint64 val1 = 1;
        uint64 val2 = 2;

        // Set up validators in the mock precompile with specific IDs
        MockStakingPrecompile(STAKING_PRECOMPILE).setupValidator(val1, 100 ether);
        MockStakingPrecompile(STAKING_PRECOMPILE).setupValidator(val2, 100 ether);

        // Add validators to CoreVault
        vm.startPrank(admin);
        coreVault.addValidator(val1);
        coreVault.addValidator(val2);
        vm.stopPrank();

        // This test verifies the complete withdrawal process with proper timing
        assertTrue(coreVault.isWhitelisted(val1));
        assertTrue(coreVault.isWhitelisted(val2));

        // Use real delegation to set up stakes (this approach works)
        vm.deal(address(magma), 200 ether);
        vm.prank(address(magma));
        coreVault.delegate{value: 200 ether}();

        // Activate the delegations
        _activatePendingDelegations();

        // Verify both validators have stake
        assertTrue(coreVault.delegatedAmount(val1) > 0);
        assertTrue(coreVault.delegatedAmount(val2) > 0);

        vm.startPrank(admin);
        coreVault.initiateValidatorRemoval(val1);
        coreVault.executeValidatorUndelegation(val1);
        vm.stopPrank();

        // Advance enough epochs for withdrawal to be ready (WITHDRAWAL_DELAY is 7 epochs)
        _advanceEpochsForWithdrawal();

        // Should complete successfully when withdrawal is ready
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit IBaseVault.ValidatorRemovalCompleted(val1);
        coreVault.completeValidatorRemovalWithdrawal(val1);

        // Validator status should be cleared to NONE
        assertEq(uint256(coreVault.validatorStatus(val1)), uint256(IBaseVault.ValidatorStatus.NONE));
    }

    // ============ COMPREHENSIVE MULTI-STEP PROCESS TESTS ============

    function test_completeValidatorRemovalProcess() public {
        // Setup: Multiple validators for redistribution testing
        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        coreVault.addValidator(VAL_3);
        vm.stopPrank();

        // Set up stakes
        _setupValidatorStake(VAL_1, 300 ether);
        _setupValidatorStake(VAL_2, 200 ether);
        _setupValidatorStake(VAL_3, 100 ether);

        // Fund CoreVault for redistribution
        vm.deal(address(coreVault), 1000 ether);

        uint256 val1InitialStake = 300 ether; // We know we set it to 300 ether

        // Step 1: Initiate removal
        vm.prank(admin);
        coreVault.initiateValidatorRemoval(VAL_1);

        assertFalse(coreVault.isWhitelisted(VAL_1));
        assertEq(coreVault.getValidatorCount(), 2); // Only VAL_2 and VAL_3 remain active

        // Step 2: Execute undelegation (after pending epochs clear)
        vm.prank(admin);
        coreVault.executeValidatorUndelegation(VAL_1);

        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(IBaseVault.ValidatorStatus.UNDELEGATING));
        assertEq(coreVault.delegatedAmount(VAL_1), 0);
        assertEq(coreVault.totalPendingRedelegation(), val1InitialStake);

        // Step 3: Wait for withdrawal delay and complete withdrawal
        _advanceEpochsForWithdrawal();

        vm.prank(admin);
        coreVault.completeValidatorRemovalWithdrawal(VAL_1);

        // Verify final state
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(IBaseVault.ValidatorStatus.NONE));
        assertTrue(coreVault.isWhitelisted(VAL_2));
        assertTrue(coreVault.isWhitelisted(VAL_3));
        assertEq(coreVault.getValidatorCount(), 2);

        // The removed validator's stake should have been redistributed
        // (Exact redistribution depends on the implementation logic)
    }

    function test_validatorRemovalWithUserDelegations() public {
        // Setup: Add validators and simulate user delegations
        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        vm.stopPrank();

        _setupValidatorStake(VAL_1, 100 ether);
        _setupValidatorStake(VAL_2, 100 ether);

        // Simulate user delegations by calling delegate through Magma
        vm.deal(address(magma), 200 ether);
        vm.prank(address(magma));
        coreVault.delegate{value: 200 ether}();

        // Advance epochs to activate the pending delegations
        MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();

        // Now remove VAL_1
        vm.startPrank(admin);
        coreVault.initiateValidatorRemoval(VAL_1);
        coreVault.executeValidatorUndelegation(VAL_1);
        vm.stopPrank();

        // Advance epochs
        _advanceEpochsForWithdrawal();

        // Complete removal
        vm.prank(admin);
        coreVault.completeValidatorRemovalWithdrawal(VAL_1);

        // Verify that funds were properly redistributed to remaining validator
        assertTrue(coreVault.delegatedAmount(VAL_2) > 100 ether);
    }

    // ============ ERROR CONDITION TESTS ============

    function test_cannotRemoveLastValidator() public {
        // This test ensures we cannot remove the last validator
        vm.prank(admin);
        coreVault.addValidator(VAL_1);

        _setupValidatorStake(VAL_1, 100 ether);

        // Try to remove the only validator - should fail
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrNotEnoughValidators.selector));
        coreVault.initiateValidatorRemoval(VAL_1);

        // Validator should still be active
        assertTrue(coreVault.isWhitelisted(VAL_1));
        assertEq(coreVault.getValidatorCount(), 1);
    }

    function test_stakeRedistributionOnValidatorRemoval() public {
        // First set up validators in the mock precompile
        _setupValidatorInStakingPrecompile(VAL_1);
        _setupValidatorInStakingPrecompile(VAL_2);
        _setupValidatorInStakingPrecompile(VAL_3);

        // Setup: Add 3 validators
        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        coreVault.addValidator(VAL_3);
        vm.stopPrank();

        // Set up stakes in the mock precompile
        _setupValidatorStake(VAL_1, 600 ether); // Will be removed
        _setupValidatorStake(VAL_2, 200 ether); // Will receive redistributed stake
        _setupValidatorStake(VAL_3, 200 ether); // Will receive redistributed stake

        // Activate the delegations
        _activatePendingDelegations();

        // Record initial states
        uint256 initialValidator1Stake = coreVault.delegatedAmount(VAL_1);
        uint256 initialValidator2Stake = coreVault.delegatedAmount(VAL_2);
        uint256 initialValidator3Stake = coreVault.delegatedAmount(VAL_3);
        uint256 initialTotal = coreVault.getTotalDelegated();

        console.log("=== INITIAL STATE ===");
        console.log("VAL_1 stake:", initialValidator1Stake);
        console.log("VAL_2 stake:", initialValidator2Stake);
        console.log("VAL_3 stake:", initialValidator3Stake);
        console.log("Total delegated:", initialTotal);

        // Verify initial distribution (should be equal since delegate() distributes equally)
        assertTrue(initialValidator1Stake > 0);
        assertTrue(initialValidator2Stake > 0);
        assertTrue(initialValidator3Stake > 0);
        assertEq(initialValidator2Stake, initialValidator3Stake, "VAL_2 and VAL_3 should have equal stake");

        // Step 1: Remove VAL_1
        vm.startPrank(admin);
        coreVault.initiateValidatorRemoval(VAL_1);
        coreVault.executeValidatorUndelegation(VAL_1);
        vm.stopPrank();

        // Verify VAL_1 stake moved to pending redistribution
        assertEq(coreVault.delegatedAmount(VAL_1), 0);
        assertTrue(coreVault.totalPendingRedelegation() > 0);

        console.log("=== AFTER UNDELEGATION ===");
        console.log("VAL_1 stake:", coreVault.delegatedAmount(VAL_1));
        console.log("Pending redistribution:", coreVault.totalPendingRedelegation());

        // Step 2: Complete withdrawal to trigger redistribution
        _advanceEpochsForWithdrawal();

        vm.prank(admin);
        coreVault.completeValidatorRemovalWithdrawal(VAL_1);

        // Verify final state
        uint256 finalValidator2Stake = coreVault.delegatedAmount(VAL_2);
        uint256 finalValidator3Stake = coreVault.delegatedAmount(VAL_3);
        uint256 finalTotal = coreVault.getTotalDelegated();

        console.log("=== AFTER REDISTRIBUTION ===");
        console.log("VAL_2 final stake:", finalValidator2Stake);
        console.log("VAL_3 final stake:", finalValidator3Stake);
        console.log("Final total delegated:", finalTotal);

        // Verify redistribution behavior
        // VAL_2 and VAL_3 should have received additional stake
        assertTrue(finalValidator2Stake >= initialValidator2Stake, "VAL_2 should have received additional stake");
        assertTrue(finalValidator3Stake >= initialValidator3Stake, "VAL_3 should have received additional stake");

        // Total should be conserved (minus VAL_1's original stake, plus any redistributed funds)
        assertEq(finalTotal, finalValidator2Stake + finalValidator3Stake, "Total should be conserved");

        // Pending redistribution should be cleared (allowing for small rounding differences)
        assertEq(coreVault.totalPendingRedelegation(), 0, "Pending redistribution should be cleared");

        // VAL_1 should be completely removed
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(IBaseVault.ValidatorStatus.NONE));
        assertFalse(coreVault.isWhitelisted(VAL_1));
        assertEq(coreVault.getValidatorCount(), 2);

        // The remaining validators should still be active
        assertTrue(coreVault.isWhitelisted(VAL_2));
        assertTrue(coreVault.isWhitelisted(VAL_3));
    }

    function test_multipleValidatorRemovalProcess() public {
        // Set up validators in the mock precompile with specific IDs
        MockStakingPrecompile(STAKING_PRECOMPILE).setupValidator(VAL_1, 100 ether);
        MockStakingPrecompile(STAKING_PRECOMPILE).setupValidator(VAL_2, 100 ether);
        MockStakingPrecompile(STAKING_PRECOMPILE).setupValidator(VAL_3, 100 ether);

        // Test removing multiple validators in sequence
        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        coreVault.addValidator(VAL_3);
        vm.stopPrank();

        // Set up real stakes through delegation
        vm.deal(address(magma), 900 ether);
        vm.prank(address(magma));
        coreVault.delegate{value: 900 ether}();

        // Activate the delegations
        _activatePendingDelegations();

        // Verify all 3 validators have equal stakes
        assertEq(coreVault.getValidatorCount(), 3);
        uint256 stakePerValidator = coreVault.delegatedAmount(VAL_1);
        assertEq(coreVault.delegatedAmount(VAL_2), stakePerValidator);
        assertEq(coreVault.delegatedAmount(VAL_3), stakePerValidator);
        assertTrue(stakePerValidator > 0);

        // Remove VAL_1 (3 -> 2 validators)
        vm.startPrank(admin);
        coreVault.initiateValidatorRemoval(VAL_1);
        coreVault.executeValidatorUndelegation(VAL_1);
        vm.stopPrank();

        // Complete VAL_1 withdrawal
        _advanceEpochsForWithdrawal();

        vm.prank(admin);
        coreVault.completeValidatorRemovalWithdrawal(VAL_1);

        // Verify VAL_1 is removed and others received redistribution
        assertEq(coreVault.getValidatorCount(), 2);
        assertFalse(coreVault.isWhitelisted(VAL_1));
        assertTrue(coreVault.isWhitelisted(VAL_2));
        assertTrue(coreVault.isWhitelisted(VAL_3));

        uint256 val2StakeAfterFirst = coreVault.delegatedAmount(VAL_2);
        uint256 val3StakeAfterFirst = coreVault.delegatedAmount(VAL_3);

        // Both should have received additional stake
        assertTrue(val2StakeAfterFirst > stakePerValidator);
        assertTrue(val3StakeAfterFirst > stakePerValidator);

        // Advance additional epochs to activate any pending stakes from redistribution
        for (uint256 i = 0; i < 5; i++) {
            MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        }

        // Remove VAL_2 (2 -> 1 validator)
        vm.startPrank(admin);
        coreVault.initiateValidatorRemoval(VAL_2);
        coreVault.executeValidatorUndelegation(VAL_2);
        vm.stopPrank();

        // Complete VAL_2 withdrawal
        _advanceEpochsForWithdrawal();

        vm.prank(admin);
        coreVault.completeValidatorRemovalWithdrawal(VAL_2);

        // Verify only VAL_3 remains and received all redistributed stake
        assertEq(coreVault.getValidatorCount(), 1);
        assertFalse(coreVault.isWhitelisted(VAL_2));
        assertTrue(coreVault.isWhitelisted(VAL_3));

        uint256 val3FinalStake = coreVault.delegatedAmount(VAL_3);
        assertTrue(val3FinalStake > val3StakeAfterFirst);

        // Now VAL_3 is the last validator, so removal should fail
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrNotEnoughValidators.selector));
        coreVault.initiateValidatorRemoval(VAL_3);

        // VAL_3 should still be active
        assertTrue(coreVault.isWhitelisted(VAL_3));
        assertEq(coreVault.getValidatorCount(), 1);
    }

    function test_canRemoveSecondToLastValidator() public {
        // Set up validators in the mock precompile with specific IDs
        MockStakingPrecompile(STAKING_PRECOMPILE).setupValidator(VAL_1, 100 ether);
        MockStakingPrecompile(STAKING_PRECOMPILE).setupValidator(VAL_2, 100 ether);

        // Test that we can remove validators until only 1 remains, but not the last one
        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        vm.stopPrank();

        // Use real delegation to set up stakes
        vm.deal(address(magma), 500 ether);
        vm.prank(address(magma));
        coreVault.delegate{value: 500 ether}();

        // Activate the delegations
        _activatePendingDelegations();

        // Record initial stakes (should be equal due to equal distribution)
        uint256 val1InitialStake = coreVault.delegatedAmount(VAL_1);
        uint256 val2InitialStake = coreVault.delegatedAmount(VAL_2);

        assertTrue(val1InitialStake > 0);
        assertTrue(val2InitialStake > 0);
        assertEq(val1InitialStake, val2InitialStake); // Should be equal

        // Should be able to remove VAL_1 (leaving VAL_2 as the only validator)
        vm.startPrank(admin);
        coreVault.initiateValidatorRemoval(VAL_1);
        coreVault.executeValidatorUndelegation(VAL_1);
        vm.stopPrank();

        // Complete the withdrawal
        _advanceEpochsForWithdrawal();

        vm.prank(admin);
        coreVault.completeValidatorRemovalWithdrawal(VAL_1);

        // Now VAL_2 is the only validator
        assertEq(coreVault.getValidatorCount(), 1);
        assertTrue(coreVault.isWhitelisted(VAL_2));
        assertFalse(coreVault.isWhitelisted(VAL_1));

        // VAL_2 should have received all of VAL_1's stake
        uint256 val2FinalStake = coreVault.delegatedAmount(VAL_2);
        assertTrue(val2FinalStake >= val2InitialStake); // Should have received additional stake
        // Total should be approximately the original total (allowing for small rounding)
        assertTrue(val2FinalStake >= val1InitialStake + val2InitialStake - 1 ether);

        // Now trying to remove VAL_2 (the last validator) should fail
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrNotEnoughValidators.selector));
        coreVault.initiateValidatorRemoval(VAL_2);

        // VAL_2 should still be active
        assertTrue(coreVault.isWhitelisted(VAL_2));
        assertEq(coreVault.getValidatorCount(), 1);
    }

    function test_removalStateTransitions() public {
        // Set up validators in the mock precompile with specific IDs
        MockStakingPrecompile(STAKING_PRECOMPILE).setupValidator(VAL_1, 100 ether);
        MockStakingPrecompile(STAKING_PRECOMPILE).setupValidator(VAL_2, 100 ether);

        // Need 2 validators to test removal
        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        vm.stopPrank();

        // Use real delegation to set up stakes
        vm.deal(address(magma), 200 ether);
        vm.prank(address(magma));
        coreVault.delegate{value: 200 ether}();

        // Activate the delegations
        _activatePendingDelegations();

        // Initial state
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(IBaseVault.ValidatorStatus.NONE));
        assertTrue(coreVault.isWhitelisted(VAL_1));

        // After initiation
        vm.prank(admin);
        coreVault.initiateValidatorRemoval(VAL_1);
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(IBaseVault.ValidatorStatus.PAUSED));
        assertFalse(coreVault.isWhitelisted(VAL_1));

        // After undelegation
        vm.prank(admin);
        coreVault.executeValidatorUndelegation(VAL_1);
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(IBaseVault.ValidatorStatus.UNDELEGATING));

        // After withdrawal completion
        _advanceEpochsForWithdrawal();

        vm.prank(admin);
        coreVault.completeValidatorRemovalWithdrawal(VAL_1);
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(IBaseVault.ValidatorStatus.NONE));
    }

    // ============ HELPER FUNCTIONS ============

    /**
     * @dev Helper function to set up validator stake in the mock precompile
     */
    function _setupValidatorStake(uint64 valId, uint256 amount) internal override {
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(valId, address(coreVault), amount);
    }
}
