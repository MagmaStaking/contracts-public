// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseTest} from "./BaseTest.t.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {CoreVault} from "../src/CoreVault.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
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
    uint64 constant VAL_1 = uint64(uint160(address(0x101)));
    uint64 constant VAL_2 = uint64(uint160(address(0x102)));
    uint64 constant VAL_3 = uint64(uint160(address(0x103)));

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
    }

    // ============ VALIDATOR ADDITION TESTS ============

    function testAddValidator_Success() public {
        vm.prank(admin);
        coreVault.addValidator(VAL_1);

        assertTrue(coreVault.isWhitelisted(VAL_1));
        assertEq(coreVault.getValidatorCount(), 1);

        uint64[] memory validators = coreVault.getValidators();
        assertEq(validators.length, 1);
        assertEq(validators[0], VAL_1);
    }

    function testAddValidator_RevertZeroValidatorId() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrZeroValidatorId.selector));
        coreVault.addValidator(0);
    }

    function testAddValidator_RevertAlreadyWhitelisted() public {
        vm.prank(admin);
        coreVault.addValidator(VAL_1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrAlreadyWhitelisted.selector));
        coreVault.addValidator(VAL_1);
    }

    function testAddValidator_RevertNotAdmin() public {
        vm.prank(USER_1);
        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.addValidator(VAL_1);
    }

    function testAddMultipleValidators() public {
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

    // ============ VALIDATOR REMOVAL STEP 1: INITIATION TESTS ============

    function testInitiateValidatorRemoval_Success() public {
        // Setup: Add 2 validators (can't remove the last one)
        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        vm.stopPrank();
        assertTrue(coreVault.isWhitelisted(VAL_1));

        // Test: Initiate removal
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit ICoreVault.ValidatorRemovalInitiated(VAL_1);
        coreVault.initiateValidatorRemoval(VAL_1);

        // Verify: Status changed
        assertFalse(coreVault.isWhitelisted(VAL_1));
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(CoreVault.ValidatorStatus.PAUSED));
        assertEq(coreVault.getValidatorCount(), 1); // VAL_2 should remain active
        assertTrue(coreVault.isWhitelisted(VAL_2)); // VAL_2 should still be whitelisted
    }

    function testInitiateValidatorRemoval_RevertNotWhitelisted() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrNotWhitelisted.selector));
        coreVault.initiateValidatorRemoval(VAL_1);
    }

    function testInitiateValidatorRemoval_RevertNotAdmin() public {
        vm.prank(admin);
        coreVault.addValidator(VAL_1);

        vm.prank(USER_1);
        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.initiateValidatorRemoval(VAL_1);
    }

    function testInitiateValidatorRemoval_WithMultipleValidators() public {
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

    function testExecuteValidatorUndelegation_Success() public {
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
        emit ICoreVault.ValidatorRemoved(VAL_1);
        coreVault.executeValidatorUndelegation(VAL_1);

        // Verify: Status changed to UNDELEGATING
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(CoreVault.ValidatorStatus.UNDELEGATING));
        assertEq(coreVault.delegatedAmount(VAL_1), 0); // Delegated amount reset to 0
        assertEq(coreVault.pendingRedelegationTotal(), 100 ether); // Pending redelegation increased
    }

    function testExecuteValidatorUndelegation_RevertInvalidStatus() public {
        // Setup: Add validator without initiating removal
        vm.prank(admin);
        coreVault.addValidator(VAL_1);

        // Try to execute undelegation without initiating removal first
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrInvalidStatus.selector));
        coreVault.executeValidatorUndelegation(VAL_1);
    }

    function testExecuteValidatorUndelegation_RevertPendingStakeNotZero() public {
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

    function testExecuteValidatorUndelegation_RevertNotAdmin() public {
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

    function testCompleteValidatorRemovalWithdrawal_Success() public {
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
        for (uint256 i = 0; i < 8; i++) {
            MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        }

        // Complete withdrawal
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit ICoreVault.ValidatorRemovalCompleted(VAL_1);
        coreVault.completeValidatorRemovalWithdrawal(VAL_1);

        // Verify: Status cleared
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(CoreVault.ValidatorStatus.NONE));
    }

    function testCompleteValidatorRemovalWithdrawal_RevertInvalidStatus() public {
        // Try to complete withdrawal without proper status
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrInvalidStatus.selector));
        coreVault.completeValidatorRemovalWithdrawal(VAL_1);
    }

    function testCompleteValidatorRemovalWithdrawal_WithdrawalReady() public {
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
        MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();

        // Verify both validators have stake
        assertTrue(coreVault.delegatedAmount(val1) > 0);
        assertTrue(coreVault.delegatedAmount(val2) > 0);

        vm.startPrank(admin);
        coreVault.initiateValidatorRemoval(val1);
        coreVault.executeValidatorUndelegation(val1);
        vm.stopPrank();

        // Advance enough epochs for withdrawal to be ready (WITHDRAWAL_DELAY is 7 epochs)
        for (uint256 i = 0; i < 8; i++) {
            MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        }

        // Should complete successfully when withdrawal is ready
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit ICoreVault.ValidatorRemovalCompleted(val1);
        coreVault.completeValidatorRemovalWithdrawal(val1);

        // Validator status should be cleared to NONE
        assertEq(uint256(coreVault.validatorStatus(val1)), uint256(CoreVault.ValidatorStatus.NONE));
    }

    // ============ COMPREHENSIVE MULTI-STEP PROCESS TESTS ============

    function testCompleteValidatorRemovalProcess() public {
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

        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(CoreVault.ValidatorStatus.UNDELEGATING));
        assertEq(coreVault.delegatedAmount(VAL_1), 0);
        assertEq(coreVault.pendingRedelegationTotal(), val1InitialStake);

        // Step 3: Wait for withdrawal delay and complete withdrawal
        for (uint256 i = 0; i < 8; i++) {
            MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        }

        vm.prank(admin);
        coreVault.completeValidatorRemovalWithdrawal(VAL_1);

        // Verify final state
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(CoreVault.ValidatorStatus.NONE));
        assertTrue(coreVault.isWhitelisted(VAL_2));
        assertTrue(coreVault.isWhitelisted(VAL_3));
        assertEq(coreVault.getValidatorCount(), 2);

        // The removed validator's stake should have been redistributed
        // (Exact redistribution depends on the implementation logic)
    }

    function testValidatorRemovalWithUserDelegations() public {
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
        for (uint256 i = 0; i < 8; i++) {
            MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        }

        // Complete removal
        vm.prank(admin);
        coreVault.completeValidatorRemovalWithdrawal(VAL_1);

        // Verify that funds were properly redistributed to remaining validator
        assertTrue(coreVault.delegatedAmount(VAL_2) > 100 ether);
    }

    // ============ ERROR CONDITION TESTS ============

    function testCannotRemoveLastValidator() public {
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

    function testStakeRedistributionOnValidatorRemoval() public {
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

        // Use the actual delegation mechanism to set up real stakes
        // This ensures CoreVault's internal state is properly updated
        vm.deal(address(magma), 1000 ether);
        vm.prank(address(magma));
        coreVault.delegate{value: 1000 ether}();

        // Activate the delegations
        MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();

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
        assertEq(initialValidator1Stake, initialValidator2Stake);
        assertEq(initialValidator2Stake, initialValidator3Stake);

        // Step 1: Remove VAL_1
        vm.startPrank(admin);
        coreVault.initiateValidatorRemoval(VAL_1);
        coreVault.executeValidatorUndelegation(VAL_1);
        vm.stopPrank();

        // Verify VAL_1 stake moved to pending redistribution
        assertEq(coreVault.delegatedAmount(VAL_1), 0);
        assertTrue(coreVault.pendingRedelegationTotal() > 0);

        console.log("=== AFTER UNDELEGATION ===");
        console.log("VAL_1 stake:", coreVault.delegatedAmount(VAL_1));
        console.log("Pending redistribution:", coreVault.pendingRedelegationTotal());

        // Step 2: Complete withdrawal to trigger redistribution
        for (uint256 i = 0; i < 8; i++) {
            MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        }

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
        assertTrue(finalValidator2Stake >= initialValidator2Stake);
        assertTrue(finalValidator3Stake >= initialValidator3Stake);

        // Total should be conserved (minus VAL_1's original stake, plus any redistributed funds)
        assertEq(finalTotal, finalValidator2Stake + finalValidator3Stake);

        // Pending redistribution should be cleared (allowing for small rounding differences)
        assertTrue(coreVault.pendingRedelegationTotal() < 1 ether); // Allow small rounding errors

        // VAL_1 should be completely removed
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(CoreVault.ValidatorStatus.NONE));
        assertFalse(coreVault.isWhitelisted(VAL_1));
        assertEq(coreVault.getValidatorCount(), 2);

        // The remaining validators should still be active
        assertTrue(coreVault.isWhitelisted(VAL_2));
        assertTrue(coreVault.isWhitelisted(VAL_3));
    }

    function testMultipleValidatorRemovalProcess() public {
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
        MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();

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
        for (uint256 i = 0; i < 8; i++) {
            MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        }
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
        for (uint256 i = 0; i < 8; i++) {
            MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        }
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

    function testCanRemoveSecondToLastValidator() public {
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
        MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();

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
        for (uint256 i = 0; i < 8; i++) {
            MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        }
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

    function testRemovalStateTransitions() public {
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
        MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();

        // Initial state
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(CoreVault.ValidatorStatus.NONE));
        assertTrue(coreVault.isWhitelisted(VAL_1));

        // After initiation
        vm.prank(admin);
        coreVault.initiateValidatorRemoval(VAL_1);
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(CoreVault.ValidatorStatus.PAUSED));
        assertFalse(coreVault.isWhitelisted(VAL_1));

        // After undelegation
        vm.prank(admin);
        coreVault.executeValidatorUndelegation(VAL_1);
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(CoreVault.ValidatorStatus.UNDELEGATING));

        // After withdrawal completion
        for (uint256 i = 0; i < 8; i++) {
            MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        }
        vm.prank(admin);
        coreVault.completeValidatorRemovalWithdrawal(VAL_1);
        assertEq(uint256(coreVault.validatorStatus(VAL_1)), uint256(CoreVault.ValidatorStatus.NONE));
    }

    // ============ HELPER FUNCTIONS ============

    /**
     * @dev Helper function to set up validator stake in the mock precompile
     */
    function _setupValidatorStake(uint64 valId, uint256 amount) internal override {
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(valId, address(coreVault), amount);
    }
}
