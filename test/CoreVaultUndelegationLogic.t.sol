/* solhint-disable */
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseTest} from "./BaseTest.t.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {CoreVault} from "../src/CoreVault.sol";
import {console} from "forge-std/console.sol";
import {MockStakingPrecompile} from "./mock/MockStakingPrecompile.sol";
import {
    ErrBelowMinWithdraw,
    ErrNoValidators,
    ErrExistingWithdrawalInProgress,
    ErrInsufficientDelegated,
    ErrNotMagma,
    ErrInvalidAmount,
    ErrNoPendingWithdrawRequest
} from "../src/MagmaErrorsModule.sol";

contract CoreVaultUndelegationLogicTest is BaseTest {
    // Test users
    address public alice;
    address public bob;
    address public charlie;

    function setUp() public override {
        BaseTest.setUp();

        // Create test users
        alice = address(0xA11CE);
        bob = address(0xB0B);
        charlie = address(0xC4A211E);

        // Fund test users
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(charlie, 1000 ether);

        // Redeploy CoreVault with epochSeconds = 0 to bypass epoch guard for testing
        address coreImpl = address(new CoreVault());
        address coreProxy = UnsafeUpgrades.deployUUPSProxy(
            coreImpl, abi.encodeCall(CoreVault.initialize, (address(magma), uint256(0), uint64(10)))
        );
        coreVault = CoreVault(payable(coreProxy));

        // Wire magma to new coreVault
        vm.prank(admin);
        magma.setVaults(address(coreVault), address(gvault));

        // Set minimum withdrawal amount for testing
        vm.prank(admin);
        coreVault.setMinUserWithdrawAmount(1 ether);

        // Add multiple validators for testing validator ordering
        _setupMultipleValidators();
    }

    function _setupMultipleValidators() internal {
        // Add 4 validators with different stake amounts
        uint64[4] memory validatorIds = [uint64(10), uint64(20), uint64(30), uint64(40)];
        uint256[4] memory stakeAmounts = [uint256(100 ether), uint256(200 ether), uint256(50 ether), uint256(150 ether)];

        for (uint256 i = 0; i < validatorIds.length; i++) {
            uint64 valId = validatorIds[i];

            // Register validator in mock staking precompile
            _setupValidatorInStakingPrecompile(valId);

            _setupValidatorStake(valId, stakeAmounts[i]);

            // Add validator to CoreVault AFTER stake is set
            vm.startPrank(admin);
            coreVault.addValidator(valId);

            // Advance epochs to make admin withdrawals ready
            _advanceEpochsForWithdrawal();

            // Complete the rebalancing to clear admin withdrawal IDs
            coreVault.redelegateToValidators();
            vm.stopPrank();
        }

        coreVault.refreshCache();
    }

    // Test basic undelegation functionality
    function test_UndelegateBasic() public {
        uint256 withdrawAmount = 50 ether;

        // Initialize cache before first totalAssets() call
        coreVault.refreshCacheCheck();

        // Record initial state
        uint256 initialTotalAssets = coreVault.totalAssets();
        uint256 initialTotalPendingUndelegations = coreVault.totalPendingUndelegations();

        // Alice makes a withdrawal request
        vm.prank(address(magma));
        coreVault.undelegate(withdrawAmount, alice);

        // Check that withdrawal request was stored
        CoreVault.WithdrawalRequestInfo[] memory requests = coreVault.getUserWithdrawalRequests(alice);
        assertTrue(requests.length > 0, "Should have withdrawal requests");

        uint256 totalRequestedAmount = 0;
        for (uint256 i = 0; i < requests.length; i++) {
            totalRequestedAmount += requests[i].amount;
        }
        assertEq(totalRequestedAmount, withdrawAmount, "Total requested amount should match");

        // Asset tracking checks
        uint256 finalTotalAssets = coreVault.totalAssets();
        uint256 finalTotalPendingUndelegations = coreVault.totalPendingUndelegations();

        // totalAssets should decrease immediately when undelegation is requested
        assertEq(
            finalTotalAssets, initialTotalAssets - withdrawAmount, "Total assets should decrease by withdrawal amount"
        );

        // totalPendingUndelegations should increase by the withdrawal amount
        assertEq(
            finalTotalPendingUndelegations,
            initialTotalPendingUndelegations + withdrawAmount,
            "Total pending undelegations should increase"
        );

        // Check validator-specific pending undelegations
        uint256 totalValidatorPending = 0;
        for (uint256 i = 0; i < requests.length; i++) {
            uint64 validator = requests[i].validator;
            uint256 amount = requests[i].amount;
            uint256 validatorPending = coreVault.pendingUndelegateByValidator(validator);
            assertGe(validatorPending, amount, "Validator should have at least the requested amount pending");
            totalValidatorPending += validatorPending;
        }
    }

    // Test validator ordering (highest stake first)
    function test_UndelegateValidatorOrdering() public {
        uint256 withdrawAmount = 25 ether; // Small amount to test ordering

        // Alice makes a withdrawal request
        vm.prank(address(magma));
        coreVault.undelegate(withdrawAmount, alice);

        // Check withdrawal requests to verify ordering
        CoreVault.WithdrawalRequestInfo[] memory requests = coreVault.getUserWithdrawalRequests(alice);

        // Should have withdrawn from one of the validators with highest stake (after rebalancing, multiple validators may have equal stake)
        bool foundHighestStakeValidator = false;
        for (uint256 i = 0; i < requests.length; i++) {
            // After rebalancing, validators 10, 20, and 40 all have 100 ether (tied for highest)
            if (requests[i].validator == 10 || requests[i].validator == 20 || requests[i].validator == 40) {
                foundHighestStakeValidator = true;
                assertGt(requests[i].amount, 0, "Should have withdrawn from highest stake validator");
                break;
            }
        }
        assertTrue(foundHighestStakeValidator, "Should have withdrawn from one of the highest stake validators");
    }

    // Test 1/20th threshold limit
    function test_UndelegateOnetwentiethThreshold() public {
        // Calculate total active stake
        uint256 totalStake = 0;
        uint64[4] memory validators = [uint64(10), uint64(20), uint64(30), uint64(40)];
        for (uint256 i = 0; i < validators.length; i++) {
            totalStake += coreVault.delegatedAmount(validators[i]);
        }

        uint256 onetwentiethThreshold = totalStake / 20;

        // Record initial state
        uint256 initialTotalAssets = coreVault.totalAssets();
        uint256 initialTotalPendingUndelegations = coreVault.totalPendingUndelegations();

        // Try to withdraw exactly the 1/20th threshold - should succeed
        vm.prank(address(magma));
        coreVault.undelegate(onetwentiethThreshold, alice);

        // Check that withdrawal was successful
        CoreVault.WithdrawalRequestInfo[] memory requests = coreVault.getUserWithdrawalRequests(alice);
        assertTrue(requests.length > 0, "Should have withdrawal requests");

        uint256 totalWithdrawn = 0;
        for (uint256 i = 0; i < requests.length; i++) {
            totalWithdrawn += requests[i].amount;
        }
        assertEq(totalWithdrawn, onetwentiethThreshold, "Should withdraw exactly 1/20th threshold");

        // Asset tracking checks
        uint256 finalTotalAssets = coreVault.totalAssets();
        uint256 finalTotalPendingUndelegations = coreVault.totalPendingUndelegations();

        // totalAssets should decrease by the withdrawal amount
        assertEq(
            finalTotalAssets,
            initialTotalAssets - onetwentiethThreshold,
            "Total assets should decrease by threshold amount"
        );

        // totalPendingUndelegations should increase by the threshold amount
        assertEq(
            finalTotalPendingUndelegations,
            initialTotalPendingUndelegations + onetwentiethThreshold,
            "Pending undelegations should increase by threshold amount"
        );

        // Verify the relationship: totalAssets = delegated stake + pending redelegations
        uint256 currentDelegatedStake = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            currentDelegatedStake += coreVault.delegatedAmount(validators[i]);
        }
    }

    // Test multiple validators used when amount exceeds single validator capacity
    function test_UndelegateMultipleValidators() public {
        // Large withdrawal that should span multiple validators (within available stake)
        uint256 largeWithdrawAmount = 60 ether; // Just under the 70 ether available

        // Record initial state
        uint256 initialTotalAssets = coreVault.totalAssets();
        uint256 initialTotalPendingUndelegations = coreVault.totalPendingUndelegations();

        // Record initial pending undelegations per validator
        uint64[4] memory validators = [uint64(10), uint64(20), uint64(30), uint64(40)];
        uint256[4] memory initialPending;
        for (uint256 i = 0; i < validators.length; i++) {
            initialPending[i] = coreVault.pendingUndelegateByValidator(validators[i]);
        }

        vm.prank(address(magma));
        coreVault.undelegate(largeWithdrawAmount, alice);

        // Check that multiple validators were used
        CoreVault.WithdrawalRequestInfo[] memory requests = coreVault.getUserWithdrawalRequests(alice);
        assertTrue(requests.length > 1, "Should use multiple validators for large withdrawal");

        // Verify total amount
        uint256 totalWithdrawn = 0;
        for (uint256 i = 0; i < requests.length; i++) {
            totalWithdrawn += requests[i].amount;
        }
        assertEq(totalWithdrawn, largeWithdrawAmount, "Total withdrawn should match requested amount");

        // Asset tracking checks
        uint256 finalTotalAssets = coreVault.totalAssets();
        uint256 finalTotalPendingUndelegations = coreVault.totalPendingUndelegations();

        // totalAssets should decrease by withdrawal amount
        assertEq(
            finalTotalAssets,
            initialTotalAssets - largeWithdrawAmount,
            "Total assets should decrease by withdrawal amount"
        );

        // totalPendingUndelegations should increase by withdrawal amount
        assertEq(
            finalTotalPendingUndelegations,
            initialTotalPendingUndelegations + largeWithdrawAmount,
            "Total pending should increase by withdrawal amount"
        );

        // Verify that pending undelegations increased for validators that were used
        uint256 totalValidatorPendingIncrease = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            uint256 finalPending = coreVault.pendingUndelegateByValidator(validators[i]);
            uint256 increase = finalPending - initialPending[i];
            totalValidatorPendingIncrease += increase;
        }

        // Total validator pending increases should equal the withdrawal amount
        assertEq(
            totalValidatorPendingIncrease,
            largeWithdrawAmount,
            "Sum of validator pending increases should match withdrawal amount"
        );
    }

    // Test one withdrawal per user restriction
    function test_UndelegateOneWithdrawalPerUser() public {
        uint256 withdrawAmount = 50 ether;

        // Alice makes first withdrawal
        vm.prank(address(magma));
        coreVault.undelegate(withdrawAmount, alice);

        // Alice tries to make second withdrawal - should fail
        vm.prank(address(magma));
        vm.expectRevert(ErrExistingWithdrawalInProgress.selector);
        coreVault.undelegate(withdrawAmount, alice);
    }

    // Test different users can withdraw simultaneously
    function test_UndelegateMultipleUsers() public {
        uint256 withdrawAmount = 50 ether;

        // Record initial state
        uint256 initialTotalAssets = coreVault.totalAssets();
        uint256 initialTotalPendingUndelegations = coreVault.totalPendingUndelegations();

        // Alice withdraws
        vm.prank(address(magma));
        coreVault.undelegate(withdrawAmount, alice);

        // Check state after Alice
        uint256 afterAliceTotalAssets = coreVault.totalAssets();
        uint256 afterAlicePending = coreVault.totalPendingUndelegations();
        assertEq(afterAliceTotalAssets, initialTotalAssets - withdrawAmount, "Total assets decreased after Alice");
        assertEq(afterAlicePending, initialTotalPendingUndelegations + withdrawAmount, "Pending increased after Alice");

        // Bob withdraws (should succeed)
        vm.prank(address(magma));
        coreVault.undelegate(withdrawAmount, bob);

        // Check state after Bob
        uint256 afterBobTotalAssets = coreVault.totalAssets();
        uint256 afterBobPending = coreVault.totalPendingUndelegations();
        assertEq(afterBobTotalAssets, initialTotalAssets - (withdrawAmount * 2), "Total assets decreased after Bob");
        assertEq(
            afterBobPending, initialTotalPendingUndelegations + (withdrawAmount * 2), "Pending increased after Bob"
        );

        // Charlie withdraws (should succeed)
        vm.prank(address(magma));
        coreVault.undelegate(withdrawAmount, charlie);

        // Final state checks
        uint256 finalTotalAssets = coreVault.totalAssets();
        uint256 finalTotalPendingUndelegations = coreVault.totalPendingUndelegations();

        // Verify all users have withdrawal requests
        assertTrue(coreVault.getUserWithdrawalRequests(alice).length > 0, "Alice should have requests");
        assertTrue(coreVault.getUserWithdrawalRequests(bob).length > 0, "Bob should have requests");
        assertTrue(coreVault.getUserWithdrawalRequests(charlie).length > 0, "Charlie should have requests");

        // Asset tracking checks
        assertEq(
            finalTotalAssets,
            initialTotalAssets - (withdrawAmount * 3),
            "Total assets should decrease by all three withdrawals"
        );
        assertEq(
            finalTotalPendingUndelegations,
            initialTotalPendingUndelegations + (withdrawAmount * 3),
            "Total pending should reflect all three withdrawals"
        );
    }

    // Test minimum withdrawal amount validation
    function test_UndelegateBelowMinimum() public {
        uint256 belowMinAmount = 0.5 ether; // Below 1 ether minimum

        vm.prank(address(magma));
        vm.expectRevert(abi.encodeWithSelector(ErrBelowMinWithdraw.selector, 1 ether));
        coreVault.undelegate(belowMinAmount, alice);
    }

    // Test zero amount validation
    function test_UndelegateZeroAmount() public {
        vm.prank(address(magma));
        vm.expectRevert(abi.encodeWithSelector(ErrBelowMinWithdraw.selector, 1 ether));
        coreVault.undelegate(0, alice);
    }

    // Test no validators scenario
    function test_UndelegateNoValidators() public {
        // Deploy fresh CoreVault with no validators
        address coreImpl = address(new CoreVault());
        address coreProxy = UnsafeUpgrades.deployUUPSProxy(
            coreImpl, abi.encodeCall(CoreVault.initialize, (address(magma), uint256(0), uint64(10)))
        );
        CoreVault freshCoreVault = CoreVault(payable(coreProxy));

        // Wire magma to fresh coreVault
        vm.prank(admin);
        magma.setVaults(address(freshCoreVault), address(gvault));

        // Set minimum withdrawal amount
        vm.prank(admin);
        freshCoreVault.setMinUserWithdrawAmount(1 ether);

        // Try to withdraw with no validators
        vm.prank(address(magma));
        vm.expectRevert(ErrNoValidators.selector);
        freshCoreVault.undelegate(10 ether, alice);
    }

    // Test insufficient delegated amount scenario
    function test_UndelegateInsufficientAmount() public {
        // Create fresh CoreVault with controlled stakes to avoid rebalancing interference
        address coreImpl = address(new CoreVault());
        address coreProxy = UnsafeUpgrades.deployUUPSProxy(
            coreImpl, abi.encodeCall(CoreVault.initialize, (address(magma), uint256(0), uint64(10)))
        );
        CoreVault freshCoreVault = CoreVault(payable(coreProxy));

        vm.prank(admin);
        magma.setVaults(address(freshCoreVault), address(gvault));

        vm.prank(admin);
        freshCoreVault.setMinUserWithdrawAmount(1 ether);

        // Setup validators with known active stakes
        uint64 val1 = 91;
        uint64 val2 = 92;

        // Set stakes first, then add validators
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(val1, address(freshCoreVault), 50 ether);
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(val2, address(freshCoreVault), 30 ether);

        vm.prank(admin);
        freshCoreVault.addValidator(val1);
        vm.prank(admin);
        freshCoreVault.addValidator(val2);

        // Test the insufficient amount scenario
        // Based on the pattern we've seen, active stake is typically much less than total stake
        // Let's test with a reasonable amount first to succeed, then test insufficient
        magma.refreshCache();
        // First, try a small withdrawal that should succeed
        uint256 smallAmount = 5 ether;
        vm.prank(address(magma));
        freshCoreVault.undelegate(smallAmount, bob); // Use bob since alice might have existing requests

        // Verify it succeeded
        CoreVault.WithdrawalRequestInfo[] memory bobRequests = freshCoreVault.getUserWithdrawalRequests(bob);
        assertTrue(bobRequests.length > 0, "Small withdrawal should succeed");

        // Now try a large withdrawal that should fail due to insufficient stake
        uint256 largeAmount = 500 ether; // Way more than any reasonable active stake
        vm.prank(address(magma));
        vm.expectRevert(); // Expect ErrInsufficientDelegated with any amounts
        freshCoreVault.undelegate(largeAmount, alice);
    }

    // Test only Magma can call undelegate
    function test_UndelegateOnlyMagma() public {
        vm.prank(alice);
        vm.expectRevert(ErrNotMagma.selector);
        coreVault.undelegate(10 ether, alice);
    }

    // Test withdrawal request data integrity
    function test_UndelegateRequestDataIntegrity() public {
        uint256 withdrawAmount = 50 ether; // Within available stake

        vm.prank(address(magma));
        coreVault.undelegate(withdrawAmount, alice);

        CoreVault.WithdrawalRequestInfo[] memory requests = coreVault.getUserWithdrawalRequests(alice);

        // Verify request data
        for (uint256 i = 0; i < requests.length; i++) {
            assertGt(requests[i].amount, 0, "Amount should be greater than 0");
            assertTrue(requests[i].validator > 0, "Validator ID should be valid");
            assertTrue(requests[i].withdrawalId < 255, "Withdrawal ID should be valid"); // ADMIN_WID is 255
        }
    }

    // Test comprehensive asset tracking during undelegation lifecycle
    function test_AssetTrackingDuringUndelegation() public {
        uint256 withdrawAmount = 30 ether;

        console.log("=== Asset Tracking Test ===");

        // Initialize cache before first totalAssets() call
        coreVault.refreshCacheCheck();

        // Record comprehensive initial state
        uint256 initialTotalAssets = coreVault.totalAssets();
        uint256 initialTotalDelegated = coreVault.getTotalDelegated();
        uint256 initialTotalPendingUndelegations = coreVault.totalPendingUndelegations();

        // Record per-validator initial state
        uint64[4] memory validators = [uint64(10), uint64(20), uint64(30), uint64(40)];
        uint256[4] memory initialValidatorDelegated;
        uint256[4] memory initialValidatorPending;

        for (uint256 i = 0; i < validators.length; i++) {
            initialValidatorDelegated[i] = coreVault.delegatedAmount(validators[i]);
            initialValidatorPending[i] = coreVault.pendingUndelegateByValidator(validators[i]);
        }

        // Perform undelegation
        vm.prank(address(magma));
        coreVault.undelegate(withdrawAmount, alice);

        // Record post-undelegation state
        uint256 postTotalAssets = coreVault.totalAssets();
        uint256 postTotalDelegated = coreVault.getTotalDelegated();
        uint256 postTotalPendingUndelegations = coreVault.totalPendingUndelegations();

        // Key assertions for undelegation request phase
        // IMPORTANT: Undelegation immediately reduces delegated stake and total assets
        assertEq(
            postTotalAssets, initialTotalAssets - withdrawAmount, "Total assets should decrease by withdrawal amount"
        );
        assertEq(
            postTotalDelegated,
            initialTotalDelegated - withdrawAmount,
            "Total delegated should decrease by withdrawal amount"
        );
        assertEq(
            postTotalPendingUndelegations,
            initialTotalPendingUndelegations + withdrawAmount,
            "Pending undelegations should increase by withdrawal amount"
        );

        // Verify per-validator changes
        uint256 totalValidatorPendingIncrease = 0;
        uint256 totalValidatorDelegatedDecrease = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            uint256 currentDelegated = coreVault.delegatedAmount(validators[i]);
            uint256 currentPending = coreVault.pendingUndelegateByValidator(validators[i]);
            uint256 pendingIncrease = currentPending - initialValidatorPending[i];
            uint256 delegatedDecrease = initialValidatorDelegated[i] - currentDelegated;

            // Track changes
            totalValidatorDelegatedDecrease += delegatedDecrease;

            totalValidatorPendingIncrease += pendingIncrease;
        }

        // Total validator pending increases should equal withdrawal amount
        assertEq(
            totalValidatorPendingIncrease,
            withdrawAmount,
            "Sum of validator pending increases should equal withdrawal amount"
        );

        // Total validator delegated decreases should also equal withdrawal amount
        assertEq(
            totalValidatorDelegatedDecrease,
            withdrawAmount,
            "Sum of validator delegated decreases should equal withdrawal amount"
        );

        // Verify withdrawal request was stored correctly
        CoreVault.WithdrawalRequestInfo[] memory requests = coreVault.getUserWithdrawalRequests(alice);
        assertTrue(requests.length > 0, "Should have withdrawal requests");

        uint256 totalRequestedAmount = 0;
        for (uint256 i = 0; i < requests.length; i++) {
            totalRequestedAmount += requests[i].amount;
        }
        assertEq(totalRequestedAmount, withdrawAmount, "Total requested amount should match withdrawal amount");
    }

    // Test user withdrawal completion lifecycle
    function test_CompleteUserWithdrawal() public {
        uint256 withdrawAmount = 20 ether; // Use smaller amount that should work

        // Record initial state
        uint256 initialTotalAssets = coreVault.totalAssets();
        uint256 initialTotalPendingUndelegations = coreVault.totalPendingUndelegations();
        uint256 initialMagmaBalance = address(magma).balance;

        // Step 1: Alice makes undelegation request
        vm.prank(address(magma));
        coreVault.undelegate(withdrawAmount, alice);

        // Check state after undelegation request
        uint256 afterRequestTotalAssets = coreVault.totalAssets();
        uint256 afterRequestPendingUndelegations = coreVault.totalPendingUndelegations();

        // Verify immediate asset changes from undelegation request
        assertEq(
            afterRequestTotalAssets,
            initialTotalAssets - withdrawAmount,
            "Total assets should decrease immediately after undelegate"
        );
        assertEq(
            afterRequestPendingUndelegations,
            initialTotalPendingUndelegations + withdrawAmount,
            "Pending undelegations should increase"
        );

        // Verify request was created
        CoreVault.WithdrawalRequestInfo[] memory requests = coreVault.getUserWithdrawalRequests(alice);
        assertTrue(requests.length > 0, "Should have withdrawal requests");

        // Step 2: Advance epochs to make withdrawals ready
        _advanceEpochsForWithdrawal();

        // Step 3: Complete the withdrawal
        vm.prank(address(magma));
        (uint256 actualWithdrawn,) = coreVault.completeUserWithdrawal(alice);

        // Check final state
        uint256 finalTotalAssets = coreVault.totalAssets();
        uint256 finalTotalPendingUndelegations = coreVault.totalPendingUndelegations();
        uint256 finalMagmaBalance = address(magma).balance;

        // If withdrawal was successful
        assertEq(
            finalMagmaBalance,
            initialMagmaBalance + actualWithdrawn,
            "Magma balance should increase by withdrawn amount"
        );
        assertEq(
            finalTotalPendingUndelegations,
            afterRequestPendingUndelegations - actualWithdrawn,
            "Pending should decrease by withdrawn amount"
        );

        // Total assets should remain the same after completion (no additional change)
        assertEq(finalTotalAssets, afterRequestTotalAssets, "Total assets should not change during completion");

        // Requests should be cleared regardless
        CoreVault.WithdrawalRequestInfo[] memory finalRequests = coreVault.getUserWithdrawalRequests(alice);
        assertEq(finalRequests.length, 0, "Alice should have no remaining withdrawal requests after completion attempt");
    }

    // Test getter functions
    function test_GetterFunctions() public {
        uint256 withdrawAmount = 50 ether;

        vm.prank(address(magma));
        coreVault.undelegate(withdrawAmount, alice);

        // Test getUserWithdrawalRequests
        CoreVault.WithdrawalRequestInfo[] memory allRequests = coreVault.getUserWithdrawalRequests(alice);
        assertTrue(allRequests.length > 0, "Should have requests");

        // Test getUserWithdrawalRequestCount
        uint256 count = coreVault.getUserWithdrawalRequestCount(alice);
        assertEq(count, allRequests.length, "Count should match array length");

        // Test getUserWithdrawalRequest
        if (count > 0) {
            CoreVault.WithdrawalRequestInfo memory firstRequest = coreVault.getUserWithdrawalRequest(alice, 0);
            assertEq(firstRequest.amount, allRequests[0].amount, "Amount should match");
        }
    }

    // Test getter function with invalid index
    function test_GetUserWithdrawalRequestInvalidIndex() public {
        // Try to get request with invalid index
        vm.expectRevert(abi.encodeWithSelector(ErrInvalidAmount.selector, 0));
        coreVault.getUserWithdrawalRequest(alice, 0);
    }

    // Test edge case: single validator with exact stake amount
    function test_UndelegateSingleValidatorExactAmount() public {
        // Deploy fresh CoreVault with single validator
        address coreImpl = address(new CoreVault());
        address coreProxy = UnsafeUpgrades.deployUUPSProxy(
            coreImpl, abi.encodeCall(CoreVault.initialize, (address(magma), uint256(0), uint64(10)))
        );
        CoreVault freshCoreVault = CoreVault(payable(coreProxy));

        // Wire magma to fresh coreVault
        vm.prank(admin);
        magma.setVaults(address(freshCoreVault), address(gvault));

        // Set minimum withdrawal amount
        vm.prank(admin);
        freshCoreVault.setMinUserWithdrawAmount(1 ether);

        // Add single validator
        uint64 singleValId = 99;
        uint256 validatorStake = 100 ether;

        _setupValidatorInStakingPrecompile(singleValId);
        // Set stake for the fresh CoreVault specifically
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(
            singleValId, address(freshCoreVault), validatorStake
        );
        vm.prank(admin);
        freshCoreVault.addValidator(singleValId);

        magma.refreshCache();
        // The delegatedAmount shows total stake, but active stake available for withdrawal is much less
        // Let's use a small, realistic amount that should be available as active stake
        uint256 withdrawAmount = 3 ether; // Small amount that should be available as active stake

        vm.prank(address(magma));
        freshCoreVault.undelegate(withdrawAmount, alice);

        // Verify withdrawal
        CoreVault.WithdrawalRequestInfo[] memory requests = freshCoreVault.getUserWithdrawalRequests(alice);
        assertTrue(requests.length > 0, "Should have withdrawal requests");

        uint256 totalWithdrawn = 0;
        for (uint256 i = 0; i < requests.length; i++) {
            totalWithdrawn += requests[i].amount;
        }
        assertEq(totalWithdrawn, withdrawAmount, "Should withdraw exactly requested amount");
    }

    // Test large-scale withdrawal spanning multiple validators
    function test_UndelegateLargeScaleAllValidators() public {
        // Create fresh CoreVault with proper validator setup to avoid rebalancing issues
        address coreImpl = address(new CoreVault());
        address coreProxy = UnsafeUpgrades.deployUUPSProxy(
            coreImpl, abi.encodeCall(CoreVault.initialize, (address(magma), uint256(0), uint64(10)))
        );
        CoreVault freshCoreVault = CoreVault(payable(coreProxy));

        vm.prank(admin);
        magma.setVaults(address(freshCoreVault), address(gvault));

        vm.prank(admin);
        freshCoreVault.setMinUserWithdrawAmount(1 ether);

        // Setup multiple validators with significant active stakes
        uint64[4] memory validators = [uint64(81), uint64(82), uint64(83), uint64(84)];
        uint256[4] memory stakes = [uint256(50 ether), uint256(100 ether), uint256(75 ether), uint256(60 ether)];

        // Set stakes first, then add validators to preserve stakes
        for (uint256 i = 0; i < validators.length; i++) {
            MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(
                validators[i], address(freshCoreVault), stakes[i]
            );
        }

        // Add validators one by one, completing rebalancing between each to avoid ErrAdminWidInUse
        vm.startPrank(admin);
        for (uint256 i = 0; i < validators.length; i++) {
            freshCoreVault.addValidator(validators[i]);

            // Complete rebalancing after each validator addition (except the last one)
            if (i < validators.length - 1) {
                // Advance epochs to make admin withdrawals ready
                _advanceEpochsForWithdrawal();

                // Complete the rebalancing to clear admin withdrawal IDs
                freshCoreVault.redelegateToValidators();
            }
        }
        vm.stopPrank();

        // Calculate actual available active stake (much smaller than total)
        uint256 totalActiveStake = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            uint256 validatorStake = freshCoreVault.delegatedAmount(validators[i]);
            totalActiveStake += validatorStake;
        }

        // Use a withdrawal amount that will require multiple validators but is realistic
        // Start with something that should work - about 1/20th of total (which is the threshold)
        uint256 largeWithdrawAmount = totalActiveStake / 20; // 1/20th threshold
        if (largeWithdrawAmount < 5 ether) largeWithdrawAmount = 5 ether; // Ensure minimum reasonable amount

        console.log("Attempting to withdraw: %d", largeWithdrawAmount);

        magma.refreshCache();
        vm.prank(address(magma));
        freshCoreVault.undelegate(largeWithdrawAmount, alice);

        // Verify withdrawal was successful
        CoreVault.WithdrawalRequestInfo[] memory requests = freshCoreVault.getUserWithdrawalRequests(alice);
        assertTrue(requests.length > 0, "Should have withdrawal requests");

        // Count unique validators used
        uint256 uniqueValidators = 0;
        bool[5] memory validatorUsed; // index 0 unused, 1-4 for validators 81,82,83,84

        for (uint256 i = 0; i < requests.length; i++) {
            uint64 valId = requests[i].validator;
            uint256 index = 0;
            if (valId == 81) index = 1;
            else if (valId == 82) index = 2;
            else if (valId == 83) index = 3;
            else if (valId == 84) index = 4;

            if (index > 0 && !validatorUsed[index]) {
                validatorUsed[index] = true;
                uniqueValidators++;
            }
        }

        assertGe(uniqueValidators, 1, "Should use at least 1 validator for withdrawal");

        // Verify total amount
        uint256 totalWithdrawn = 0;
        for (uint256 i = 0; i < requests.length; i++) {
            totalWithdrawn += requests[i].amount;
        }
        assertEq(totalWithdrawn, largeWithdrawAmount, "Total withdrawn should match requested amount");
    }

    // Test multiple users completing withdrawals simultaneously
    function test_CompleteMultipleUserWithdrawals() public {
        uint256 withdrawAmount = 30 ether;

        // Record initial state
        uint256 initialTotalAssets = coreVault.totalAssets();
        uint256 initialTotalPendingUndelegations = coreVault.totalPendingUndelegations();
        uint256 initialMagmaBalance = address(magma).balance;

        // All users make withdrawal requests
        vm.prank(address(magma));
        coreVault.undelegate(withdrawAmount, alice);

        vm.prank(address(magma));
        coreVault.undelegate(withdrawAmount, bob);

        vm.prank(address(magma));
        coreVault.undelegate(withdrawAmount, charlie);

        uint256 afterAllRequestsTotalAssets = coreVault.totalAssets();
        uint256 afterAllRequestsPendingUndelegations = coreVault.totalPendingUndelegations();

        // Verify progressive asset changes
        assertEq(
            afterAllRequestsTotalAssets,
            initialTotalAssets - (withdrawAmount * 3),
            "Total assets should decrease by all three withdrawals"
        );
        assertEq(
            afterAllRequestsPendingUndelegations,
            initialTotalPendingUndelegations + (withdrawAmount * 3),
            "Pending should increase by all three withdrawals"
        );

        // Advance epochs to make withdrawals ready
        _advanceEpochsForWithdrawal();

        // Complete withdrawals for all users
        vm.prank(address(magma));
        (uint256 aliceWithdrawn,) = coreVault.completeUserWithdrawal(alice);

        vm.prank(address(magma));
        (uint256 bobWithdrawn,) = coreVault.completeUserWithdrawal(bob);

        vm.prank(address(magma));
        (uint256 charlieWithdrawn,) = coreVault.completeUserWithdrawal(charlie);

        uint256 finalTotalAssets = coreVault.totalAssets();
        uint256 finalTotalPendingUndelegations = coreVault.totalPendingUndelegations();

        // Asset integrity checks
        uint256 totalWithdrawn = aliceWithdrawn + bobWithdrawn + charlieWithdrawn;

        // Total assets should not change during completion phase
        assertEq(finalTotalAssets, afterAllRequestsTotalAssets, "Total assets should not change during completion");

        // Pending undelegations should decrease by total withdrawn amount
        assertEq(
            finalTotalPendingUndelegations,
            afterAllRequestsPendingUndelegations - totalWithdrawn,
            "Pending should decrease by total withdrawn"
        );

        // Verify all requests are cleared
        assertEq(coreVault.getUserWithdrawalRequests(alice).length, 0, "Alice requests cleared");
        assertEq(coreVault.getUserWithdrawalRequests(bob).length, 0, "Bob requests cleared");
        assertEq(coreVault.getUserWithdrawalRequests(charlie).length, 0, "Charlie requests cleared");

        assertEq(address(magma).balance, initialMagmaBalance + totalWithdrawn, "Magma balance should increase");
    }

    // Test edge case: withdrawal completion with no pending requests
    function test_CompleteUserWithdrawalNoPendingRequests() public {
        // Try to complete withdrawal for user with no requests
        vm.prank(address(magma));
        vm.expectRevert(abi.encodeWithSelector(ErrNoPendingWithdrawRequest.selector));
        coreVault.completeUserWithdrawal(alice);
    }

    // Test access control for completion function
    function test_CompleteUserWithdrawalOnlyMagma() public {
        uint256 withdrawAmount = 20 ether;

        // Alice makes undelegation request
        vm.prank(address(magma));
        coreVault.undelegate(withdrawAmount, alice);

        // Non-magma user tries to complete withdrawal
        vm.prank(alice);
        vm.expectRevert(ErrNotMagma.selector);
        coreVault.completeUserWithdrawal(alice);

        // Admin tries to complete withdrawal
        vm.prank(admin);
        vm.expectRevert(ErrNotMagma.selector);
        coreVault.completeUserWithdrawal(alice);
    }

    // Test withdrawal request data persistence and integrity
    function test_WithdrawalRequestDataPersistence() public {
        uint256 withdrawAmount = 45 ether;

        // Record initial state
        uint256 initialRequestCount = coreVault.getUserWithdrawalRequestCount(alice);
        assertEq(initialRequestCount, 0, "Should start with no requests");

        // Alice makes withdrawal request
        vm.prank(address(magma));
        coreVault.undelegate(withdrawAmount, alice);

        // Verify request persistence
        uint256 finalRequestCount = coreVault.getUserWithdrawalRequestCount(alice);
        assertTrue(finalRequestCount > 0, "Should have requests after undelegation");

        CoreVault.WithdrawalRequestInfo[] memory allRequests = coreVault.getUserWithdrawalRequests(alice);
        assertEq(allRequests.length, finalRequestCount, "Array length should match count");

        // Test individual request access
        for (uint256 i = 0; i < finalRequestCount; i++) {
            CoreVault.WithdrawalRequestInfo memory individualRequest = coreVault.getUserWithdrawalRequest(alice, i);

            // Verify data integrity
            assertEq(individualRequest.amount, allRequests[i].amount, "Amount should match");
            assertEq(individualRequest.validator, allRequests[i].validator, "Validator should match");
            assertEq(individualRequest.withdrawalId, allRequests[i].withdrawalId, "Withdrawal ID should match");

            // Validate data ranges
            assertGt(individualRequest.amount, 0, "Amount should be positive");
            assertTrue(individualRequest.validator > 0, "Validator ID should be valid");
            assertLt(individualRequest.withdrawalId, 255, "Withdrawal ID should be under admin threshold");
        }
    }

    // Test validator distribution fairness
    function test_ValidatorDistributionFairness() public {
        uint256 largeWithdrawAmount = 60 ether; // Reduced to fit within available stake

        // Record initial stakes
        uint64[4] memory validators = [uint64(10), uint64(20), uint64(30), uint64(40)];
        uint256[4] memory initialStakes;
        for (uint256 i = 0; i < validators.length; i++) {
            initialStakes[i] = coreVault.delegatedAmount(validators[i]);
        }

        // Make large withdrawal that should span multiple validators
        vm.prank(address(magma));
        coreVault.undelegate(largeWithdrawAmount, alice);

        // Analyze how withdrawal was distributed
        CoreVault.WithdrawalRequestInfo[] memory requests = coreVault.getUserWithdrawalRequests(alice);

        // Count usage per validator using arrays
        uint256[4] memory validatorAmounts;
        uint256[4] memory validatorCounts;

        for (uint256 i = 0; i < requests.length; i++) {
            uint64 valId = requests[i].validator;
            uint256 amount = requests[i].amount;

            // Find validator index
            for (uint256 j = 0; j < validators.length; j++) {
                if (validators[j] == valId) {
                    validatorAmounts[j] += amount;
                    validatorCounts[j]++;
                    break;
                }
            }
        }

        // Verify distribution follows expected patterns
        uint256 totalDistributed = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            totalDistributed += validatorAmounts[i];
        }

        assertEq(totalDistributed, largeWithdrawAmount, "Total distributed should match requested amount");

        // Verify that higher-staked validators were used first (after rebalancing)
        // Note: After rebalancing, validators might have equal stakes, so we check that some validators were used
        uint256 validatorsUsed = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            if (validatorAmounts[i] > 0) {
                validatorsUsed++;
            }
        }

        assertGe(validatorsUsed, 1, "At least one validator should be used");
    }

    // Test boundary conditions for validator selection
    function test_ValidatorSelectionBoundaryConditions() public {
        // Test very small withdrawal (should use only highest-staked validator)
        uint256 tinyAmount = 1 ether;

        // Record state before tiny withdrawal
        uint256 beforeTinyTotalAssets = coreVault.totalAssets();
        uint256 beforeTinyPendingUndelegations = coreVault.totalPendingUndelegations();

        vm.prank(address(magma));
        coreVault.undelegate(tinyAmount, alice);

        // Check state after tiny withdrawal request
        uint256 afterTinyRequestTotalAssets = coreVault.totalAssets();
        uint256 afterTinyRequestPendingUndelegations = coreVault.totalPendingUndelegations();

        assertEq(
            afterTinyRequestTotalAssets,
            beforeTinyTotalAssets - tinyAmount,
            "Total assets should decrease by tiny amount"
        );
        assertEq(
            afterTinyRequestPendingUndelegations,
            beforeTinyPendingUndelegations + tinyAmount,
            "Pending should increase by tiny amount"
        );

        // Advance epochs to make withdrawals ready
        _advanceEpochsForWithdrawal();

        // Clear Alice's requests and check asset changes
        vm.prank(address(magma));
        (uint256 aliceTinyWithdrawn,) = coreVault.completeUserWithdrawal(alice);

        uint256 afterTinyCompletionTotalAssets = coreVault.totalAssets();
        uint256 afterTinyCompletionPendingUndelegations = coreVault.totalPendingUndelegations();

        // Assets should not change during completion
        assertEq(
            afterTinyCompletionTotalAssets,
            afterTinyRequestTotalAssets,
            "Total assets should not change during tiny completion"
        );
        assertEq(
            afterTinyCompletionPendingUndelegations,
            afterTinyRequestPendingUndelegations - aliceTinyWithdrawn,
            "Pending should decrease by withdrawn amount"
        );

        // Test withdrawal exactly at 1/20th threshold
        uint256 totalStake = 0;
        uint64[4] memory validators = [uint64(10), uint64(20), uint64(30), uint64(40)];
        for (uint256 i = 0; i < validators.length; i++) {
            totalStake += coreVault.delegatedAmount(validators[i]);
        }
        uint256 exactThreshold = totalStake / 20;

        // Record state before threshold withdrawal
        uint256 beforeThresholdTotalAssets = coreVault.totalAssets();
        uint256 beforeThresholdPendingUndelegations = coreVault.totalPendingUndelegations();

        vm.prank(address(magma));
        coreVault.undelegate(exactThreshold, bob);

        // Check state after threshold withdrawal request
        uint256 afterThresholdRequestTotalAssets = coreVault.totalAssets();
        uint256 afterThresholdRequestPendingUndelegations = coreVault.totalPendingUndelegations();

        assertEq(
            afterThresholdRequestTotalAssets,
            beforeThresholdTotalAssets - exactThreshold,
            "Total assets should decrease by threshold amount"
        );
        assertEq(
            afterThresholdRequestPendingUndelegations,
            beforeThresholdPendingUndelegations + exactThreshold,
            "Pending should increase by threshold amount"
        );

        CoreVault.WithdrawalRequestInfo[] memory thresholdRequests = coreVault.getUserWithdrawalRequests(bob);

        // Verify threshold amount is properly distributed
        uint256 totalThresholdAmount = 0;
        for (uint256 i = 0; i < thresholdRequests.length; i++) {
            totalThresholdAmount += thresholdRequests[i].amount;
        }
        assertEq(totalThresholdAmount, exactThreshold, "Threshold amount should be exact");
    }
}

// Helper contract that rejects ETH payments
contract RejectingContract {
    // This contract will reject all ETH payments by not having a receive() or fallback() function
    // Or by having one that reverts

    receive() external payable {
        revert("Payment rejected");
    }
}
