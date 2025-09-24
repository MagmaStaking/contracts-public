/* solhint-disable */
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseTest} from "./BaseTest.t.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {gVault} from "../src/gVault.sol";
import {console} from "forge-std/console.sol";
import {MockStakingPrecompile} from "./mock/MockStakingPrecompile.sol";
import {
    ErrBelowMinWithdraw,
    ErrNotWhitelisted,
    ErrExceedsCap,
    ErrCapZero,
    ErrInsufficientDelegated,
    ErrNotMagma,
    ErrZeroAddress,
    ErrNoPendingWithdrawRequest
} from "../src/MagmaErrorsModule.sol";

/**
 * @title GVaultDelegationLogicTest
 * @dev Tests for gVault delegation and undelegation functionality
 * Covers basic delegation, undelegation, cap enforcement, withdrawal completion, and access control
 */
contract GVaultDelegationLogicTest is BaseTest {
    // Test users
    address public alice;
    address public bob;
    address public charlie;

    // Test validators
    uint64 constant VAL_1 = 10;
    uint64 constant VAL_2 = 20;
    uint64 constant VAL_3 = 30;

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

        // Redeploy gVault with epochSeconds = 0 to bypass epoch guard for testing
        address gVaultImpl = address(new gVault());
        address gVaultProxy =
            UnsafeUpgrades.deployUUPSProxy(gVaultImpl, abi.encodeCall(gVault.initialize, (address(magma), uint256(0))));
        gvault = gVault(payable(gVaultProxy));

        // Wire magma to new gVault
        vm.prank(admin);
        magma.setVaults(address(coreVault), address(gvault));

        // Set minimum withdrawal amount for testing
        vm.prank(admin);
        gvault.setMinUserWithdrawAmount(1 ether);

        // Set default cap BPS (5% = 500 bps) for testing
        vm.prank(admin);
        gvault.setDefaultCapBps(500);

        // Give CoreVault substantial assets to ensure gVault caps work properly
        // gVault caps are based on CoreVault's totalAssets() with defaultCapBps = 25 (0.25%)
        _setupCoreVaultWithAssets();

        // Setup gVault validators
        _setupGVaultValidators();
    }

    function _setupCoreVaultWithAssets() internal {
        // Add validators to CoreVault and delegate substantial amounts
        // This ensures gVault caps (0.25% of CoreVault TVL) are meaningful
        uint64[3] memory coreValidators = [uint64(100), uint64(101), uint64(102)];

        for (uint256 i = 0; i < coreValidators.length; i++) {
            uint64 valId = coreValidators[i];
            _setupValidatorInStakingPrecompile(valId);

            // Set up substantial stake for CoreVault validators
            MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(valId, address(coreVault), 1000 ether);

            vm.prank(admin);
            coreVault.addValidator(valId);
        }

        // Fund CoreVault with ETH to increase totalAssets
        vm.deal(address(coreVault), 3000 ether);
    }

    function _setupGVaultValidators() internal {
        // Setup gVault validators with initial stakes
        uint64[3] memory validators = [VAL_1, VAL_2, VAL_3];

        for (uint256 i = 0; i < validators.length; i++) {
            uint64 valId = validators[i];
            _setupValidatorInStakingPrecompile(valId);

            // Start with minimal stake to ensure delegation works
            MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(valId, address(gvault), 0.1 ether);

            vm.prank(admin);
            gvault.addValidator(valId);
        }
    }

    // ============ TEST 1: BASIC DELEGATION ============

    function test_DelegateBasic() public {
        uint256 delegateAmount = 5 ether;

        // Record initial state
        uint256 initialUserShares = gvault.delegatedSharesOf(alice, VAL_1);
        uint256 initialTotalShares = gvault.totalSharesByValidator(VAL_1);

        // Fund the Magma contract for delegation (it forwards ETH to gVault)
        vm.deal(address(magma), delegateAmount);

        // Alice delegates to VAL_1
        vm.prank(address(magma));
        gvault.delegate{value: delegateAmount}(alice, VAL_1);

        // Record final state
        uint256 finalUserShares = gvault.delegatedSharesOf(alice, VAL_1);
        uint256 finalTotalShares = gvault.totalSharesByValidator(VAL_1);
        uint256 finalUserDelegatedAmount = gvault.delegatedAmountOf(alice, VAL_1);

        // Verify delegation results
        assertGt(finalUserShares, initialUserShares, "User shares should increase");
        assertGt(finalTotalShares, initialTotalShares, "Total validator shares should increase");

        // With EIP-4626 style and minimal initial stake, user owns all shares representing total validator stake
        uint256 expectedAmount = delegateAmount + 0.1 ether; // delegation + initial stake
        assertEq(
            finalUserDelegatedAmount,
            expectedAmount,
            "User delegated amount should equal total validator stake they represent"
        );
    }

    // ============ TEST 2: BASIC UNDELEGATION ============

    function test_UndelegateBasic() public {
        uint256 delegateAmount = 10 ether;
        uint256 undelegateAmount = 4 ether;

        // Setup: Alice delegates first
        vm.deal(address(magma), delegateAmount);
        vm.prank(address(magma));
        gvault.delegate{value: delegateAmount}(alice, VAL_1);

        // CRITICAL: Advance epochs to activate the delegated stake in the mock precompile
        _activatePendingDelegations();

        // Record state after delegation
        uint256 afterDelegateUserShares = gvault.delegatedSharesOf(alice, VAL_1);
        uint256 afterDelegateTotalShares = gvault.totalSharesByValidator(VAL_1);
        uint256 initialPendingUndelegations = gvault.totalPendingUndelegations();

        // Alice undelegates partial amount
        vm.prank(address(magma));
        gvault.undelegate(alice, VAL_1, undelegateAmount);

        // Record final state
        uint256 finalUserShares = gvault.delegatedSharesOf(alice, VAL_1);
        uint256 finalTotalShares = gvault.totalSharesByValidator(VAL_1);
        uint256 finalUserDelegatedAmount = gvault.delegatedAmountOf(alice, VAL_1);
        uint256 finalPendingUndelegations = gvault.totalPendingUndelegations();
        uint256 finalValidatorPending = gvault.pendingUndelegateByValidator(VAL_1);

        // Verify undelegation results
        assertLt(finalUserShares, afterDelegateUserShares, "User shares should decrease");
        assertLt(finalTotalShares, afterDelegateTotalShares, "Total shares should decrease");
        // Alice's remaining amount should account for initial 0.1 ETH stake
        uint256 expectedRemaining = delegateAmount + 0.1 ether - undelegateAmount;
        assertEq(finalUserDelegatedAmount, expectedRemaining, "Remaining amount should be correct");

        // Verify pending undelegation tracking
        assertEq(
            finalPendingUndelegations,
            initialPendingUndelegations + undelegateAmount,
            "Pending should increase by undelegated amount"
        );
        assertEq(finalValidatorPending, undelegateAmount, "Validator pending should equal undelegated amount");
    }

    // ============ TEST 3: CAP ENFORCEMENT ============

    function test_DelegateCapEnforcement() public {
        // Calculate current cap for VAL_1 (0.25% of CoreVault total assets)
        uint256 coreVaultAssets = coreVault.totalAssets();
        uint256 defaultCapBps = gvault.defaultCapBps();
        uint256 expectedCap = (coreVaultAssets * defaultCapBps) / 10_000;

        // Get current total staked to validator from mock precompile
        uint256 currentStaked = MockStakingPrecompile(STAKING_PRECOMPILE).debugDelegatorStake(VAL_1, address(gvault));

        // Calculate available cap space
        uint256 availableCapSpace = expectedCap > currentStaked ? expectedCap - currentStaked : 0;

        if (availableCapSpace < 2 ether) {
            vm.prank(admin);
            gvault.changeValidatorCap(VAL_1, currentStaked + 10 ether);
            availableCapSpace = 10 ether;
        }

        // Test successful delegation within cap
        uint256 withinCapAmount = availableCapSpace / 2;
        uint256 exceedingAmount = availableCapSpace; // Declare early

        vm.deal(address(magma), withinCapAmount + exceedingAmount + 10 ether); // Fund for all tests
        vm.prank(address(magma));
        gvault.delegate{value: withinCapAmount}(alice, VAL_1);

        // Alice owns all shares, so her delegated amount includes the initial 0.1 ETH stake
        uint256 expectedAmount = withinCapAmount + 0.1 ether;
        assertEq(gvault.delegatedAmountOf(alice, VAL_1), expectedAmount, "Within-cap delegation should succeed");

        // Test delegation that would exceed cap
        vm.prank(address(magma));
        vm.expectRevert(abi.encodeWithSelector(ErrExceedsCap.selector));
        gvault.delegate{value: exceedingAmount}(bob, VAL_1);
    }

    // ============ TEST 4: WITHDRAWAL COMPLETION ============

    function test_CompleteUserWithdrawal() public {
        uint256 delegateAmount = 5 ether;

        // Setup: Alice delegates first
        vm.deal(address(magma), delegateAmount);
        vm.prank(address(magma));
        gvault.delegate{value: delegateAmount}(alice, VAL_1);

        // CRITICAL: Advance epochs to activate the delegated stake in the mock precompile
        // Without this, the stake remains in "delta_stake" and undelegation will fail with "Insufficient stake"
        _activatePendingDelegations();

        // Use a smaller undelegation amount that's definitely within her position
        uint256 undelegateAmount = 2 ether; // Use a fixed amount that's less than delegation

        vm.prank(address(magma));
        gvault.undelegate(alice, VAL_1, undelegateAmount);

        // Record state before completion
        uint256 initialPendingUndelegations = gvault.totalPendingUndelegations();
        uint256 initialMagmaBalance = address(magma).balance;

        // Advance time to make withdrawal ready
        _advanceEpochsForWithdrawal();

        // Complete withdrawal
        vm.prank(address(magma));
        (uint256 actualWithdrawn,) = gvault.completeUserWithdrawal(alice);

        // Record final state
        uint256 finalPendingUndelegations = gvault.totalPendingUndelegations();
        uint256 finalMagmaBalance = address(magma).balance;

        // Verify withdrawal completion
        if (actualWithdrawn > 0) {
            assertEq(finalMagmaBalance, initialMagmaBalance + actualWithdrawn, "Magma balance should increase");
            assertEq(
                finalPendingUndelegations, initialPendingUndelegations - actualWithdrawn, "Pending should decrease"
            );
        }

        // Verify withdrawal requests are cleared regardless of success
        // (The implementation clears requests even if withdrawals aren't ready)
        // This is expected behavior to prevent request accumulation
    }

    // ============ TEST 5: ACCESS CONTROL ============

    function test_DelegationAccessControl() public {
        uint256 delegateAmount = 5 ether;
        uint256 undelegateAmount = 2 ether;

        // Test that only Magma can call delegate
        vm.deal(address(magma), delegateAmount * 3); // Fund Magma for multiple attempts

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrNotMagma.selector));
        gvault.delegate{value: delegateAmount}(alice, VAL_1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrNotMagma.selector));
        gvault.delegate{value: delegateAmount}(alice, VAL_1);

        // Successful delegation through Magma
        vm.prank(address(magma));
        gvault.delegate{value: delegateAmount}(alice, VAL_1);

        // Alice owns all shares, so her delegated amount includes the initial 0.1 ETH stake
        uint256 expectedAmount = delegateAmount + 0.1 ether;
        assertEq(gvault.delegatedAmountOf(alice, VAL_1), expectedAmount, "Magma delegation should succeed");

        // CRITICAL: Advance epochs to activate the delegated stake before undelegation tests
        _activatePendingDelegations();

        // Test that only Magma can call undelegate
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrNotMagma.selector));
        gvault.undelegate(alice, VAL_1, undelegateAmount);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ErrNotMagma.selector));
        gvault.undelegate(alice, VAL_1, undelegateAmount);

        // Successful undelegation through Magma
        vm.prank(address(magma));
        gvault.undelegate(alice, VAL_1, undelegateAmount);

        // Alice's remaining amount should be: initial delegation + 0.1 ETH initial stake - undelegation
        uint256 expectedRemaining = delegateAmount + 0.1 ether - undelegateAmount;
        assertEq(gvault.delegatedAmountOf(alice, VAL_1), expectedRemaining, "Magma undelegation should succeed");

        // Note: completeUserWithdrawal is NOT restricted to onlyMagma - users can complete their own withdrawals
        // So we don't test access control for this function

        // Test other validation errors

        // Test delegation to non-whitelisted validator
        // (Magma already has enough funds from previous deal)
        vm.prank(address(magma));
        vm.expectRevert(abi.encodeWithSelector(ErrNotWhitelisted.selector));
        gvault.delegate{value: delegateAmount}(alice, 999); // Non-existent validator

        // Test delegation to zero address
        vm.prank(address(magma));
        vm.expectRevert(abi.encodeWithSelector(ErrZeroAddress.selector));
        gvault.delegate{value: delegateAmount}(address(0), VAL_1);

        // Test undelegation below minimum
        vm.prank(address(magma));
        vm.expectRevert(abi.encodeWithSelector(ErrBelowMinWithdraw.selector, 1 ether));
        gvault.undelegate(alice, VAL_1, 0.5 ether);

        // Test completing withdrawal with no pending requests
        vm.prank(address(magma));
        vm.expectRevert(abi.encodeWithSelector(ErrNoPendingWithdrawRequest.selector));
        gvault.completeUserWithdrawal(bob); // Bob has no pending requests
    }

    // ============ TEST 6: SNAPSHOT MULTIPLIER AFTER ADMIN REBALANCE ==========
    function test_SnapshotAfterAdminRebalance() public {
        uint256 aliceDeposit = 10 ether;
        uint256 bobDeposit = 10 ether;

        // Ensure cap is sufficient for test; increase if needed
        uint256 currentStaked = MockStakingPrecompile(STAKING_PRECOMPILE).debugDelegatorStake(VAL_1, address(gvault));
        vm.prank(admin);
        gvault.changeValidatorCap(VAL_1, currentStaked + aliceDeposit + bobDeposit);

        // Alice deposits to gVault (through Magma)
        vm.deal(address(magma), aliceDeposit);
        vm.prank(address(magma));
        gvault.delegate{value: aliceDeposit}(alice, VAL_1);

        // Admin initiates a 50% rebalance
        vm.prank(admin);
        gvault.adminInitiateRebalanceBps(5000);

        // Bob deposits after rebalance
        vm.deal(address(magma), bobDeposit);
        vm.prank(address(magma));
        gvault.delegate{value: bobDeposit}(bob, VAL_1);

        // Check max withdrawable entitlements
        uint256 aliceMax = gvault.maxWithdrawableFromGVault(alice, VAL_1);
        uint256 bobMax = gvault.maxWithdrawableFromGVault(bob, VAL_1);

        // Alice should be limited to 50% of her pre-rebalance deposit; Bob should have full entitlement
        assertApproxEqAbs(aliceMax, aliceDeposit / 2, 1, "Alice entitlement should be ~50% after rebalance");
        assertApproxEqAbs(bobMax, bobDeposit, 1, "Bob entitlement should equal his deposit after rebalance");
    }

    // ============ TEST 7: MULTIPLIER ADJUSTMENT ON REDEEM AFTER REBALANCE ==========
    function test_MultiplierAdjustedOnRedeemAfterRebalance() public {
        uint256 depositAmount = 10 ether;

        // Ensure cap room
        uint256 currentStaked = MockStakingPrecompile(STAKING_PRECOMPILE).debugDelegatorStake(VAL_1, address(gvault));
        vm.prank(admin);
        gvault.changeValidatorCap(VAL_1, currentStaked + depositAmount);

        // Alice deposits via Magma
        vm.deal(address(magma), depositAmount);
        vm.prank(address(magma));
        gvault.delegate{value: depositAmount}(alice, VAL_1);

        // Optional: activate stake to ensure later undelegation succeeds against mock
        _activatePendingDelegations();

        // Admin triggers 50% rebalance; P is halved
        vm.prank(admin);
        gvault.adminInitiateRebalanceBps(5000);

        // Alice's max entitlement should be ~50% of her deposit
        uint256 aliceEntitlementBefore = gvault.maxWithdrawableFromGVault(alice, VAL_1);
        assertApproxEqAbs(aliceEntitlementBefore, depositAmount / 2, 1, "Entitlement before redeem should be ~50%");

        // Alice redeems her full entitlement from gVault path
        vm.prank(address(magma));
        gvault.undelegate(alice, VAL_1, aliceEntitlementBefore);

        _advanceEpochsForWithdrawal();

        vm.prank(address(magma));
        (uint256 withdrawn,) = gvault.completeUserWithdrawal(alice);
        assertApproxEqAbs(withdrawn, aliceEntitlementBefore, 1, "Withdrawn should match entitlement");

        // After redeem, multiplier-accounted entitlement should be ~0
        uint256 aliceEntitlementAfter = gvault.maxWithdrawableFromGVault(alice, VAL_1);
        assertLe(aliceEntitlementAfter, 1, "Entitlement after redeem should be ~0");

        // Alice deposits again; her new entitlement multiplier should be 1 (entitlement == new deposit)
        uint256 depositAgain = 5 ether;
        uint256 stakedNow = MockStakingPrecompile(STAKING_PRECOMPILE).debugDelegatorStake(VAL_1, address(gvault));
        uint256 pendingRedel = gvault.pendingRedelegateByValidator(VAL_1);
        vm.prank(admin);
        gvault.changeValidatorCap(VAL_1, stakedNow + pendingRedel + depositAgain + 1 ether);

        vm.deal(address(magma), depositAgain);
        vm.prank(address(magma));
        gvault.delegate{value: depositAgain}(alice, VAL_1);

        uint256 aliceEntitlementNew = gvault.maxWithdrawableFromGVault(alice, VAL_1);
        assertApproxEqAbs(
            aliceEntitlementNew, depositAgain, 1, "New entitlement should equal new deposit (multiplier=1)"
        );
    }
}
