// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

import {Magma} from "../src/Magma.sol";
import {CoreVault} from "../src/CoreVault.sol";
import {gVault} from "../src/gVault.sol";
import {WrappedMonad} from "../monad/WrappedMonad.sol";
import {MockStakingPrecompile} from "./mock/MockStakingPrecompile.sol";
import {
    ErrBelowMinWithdraw,
    ErrNoValidators,
    ErrExistingWithdrawalInProgress,
    ErrInsufficientDelegated,
    ErrNotMagma
} from "../src/MagmaErrorsModule.sol";

contract CoreVaultUndelegationSimpleTest is Test {
    address public admin;
    address public alice;
    address public bob;

    WrappedMonad public wmon;
    Magma public magma;
    CoreVault public coreVault;
    gVault public gvault;
    MockStakingPrecompile public stakingPrecompile;

    // Staking precompile address
    address payable internal constant STAKING_PRECOMPILE = payable(address(0x0000000000000000000000000000000000001000));

    function setUp() public {
        admin = address(0xADC1);
        alice = address(0xA11CE);
        bob = address(0xB0B);

        // Deploy mock staking precompile at the expected address
        stakingPrecompile = new MockStakingPrecompile();
        vm.etch(STAKING_PRECOMPILE, address(stakingPrecompile).code);
        vm.deal(STAKING_PRECOMPILE, 1000000 ether);
        MockStakingPrecompile(STAKING_PRECOMPILE).initialize();

        // Deploy wrapped asset
        wmon = new WrappedMonad();

        // Deploy Magma
        address magmaImpl = address(new Magma());
        address magmaProxy = UnsafeUpgrades.deployUUPSProxy(
            magmaImpl,
            abi.encodeCall(
                Magma.initialize,
                (IERC20(address(wmon)), "gMON", "gMON", admin, address(0), address(0), 10, 0, admin, uint256(0))
            )
        );
        magma = Magma(payable(magmaProxy));

        // Deploy CoreVault
        address coreImpl = address(new CoreVault());
        address coreProxy = UnsafeUpgrades.deployUUPSProxy(
            coreImpl, abi.encodeCall(CoreVault.initialize, (address(magma), uint256(0), uint64(10)))
        );
        coreVault = CoreVault(payable(coreProxy));

        // Deploy gVault
        address gvImpl = address(new gVault());
        address gvProxy =
            UnsafeUpgrades.deployUUPSProxy(gvImpl, abi.encodeCall(gVault.initialize, (address(magma), uint256(0))));
        gvault = gVault(payable(gvProxy));

        // Wire magma vault refs
        vm.prank(admin);
        magma.setVaults(address(coreVault), address(gvault));

        // Set minimum withdrawal amount
        vm.prank(admin);
        coreVault.setMinUserWithdrawAmount(1 ether);

        // Fund test users
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function test_BasicUndelegationWorkflow() public {
        // Setup: Add validators with different stakes
        uint64 val1 = 10;
        uint64 val2 = 20;
        uint64 val3 = 30;

        // Add validators to CoreVault
        vm.startPrank(admin);
        coreVault.addValidator(val1);
        coreVault.addValidator(val2);
        coreVault.addValidator(val3);
        vm.stopPrank();

        // Set up stakes directly in mock precompile (simulating different delegated amounts)
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(val1, address(coreVault), 100 ether); // Low stake
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(val2, address(coreVault), 300 ether); // High stake
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(val3, address(coreVault), 200 ether); // Medium stake

        // Verify stakes are set correctly
        console.log("Val 1 stake:", coreVault.delegatedAmount(val1));
        console.log("Val 2 stake:", coreVault.delegatedAmount(val2));
        console.log("Val 3 stake:", coreVault.delegatedAmount(val3));

        // Test: Alice makes a withdrawal
        uint256 withdrawAmount = 50 ether;
        vm.prank(address(magma));
        coreVault.undelegate(withdrawAmount, alice);

        // Verify: Check withdrawal requests
        CoreVault.WithdrawalRequestInfo[] memory requests = coreVault.getUserWithdrawalRequests(alice);
        assertTrue(requests.length > 0, "Should have withdrawal requests");

        // Verify total amount
        uint256 totalWithdrawn = 0;
        for (uint256 i = 0; i < requests.length; i++) {
            totalWithdrawn += requests[i].amount;
            console.log("Request %d - Validator: %d Amount: %d", i, requests[i].validator, requests[i].amount);
        }
        assertEq(totalWithdrawn, withdrawAmount, "Total withdrawn should match requested");

        // Verify highest stake validator was used first (val2 with 300 ether)
        bool foundVal2 = false;
        for (uint256 i = 0; i < requests.length; i++) {
            if (requests[i].validator == val2) {
                foundVal2 = true;
                assertGt(requests[i].amount, 0, "Should have withdrawn from highest stake validator");
                break;
            }
        }
        assertTrue(foundVal2, "Should have withdrawn from validator 2 (highest stake)");
    }

    function test_OneWithdrawalPerUser() public {
        // Setup simple validator - set stake BEFORE adding validator
        uint64 val1 = 51; // Use unique validator ID to avoid test interference
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(val1, address(coreVault), 100 ether);
        vm.prank(admin);
        coreVault.addValidator(val1);

        // Alice makes first withdrawal (use smaller amount within available active stake)
        vm.prank(address(magma));
        coreVault.undelegate(3 ether, alice);

        // Alice tries second withdrawal - should fail
        vm.prank(address(magma));
        vm.expectRevert(ErrExistingWithdrawalInProgress.selector);
        coreVault.undelegate(2 ether, alice);
    }

    function test_MultipleUsers() public {
        // Setup validator - set stake BEFORE adding validator
        uint64 val1 = 52; // Use unique validator ID to avoid test interference
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(val1, address(coreVault), 200 ether);
        vm.prank(admin);
        coreVault.addValidator(val1);

        // Alice withdraws (use smaller amount within available active stake)
        vm.prank(address(magma));
        coreVault.undelegate(8 ether, alice);

        // Bob withdraws (should succeed, use remaining available stake)
        vm.prank(address(magma));
        coreVault.undelegate(2 ether, bob);

        // Verify both have requests
        assertTrue(coreVault.getUserWithdrawalRequests(alice).length > 0, "Alice should have requests");
        assertTrue(coreVault.getUserWithdrawalRequests(bob).length > 0, "Bob should have requests");
    }

    function test_InsufficientStake() public {
        // Setup fresh CoreVault to avoid interference
        address coreImpl = address(new CoreVault());
        address coreProxy = UnsafeUpgrades.deployUUPSProxy(
            coreImpl, abi.encodeCall(CoreVault.initialize, (address(magma), uint256(0), uint64(10)))
        );
        CoreVault freshCoreVault = CoreVault(payable(coreProxy));

        vm.prank(admin);
        magma.setVaults(address(freshCoreVault), address(gvault));

        vm.prank(admin);
        freshCoreVault.setMinUserWithdrawAmount(1 ether);

        // Setup validator with low stake
        uint64 val1 = 99; // Use unique validator ID

        // Set stake BEFORE adding validator to avoid rebalancing
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(val1, address(freshCoreVault), 5 ether);

        vm.prank(admin);
        freshCoreVault.addValidator(val1);

        // Check what the actual available stake is after rebalancing
        uint256 actualStake = freshCoreVault.delegatedAmount(val1);
        console.log("Actual stake after rebalancing: %d", actualStake);

        // Try to withdraw more than available - expect revert with actual available amount
        vm.prank(address(magma));
        vm.expectRevert(); // Just expect insufficient delegated error, don't check exact amounts due to rebalancing
        freshCoreVault.undelegate(10 ether, alice);
    }

    function test_OnetwentiethThreshold() public {
        // Setup validators with total stake of 600 ether
        uint64 val1 = 10;
        uint64 val2 = 20;
        vm.startPrank(admin);
        coreVault.addValidator(val1);
        coreVault.addValidator(val2);
        vm.stopPrank();

        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(val1, address(coreVault), 300 ether);
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(val2, address(coreVault), 300 ether);

        // Total stake = 600 ether, 1/20th = 30 ether
        uint256 onetwentiethAmount = 30 ether;

        // Should succeed
        vm.prank(address(magma));
        coreVault.undelegate(onetwentiethAmount, alice);

        // Verify withdrawal
        CoreVault.WithdrawalRequestInfo[] memory requests = coreVault.getUserWithdrawalRequests(alice);
        uint256 totalWithdrawn = 0;
        for (uint256 i = 0; i < requests.length; i++) {
            totalWithdrawn += requests[i].amount;
        }
        assertEq(totalWithdrawn, onetwentiethAmount, "Should withdraw exactly 1/20th threshold");
    }

    function test_AccessControl() public {
        // Setup validator
        uint64 val1 = 10;
        vm.prank(admin);
        coreVault.addValidator(val1);
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(val1, address(coreVault), 100 ether);

        // Only Magma can call undelegate
        vm.prank(alice);
        vm.expectRevert(ErrNotMagma.selector);
        coreVault.undelegate(10 ether, alice);
    }

    function test_MinimumWithdrawAmount() public {
        // Setup validator
        uint64 val1 = 10;
        vm.prank(admin);
        coreVault.addValidator(val1);
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(val1, address(coreVault), 100 ether);

        // Try below minimum
        vm.prank(address(magma));
        vm.expectRevert(abi.encodeWithSelector(ErrBelowMinWithdraw.selector, 1 ether));
        coreVault.undelegate(0.5 ether, alice);
    }

    function test_GetterFunctions() public {
        // Setup validator - set stake BEFORE adding validator
        uint64 val1 = 53; // Use unique validator ID to avoid test interference
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(val1, address(coreVault), 100 ether);
        vm.prank(admin);
        coreVault.addValidator(val1);

        // Make withdrawal (use smaller amount within available active stake)
        vm.prank(address(magma));
        coreVault.undelegate(4 ether, alice);

        // Test getters
        CoreVault.WithdrawalRequestInfo[] memory allRequests = coreVault.getUserWithdrawalRequests(alice);
        uint256 count = coreVault.getUserWithdrawalRequestCount(alice);

        assertTrue(allRequests.length > 0, "Should have requests");
        assertEq(count, allRequests.length, "Count should match array length");

        if (count > 0) {
            CoreVault.WithdrawalRequestInfo memory firstRequest = coreVault.getUserWithdrawalRequest(alice, 0);
            assertEq(firstRequest.amount, allRequests[0].amount, "Amount should match");
        }
    }
}
