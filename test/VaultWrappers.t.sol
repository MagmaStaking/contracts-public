// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {MagmaDelegation} from "../src/MagmaDelegation.sol";
import {CoreVault} from "../src/CoreVault.sol";
import {gVault} from "../src/gVault.sol";
import {Magma} from "../src/Magma.sol";
import {WrappedMonad} from "../monad/WrappedMonad.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMagma} from "../interfaces/IMagma.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IGVault} from "../interfaces/IGVault.sol";

contract VaultWrappersTest is Test {
    MagmaDelegation public magmaDelegation;
    CoreVault public coreVault;
    gVault public gvault;
    Magma public magma;
    WrappedMonad public wmon;

    address public admin = address(0x1);
    address public user = address(0x2);
    address public validator1 = address(0x101);
    address public validator2 = address(0x102);
    address public validator3 = address(0x103);

    function setUp() public {
        // Deploy contracts
        magmaDelegation = new MagmaDelegation();
        wmon = new WrappedMonad();

        vm.prank(admin);
        magma = new Magma(IERC20(address(wmon)), "gMON", "gMON");

        coreVault = new CoreVault(address(magmaDelegation), address(magma));
        gvault = new gVault(address(magmaDelegation), address(magma));

        // Set vault addresses in Magma
        vm.prank(admin);
        magma.setVaults(address(coreVault), address(gvault));
    }

    function test_AdminIsSetCorrectly() public {
        assertEq(magma.admin(), admin);
    }

    function test_AddValidator() public {
        vm.prank(admin);
        coreVault.addValidator(validator1);

        assertTrue(coreVault.isWhitelisted(validator1));
        assertEq(coreVault.getValidatorCount(), 1);

        address[] memory validators = coreVault.getValidators();
        assertEq(validators[0], validator1);
    }

    function test_RemoveValidator() public {
        // Add validator first
        vm.prank(admin);
        coreVault.addValidator(validator1);

        // Remove validator
        vm.prank(admin);
        coreVault.removeValidator(validator1);

        assertFalse(coreVault.isWhitelisted(validator1));
        assertEq(coreVault.getValidatorCount(), 0);
    }

    function test_DelegateEquallyAmongValidators() public {
        // Add multiple validators
        vm.prank(admin);
        coreVault.addValidator(validator1);

        vm.prank(admin);
        coreVault.addValidator(validator2);

        // Delegate 1000 tokens through Magma
        uint256 delegateAmount = 1000e18;
        magma.delegate(delegateAmount);

        // Each validator should have 500 tokens
        assertEq(coreVault.delegatedAmount(validator1), 500e18);
        assertEq(coreVault.delegatedAmount(validator2), 500e18);
        assertEq(coreVault.getTotalDelegated(), 1000e18);
    }

    function test_UndelegateEquallyFromValidators() public {
        // Setup: add validators and delegate
        vm.prank(admin);
        coreVault.addValidator(validator1);

        vm.prank(admin);
        coreVault.addValidator(validator2);

        magma.delegate(1000e18);

        // Undelegate 400 tokens through Magma
        magma.undelegate(400e18);

        // Each validator should have 300 tokens left
        assertEq(coreVault.delegatedAmount(validator1), 300e18);
        assertEq(coreVault.delegatedAmount(validator2), 300e18);
        assertEq(coreVault.getTotalDelegated(), 600e18);
    }

    function test_RebalanceAfterAddingValidator() public {
        // Start with 1 validator and delegate
        vm.prank(admin);
        coreVault.addValidator(validator1);

        magma.delegate(1000e18);
        assertEq(coreVault.delegatedAmount(validator1), 1000e18);

        // Add second validator (should trigger rebalance)
        vm.prank(admin);
        coreVault.addValidator(validator2);

        // Should now be balanced 500/500
        assertEq(coreVault.delegatedAmount(validator1), 500e18);
        assertEq(coreVault.delegatedAmount(validator2), 500e18);
    }

    function test_RebalanceAfterRemovingValidator() public {
        // Start with 2 validators
        vm.prank(admin);
        coreVault.addValidator(validator1);

        vm.prank(admin);
        coreVault.addValidator(validator2);

        magma.delegate(1000e18);

        // Remove one validator (should trigger rebalance)
        vm.prank(admin);
        coreVault.removeValidator(validator2);

        // All stake should be on validator1
        assertEq(coreVault.delegatedAmount(validator1), 1000e18);
        assertEq(coreVault.delegatedAmount(validator2), 0);
    }

    function test_ManualRebalance() public {
        // Setup unbalanced state by manually adjusting
        vm.prank(admin);
        coreVault.addValidator(validator1);

        vm.prank(admin);
        coreVault.addValidator(validator2);

        magma.delegate(1000e18);

        // Manually rebalance
        vm.prank(admin);
        coreVault.rebalance();

        // Should still be balanced
        assertEq(coreVault.delegatedAmount(validator1), 500e18);
        assertEq(coreVault.delegatedAmount(validator2), 500e18);
    }

    function test_RevertNonAdminAddValidator() public {
        vm.expectRevert("CoreVault: not admin");
        vm.prank(user);
        coreVault.addValidator(validator1);
    }

    function test_RevertNonAdminRemoveValidator() public {
        vm.prank(admin);
        coreVault.addValidator(validator1);

        vm.expectRevert("CoreVault: not admin");
        vm.prank(user);
        coreVault.removeValidator(validator1);
    }

    function test_RevertDelegateWithNoValidators() public {
        vm.expectRevert("Magma: core vault delegation failed");
        magma.delegate(1000e18);
    }

    function test_RevertUndelegateWithNoValidators() public {
        vm.expectRevert("Magma: core vault undelegation failed");
        magma.undelegate(1000e18);
    }

    function test_RevertAddDuplicateValidator() public {
        vm.prank(admin);
        coreVault.addValidator(validator1);

        vm.expectRevert("CoreVault: already whitelisted");
        vm.prank(admin);
        coreVault.addValidator(validator1);
    }

    function test_RevertRemoveNonWhitelistedValidator() public {
        vm.expectRevert("CoreVault: not whitelisted");
        vm.prank(admin);
        coreVault.removeValidator(validator1);
    }

    function test_gVaultWorksNormally() public {
        // gVault should work through Magma with validator parameter
        magma.delegateToValidator(validator1, 1000e18);
        magma.undelegateFromValidator(validator1, 500e18);
        magma.completeUndelegationFromValidator(0);
    }

    function test_SetAdmin() public {
        address newAdmin = address(0x999);

        vm.prank(admin);
        magma.setAdmin(newAdmin);

        assertEq(magma.admin(), newAdmin);
    }

    function test_RevertSetAdminNonAdmin() public {
        vm.expectRevert("Magma: not admin");
        vm.prank(user);
        magma.setAdmin(address(0x999));
    }

    function test_RevertDirectCallToCoreVault() public {
        // Direct calls to CoreVault should fail with onlyMagma modifier
        vm.expectRevert("CoreVault: not magma");
        coreVault.delegate(1000e18);

        vm.expectRevert("CoreVault: not magma");
        coreVault.undelegate(1000e18);

        vm.expectRevert("CoreVault: not magma");
        coreVault.completeUndelegation(0);
    }

    function test_RevertDirectCallTogVault() public {
        // Direct calls to gVault should fail with onlyMagma modifier
        vm.expectRevert("gVault: not magma");
        gvault.delegate(validator1, 1000e18);

        vm.expectRevert("gVault: not magma");
        gvault.undelegate(validator1, 500e18);

        vm.expectRevert("gVault: not magma");
        gvault.completeUndelegation(0);
    }

    function test_SetVaults() public {
        address newCoreVault = address(0x111);
        address newGVault = address(0x222);

        vm.prank(admin);
        magma.setVaults(newCoreVault, newGVault);

        assertEq(magma.coreVault(), newCoreVault);
        assertEq(magma.gVault(), newGVault);
    }

    function test_RevertSetVaultsNonAdmin() public {
        vm.expectRevert("Magma: not admin");
        vm.prank(user);
        magma.setVaults(address(0x111), address(0x222));
    }

    function test_PauseUnpause() public {
        // Initially not paused
        assertFalse(magma.paused());

        // Admin can pause
        vm.prank(admin);
        magma.pause();
        assertTrue(magma.paused());

        // Admin can unpause
        vm.prank(admin);
        magma.unpause();
        assertFalse(magma.paused());
    }

    function test_RevertPauseNonAdmin() public {
        vm.expectRevert("Magma: not admin");
        vm.prank(user);
        magma.pause();
    }

    function test_RevertUnpauseNonAdmin() public {
        vm.prank(admin);
        magma.pause();

        vm.expectRevert("Magma: not admin");
        vm.prank(user);
        magma.unpause();
    }

    function test_RevertPauseAlreadyPaused() public {
        vm.prank(admin);
        magma.pause();

        vm.expectRevert("Magma: already paused");
        vm.prank(admin);
        magma.pause();
    }

    function test_RevertUnpauseNotPaused() public {
        vm.expectRevert("Magma: not paused");
        vm.prank(admin);
        magma.unpause();
    }

    function test_PauseEmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit Paused(admin);
        magma.pause();
    }

    function test_UnpauseEmitsEvent() public {
        vm.prank(admin);
        magma.pause();

        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit Unpaused(admin);
        magma.unpause();
    }

    // Add events for testing
    event Paused(address indexed admin);
    event Unpaused(address indexed admin);
}
