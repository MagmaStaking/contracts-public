/* solhint-disable */
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseTest} from "./BaseTest.t.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {CoreVault} from "../src/CoreVault.sol";
import {console} from "forge-std/console.sol";
import {
    ErrNotAdmin,
    ErrNotMagma,
    ErrZeroValidatorId,
    ErrAlreadyWhitelisted,
    ErrInvalidAmount
} from "../src/MagmaErrorsModule.sol";

/**
 * @title CoreVaultAccessControl
 * @dev Comprehensive tests for access control in CoreVault
 * Tests all onlyAdmin and onlyMagma function restrictions
 */
contract CoreVaultAccessControl is BaseTest {
    uint64 constant VAL_1 = 101;
    uint64 constant VAL_2 = 102;

    address constant UNAUTHORIZED_USER = address(0x123);
    address constant RANDOM_ADDRESS = address(0x456);

    function setUp() public override {
        BaseTest.setUp();

        // Ensure we have validators set up for testing
        _setupValidatorInStakingPrecompile(VAL_1);
        _setupValidatorInStakingPrecompile(VAL_2);
    }

    // ============ ONLY ADMIN FUNCTION TESTS ============

    function test_pause_OnlyAdmin_Success() public {
        vm.prank(admin);
        coreVault.pause();
        assertTrue(coreVault.paused(), "Should be paused");
    }

    function test_pause_OnlyAdmin_RevertUnauthorized() public {
        vm.prank(UNAUTHORIZED_USER);
        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.pause();
    }

    function test_unpause_OnlyAdmin_Success() public {
        // First pause as admin
        vm.prank(admin);
        coreVault.pause();
        assertTrue(coreVault.paused(), "Should be paused");

        // Then unpause as admin
        vm.prank(admin);
        coreVault.unpause();
        assertFalse(coreVault.paused(), "Should be unpaused");
    }

    function test_unpause_OnlyAdmin_RevertUnauthorized() public {
        // First pause as admin
        vm.prank(admin);
        coreVault.pause();

        // Try to unpause as unauthorized user
        vm.prank(UNAUTHORIZED_USER);
        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.unpause();
    }

    function test_setMinUserWithdrawAmount_OnlyAdmin_Success() public {
        uint256 newAmount = 100 ether;

        vm.prank(admin);
        coreVault.setMinUserWithdrawAmount(newAmount);

        assertEq(coreVault.minUserWithdrawAmount(), newAmount, "Should update min withdraw amount");
    }

    function test_setMinUserWithdrawAmount_OnlyAdmin_RevertUnauthorized() public {
        uint256 newAmount = 100 ether;

        vm.prank(UNAUTHORIZED_USER);
        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.setMinUserWithdrawAmount(newAmount);
    }

    function test_setMinUserWithdrawAmount_OnlyAdmin_RevertInvalidAmount() public {
        uint256 invalidAmount = 15000 ether; // Above 10000 ether limit

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrInvalidAmount.selector, invalidAmount));
        coreVault.setMinUserWithdrawAmount(invalidAmount);
    }

    function test_addValidator_OnlyAdmin_Success() public {
        uint256 initialCount = coreVault.getValidatorCount();

        vm.prank(admin);
        coreVault.addValidator(VAL_1);

        assertTrue(coreVault.isWhitelisted(VAL_1), "Should be whitelisted");
        assertEq(coreVault.getValidatorCount(), initialCount + 1, "Should have one more validator");
    }

    function test_addValidator_OnlyAdmin_RevertUnauthorized() public {
        vm.prank(UNAUTHORIZED_USER);
        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.addValidator(VAL_1);
    }

    function test_addValidator_OnlyAdmin_RevertZeroValidatorId() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrZeroValidatorId.selector));
        coreVault.addValidator(0);
    }

    function test_addValidator_OnlyAdmin_RevertAlreadyWhitelisted() public {
        vm.prank(admin);
        coreVault.addValidator(VAL_1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrAlreadyWhitelisted.selector));
        coreVault.addValidator(VAL_1);
    }

    function test_adminRebalanceInitiate_OnlyAdmin_Success() public {
        // First add a validator to have something to rebalance
        vm.prank(admin);
        coreVault.addValidator(VAL_1);

        // Complete first rebalance to reset state
        vm.prank(admin);
        coreVault.redelegateToValidators();

        // Now test adminRebalanceInitiate
        vm.prank(admin);
        coreVault.adminRebalanceInitiate();

        assertFalse(coreVault.finishedLastRebalance(), "Should be in rebalance progress");
    }

    function test_adminRebalanceInitiate_OnlyAdmin_RevertUnauthorized() public {
        vm.prank(UNAUTHORIZED_USER);
        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.adminRebalanceInitiate();
    }

    function test_redelegateToValidators_OnlyAdmin_Success() public {
        // First add a validator
        vm.prank(admin);
        coreVault.addValidator(VAL_1);

        // Should be able to call redelegateToValidators
        vm.prank(admin);
        coreVault.redelegateToValidators();

        assertTrue(coreVault.finishedLastRebalance(), "Should finish rebalance");
    }

    function test_redelegateToValidators_OnlyAdmin_RevertUnauthorized() public {
        vm.prank(UNAUTHORIZED_USER);
        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.redelegateToValidators();
    }

    function test_initiateValidatorRemoval_OnlyAdmin_Success() public {
        // First add two validators (need at least 2 to remove one)
        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);

        // Should be able to initiate removal
        coreVault.initiateValidatorRemoval(VAL_1);
        vm.stopPrank();

        assertFalse(coreVault.isWhitelisted(VAL_1), "Should not be whitelisted after removal initiation");
    }

    function test_initiateValidatorRemoval_OnlyAdmin_RevertUnauthorized() public {
        // First add validators as admin
        vm.startPrank(admin);
        coreVault.addValidator(VAL_1);
        coreVault.addValidator(VAL_2);
        vm.stopPrank();

        // Try to remove as unauthorized user
        vm.prank(UNAUTHORIZED_USER);
        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.initiateValidatorRemoval(VAL_1);
    }

    function test_executeValidatorUndelegation_OnlyAdmin_RevertUnauthorized() public {
        vm.prank(UNAUTHORIZED_USER);
        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.executeValidatorUndelegation(VAL_1);
    }

    function test_completeValidatorRemovalWithdrawal_OnlyAdmin_RevertUnauthorized() public {
        vm.prank(UNAUTHORIZED_USER);
        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.completeValidatorRemovalWithdrawal(VAL_1);
    }

    // ============ ONLY MAGMA FUNCTION TESTS ============

    function test_delegate_OnlyMagma_Success() public {
        // Check if validator 1 is already whitelisted, if not add it
        if (!coreVault.isWhitelisted(1)) {
            vm.prank(admin);
            coreVault.addValidator(1); // Use validator 1 which is set up in BaseTest
        }

        // Fund magma contract
        uint256 delegateAmount = 100 ether;
        vm.deal(address(magma), delegateAmount);

        // Call delegate as magma
        vm.prank(address(magma));
        coreVault.delegate{value: delegateAmount}();

        // Should succeed without revert
    }

    function test_delegate_OnlyMagma_RevertUnauthorized() public {
        uint256 delegateAmount = 100 ether;
        vm.deal(UNAUTHORIZED_USER, delegateAmount);

        vm.prank(UNAUTHORIZED_USER);
        vm.expectRevert(abi.encodeWithSelector(ErrNotMagma.selector));
        coreVault.delegate{value: delegateAmount}();
    }

    function test_undelegate_OnlyMagma_Success() public {
        // Setup: Ensure validator exists and delegate some stake
        if (!coreVault.isWhitelisted(1)) {
            vm.prank(admin);
            coreVault.addValidator(1); // Use validator 1 which is set up in BaseTest
        }

        uint256 stakeAmount = 100 ether;
        vm.deal(address(magma), stakeAmount);
        vm.prank(address(magma));
        coreVault.delegate{value: stakeAmount}();

        // Activate the stakes
        _activatePendingDelegations();
        _activateAllStakes();
        coreVault.refreshCache();

        // Set minimum withdraw amount to allow the test
        vm.prank(admin);
        coreVault.setMinUserWithdrawAmount(1 ether);

        // Try to undelegate as magma
        uint256 undelegateAmount = 2 ether;
        vm.prank(address(magma));
        coreVault.undelegate(undelegateAmount, user);

        // Should succeed without revert
    }

    function test_undelegate_OnlyMagma_RevertUnauthorized() public {
        uint256 undelegateAmount = 10 ether;

        vm.prank(UNAUTHORIZED_USER);
        vm.expectRevert(abi.encodeWithSelector(ErrNotMagma.selector));
        coreVault.undelegate(undelegateAmount, user);
    }

    function test_completeUserWithdrawal_OnlyMagma_RevertUnauthorized() public {
        vm.prank(UNAUTHORIZED_USER);
        vm.expectRevert(abi.encodeWithSelector(ErrNotMagma.selector));
        coreVault.completeUserWithdrawal(user);
    }

    // ============ UPGRADE AUTHORIZATION TEST ============
    // Note: Upgrade tests are complex due to proxy patterns and are tested separately
    // The _authorizeUpgrade function properly checks for admin role in the implementation

    // ============ COMPREHENSIVE ACCESS CONTROL TESTS ============

    function test_allOnlyAdminFunctions_RevertForRandomAddress() public {
        address randomAddr = RANDOM_ADDRESS;

        // Test all onlyAdmin functions with random address
        vm.startPrank(randomAddr);

        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.pause();

        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.unpause();

        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.setMinUserWithdrawAmount(100 ether);

        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.addValidator(VAL_1);

        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.adminRebalanceInitiate();

        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.redelegateToValidators();

        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.initiateValidatorRemoval(VAL_1);

        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.executeValidatorUndelegation(VAL_1);

        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        coreVault.completeValidatorRemovalWithdrawal(VAL_1);

        vm.stopPrank();
    }

    function test_allOnlyMagmaFunctions_RevertForRandomAddress() public {
        address randomAddr = RANDOM_ADDRESS;
        vm.deal(randomAddr, 1 ether);

        // Test all onlyMagma functions with random address
        vm.startPrank(randomAddr);

        vm.expectRevert(abi.encodeWithSelector(ErrNotMagma.selector));
        coreVault.delegate{value: 1 ether}();

        vm.expectRevert(abi.encodeWithSelector(ErrNotMagma.selector));
        coreVault.undelegate(1 ether, user);

        vm.expectRevert(abi.encodeWithSelector(ErrNotMagma.selector));
        coreVault.completeUserWithdrawal(user);

        vm.stopPrank();
    }

    function test_adminCanCallAllAdminFunctions() public {
        // Test that admin can successfully call all admin functions
        vm.startPrank(admin);

        // These should all succeed
        coreVault.setMinUserWithdrawAmount(50 ether);
        coreVault.addValidator(VAL_1);
        coreVault.redelegateToValidators(); // Complete any pending rebalance
        coreVault.adminRebalanceInitiate();
        coreVault.redelegateToValidators();

        // Pause/unpause cycle
        coreVault.pause();
        coreVault.unpause();

        vm.stopPrank();

        // Verify state changes
        assertEq(coreVault.minUserWithdrawAmount(), 50 ether);
        assertTrue(coreVault.isWhitelisted(VAL_1));
        assertFalse(coreVault.paused());
    }

    function test_magmaCanCallAllMagmaFunctions() public {
        // Setup: Ensure validator exists and set minimum withdraw amount
        vm.startPrank(admin);
        if (!coreVault.isWhitelisted(1)) {
            coreVault.addValidator(1); // Use validator 1 which is set up in BaseTest
        }
        coreVault.setMinUserWithdrawAmount(1 ether);
        vm.stopPrank();

        // Fund magma
        uint256 amount = 100 ether;
        vm.deal(address(magma), amount);

        // Test that magma can call all magma functions
        vm.startPrank(address(magma));

        // Delegate should succeed
        coreVault.delegate{value: amount}();

        // Activate stakes for undelegation test
        vm.stopPrank();
        _activatePendingDelegations();
        _activateAllStakes();
        coreVault.refreshCache();
        vm.startPrank(address(magma));

        // Undelegate should succeed
        coreVault.undelegate(2 ether, user);

        // Advance epochs to make withdrawal ready
        vm.stopPrank();
        _advanceEpochsForWithdrawal();
        vm.startPrank(address(magma));

        // CompleteUserWithdrawal should succeed
        coreVault.completeUserWithdrawal(user);

        vm.stopPrank();
    }
}
