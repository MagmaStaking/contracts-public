// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Magma} from "../src/Magma.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WrappedMonad} from "../monad/WrappedMonad.sol";

contract MagmaTest is Test {
    Magma public magma;
    WrappedMonad public wmon;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public admin = address(0x99); // Admin for pause tests

    uint256 public constant INITIAL_SUPPLY = 1_000_000e18;
    uint256 public constant DEFAULT_DELAY = 1 days;

    function setUp() public {
        // Deploy WrappedMonad as the underlying asset
        wmon = new WrappedMonad();

        // Deploy Magma vault - the vault shares are gMON (admin will be msg.sender = this contract)
        vm.prank(admin);
        magma = new Magma(IERC20(address(wmon)), "gMON", "gMON");

        // Give test accounts native currency for wrapping
        vm.deal(alice, 20_000 ether);
        vm.deal(bob, 20_000 ether);

        // Wrap some native assets for users to have WMON tokens for regular deposits
        vm.prank(alice);
        wmon.deposit{value: 10_000 ether}();

        vm.prank(bob);
        wmon.deposit{value: 10_000 ether}();

        // Approve vault for users to use wrapped tokens
        vm.prank(alice);
        wmon.approve(address(magma), type(uint256).max);

        vm.prank(bob);
        wmon.approve(address(magma), type(uint256).max);
    }

    function test_Deploy() public {
        // Test that the contract deploys successfully
        assertTrue(address(magma) != address(0));
        assertEq(address(magma.asset()), address(wmon));
        assertEq(magma.name(), "gMON");
        assertEq(magma.symbol(), "gMON");
    }

    function test_ERC165Support() public {
        // Test ERC-165 interface support
        bytes4 erc7540InterfaceId = 0x2f0a18c5;
        assertTrue(magma.supportsInterface(erc7540InterfaceId));
    }

    function test_SynchronousDeposit() public {
        uint256 depositAmount = 1000e18;

        // Alice deposits using wrapped tokens (WMON) - indirect approach
        vm.prank(alice);
        uint256 shares = magma.deposit(depositAmount, alice);

        assertEq(magma.balanceOf(alice), shares);
        assertEq(wmon.balanceOf(address(magma)), depositAmount);
        assertEq(magma.totalAssets(), depositAmount);
    }

    function test_DepositComparison() public {
        uint256 depositAmount = 1 ether;

        // Method 1: Direct native deposit using depositMon
        vm.prank(alice);
        uint256 nativeShares = magma.depositMon{value: depositAmount}();

        // Method 2: Indirect deposit via WrappedMonad -> deposit
        vm.prank(bob);
        uint256 wrappedShares = magma.deposit(depositAmount, bob);

        // Both methods should give same result (1:1 initially)
        assertEq(nativeShares, wrappedShares);
        assertEq(magma.balanceOf(alice), depositAmount);
        assertEq(magma.balanceOf(bob), depositAmount);
        assertEq(magma.totalAssets(), depositAmount * 2);
    }

    function test_SynchronousMint() public {
        uint256 sharesToMint = 1000e18;

        vm.prank(alice);
        uint256 assets = magma.mint(sharesToMint, alice);

        assertEq(magma.balanceOf(alice), sharesToMint);
        assertEq(wmon.balanceOf(address(magma)), assets);
        assertEq(magma.totalAssets(), assets);
    }

    function test_MaxWithdrawRedeem() public {
        // Setup: Alice deposits first
        vm.prank(alice);
        magma.deposit(1000e18, alice);

        // Max withdraw/redeem should return 0 to force async flow
        assertEq(magma.maxWithdraw(alice), 0);
        assertEq(magma.maxRedeem(alice), 0);
    }

    function test_RequestWithdraw() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 500e18;

        // Setup: Alice deposits
        vm.prank(alice);
        magma.deposit(depositAmount, alice);

        uint256 initialShares = magma.balanceOf(alice);

        // Alice requests withdrawal
        vm.prank(alice);
        uint256 requestId = magma.requestWithdraw(withdrawAmount, alice, alice);

        assertEq(requestId, 0); // Simplified implementation returns 0

        // Check pending request
        assertEq(magma.pendingWithdrawRequest(alice), withdrawAmount);
        assertEq(magma.pendingRedeemRequest(alice), 0);

        // Check shares are locked
        uint256 expectedShares = magma.previewWithdraw(withdrawAmount);
        assertEq(magma.balanceOf(alice), initialShares - expectedShares);
        assertEq(magma.balanceOf(address(magma)), expectedShares);
    }

    function test_RequestRedeem() public {
        uint256 depositAmount = 1000e18;
        uint256 redeemShares = 500e18;

        // Setup: Alice deposits
        vm.prank(alice);
        magma.deposit(depositAmount, alice);

        uint256 initialShares = magma.balanceOf(alice);

        // Alice requests redemption
        vm.prank(alice);
        uint256 requestId = magma.requestRedeem(redeemShares, alice, alice);

        assertEq(requestId, 0);

        // Check pending request
        assertEq(magma.pendingRedeemRequest(alice), redeemShares);
        assertEq(magma.pendingWithdrawRequest(alice), 0);

        // Check shares are locked
        assertEq(magma.balanceOf(alice), initialShares - redeemShares);
        assertEq(magma.balanceOf(address(magma)), redeemShares);
    }

    function test_LinearVestingClaimable() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 500e18;

        // Setup: Alice deposits and requests withdrawal
        vm.prank(alice);
        magma.deposit(depositAmount, alice);

        vm.prank(alice);
        magma.requestWithdraw(withdrawAmount, alice, alice);

        // Initially no claimable amount
        assertEq(magma.claimableWithdrawRequest(alice), 0);

        // After half the delay period, half should be claimable
        vm.warp(block.timestamp + DEFAULT_DELAY / 2);
        uint256 halfClaimable = magma.claimableWithdrawRequest(alice);
        assertApproxEqRel(halfClaimable, withdrawAmount / 2, 0.01e18); // 1% tolerance

        // After full delay, all should be claimable
        vm.warp(block.timestamp + DEFAULT_DELAY / 2);
        assertEq(magma.claimableWithdrawRequest(alice), withdrawAmount);
    }

    function test_ClaimWithdraw() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 500e18;

        // Setup: Alice deposits and requests withdrawal
        vm.prank(alice);
        magma.deposit(depositAmount, alice);

        vm.prank(alice);
        magma.requestWithdraw(withdrawAmount, alice, alice);

        // Fast forward past delay
        vm.warp(block.timestamp + DEFAULT_DELAY);

        uint256 aliceAssetsBefore = wmon.balanceOf(alice);

        // Alice claims withdrawal
        vm.prank(alice);
        uint256 sharesBurned = magma.withdraw(withdrawAmount, alice, alice);

        // Check assets transferred
        assertEq(wmon.balanceOf(alice), aliceAssetsBefore + withdrawAmount);

        // Check request is cleared
        assertEq(magma.pendingWithdrawRequest(alice), 0);
        assertEq(magma.balanceOf(address(magma)), 0);
    }

    function test_ClaimRedeem() public {
        uint256 depositAmount = 1000e18;
        uint256 redeemShares = 500e18;

        // Setup: Alice deposits and requests redemption
        vm.prank(alice);
        magma.deposit(depositAmount, alice);

        vm.prank(alice);
        magma.requestRedeem(redeemShares, alice, alice);

        // Fast forward past delay
        vm.warp(block.timestamp + DEFAULT_DELAY);

        uint256 aliceAssetsBefore = wmon.balanceOf(alice);

        // Alice claims redemption
        vm.prank(alice);
        uint256 assetsReceived = magma.redeem(redeemShares, alice, alice);

        // Check assets transferred
        assertEq(wmon.balanceOf(alice), aliceAssetsBefore + assetsReceived);

        // Check request is cleared
        assertEq(magma.pendingRedeemRequest(alice), 0);
        assertEq(magma.balanceOf(address(magma)), 0);
    }

    function test_PartialClaim() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 500e18;
        uint256 partialClaim = 200e18;

        // Setup: Alice deposits and requests withdrawal
        vm.prank(alice);
        magma.deposit(depositAmount, alice);

        vm.prank(alice);
        magma.requestWithdraw(withdrawAmount, alice, alice);

        // Fast forward past delay
        vm.warp(block.timestamp + DEFAULT_DELAY);

        // Alice claims partial withdrawal
        vm.prank(alice);
        magma.withdraw(partialClaim, alice, alice);

        // Check remaining request
        assertEq(
            magma.pendingWithdrawRequest(alice),
            withdrawAmount - partialClaim
        );
        assertTrue(magma.balanceOf(address(magma)) > 0);
    }

    function test_OperatorApproval() public {
        // Alice approves Bob as operator
        vm.prank(alice);
        assertTrue(magma.setOperator(bob, true));

        assertTrue(magma.isOperator(alice, bob));

        // Bob can now act on behalf of Alice
        vm.prank(alice);
        magma.deposit(1000e18, alice);

        vm.prank(bob);
        magma.requestWithdraw(500e18, alice, alice);

        assertEq(magma.pendingWithdrawRequest(alice), 500e18);
    }

    function test_RevertInsufficientShares() public {
        vm.prank(alice);
        magma.deposit(100e18, alice);

        // Try to request more than available
        vm.expectRevert("Magma: insufficient shares");
        vm.prank(alice);
        magma.requestWithdraw(1000e18, alice, alice);
    }

    function test_RevertUnauthorized() public {
        vm.prank(alice);
        magma.deposit(1000e18, alice);

        // Bob tries to request withdrawal for Alice without approval
        vm.expectRevert("Magma: not authorized");
        vm.prank(bob);
        magma.requestWithdraw(500e18, alice, alice);
    }

    function test_RevertNoPendingRequest() public {
        // Try to claim without pending request
        vm.expectRevert("Magma: no pending withdraw request");
        vm.prank(alice);
        magma.withdraw(100e18, alice, alice);
    }

    function test_RevertInsufficientClaimable() public {
        vm.prank(alice);
        magma.deposit(1000e18, alice);

        vm.prank(alice);
        magma.requestWithdraw(5 ether, alice, alice);

        // Try to claim before any time has passed
        vm.expectRevert("Magma: insufficient claimable assets");
        vm.prank(alice);
        magma.withdraw(500e18, alice, alice);
    }
}

// Test contract for native MON deposit/redeem functionality
contract MagmaNativeTest is Test {
    Magma public magma;
    WrappedMonad public wmon;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public admin = address(0x99); // Admin for pause tests

    function setUp() public {
        // Deploy WrappedMonad
        wmon = new WrappedMonad();

        // Deploy Magma vault with WrappedMonad as underlying asset (admin will be the deployer)
        vm.prank(admin);
        magma = new Magma(IERC20(address(wmon)), "gMON", "gMON");

        // Give test accounts some native currency
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function test_DepositMon() public {
        uint256 depositAmount = 1 ether;

        uint256 aliceSharesBefore = magma.balanceOf(alice);
        uint256 vaultAssetsBefore = magma.totalAssets();

        // Alice deposits native MON
        vm.prank(alice);
        uint256 shares = magma.depositMon{value: depositAmount}();

        // Check shares were minted
        assertEq(magma.balanceOf(alice), aliceSharesBefore + shares);
        assertEq(shares, depositAmount); // 1:1 ratio initially

        // Check vault received the wrapped assets
        assertEq(magma.totalAssets(), vaultAssetsBefore + depositAmount);
        assertEq(wmon.balanceOf(address(magma)), depositAmount);
    }

    // Removed: depositMon now always mints to msg.sender

    function test_RedeemMon() public {
        uint256 depositAmount = 2 ether;
        uint256 redeemShares = 1 ether;

        // Alice deposits native MON first
        vm.prank(alice);
        magma.depositMon{value: depositAmount}();

        uint256 aliceBalanceBefore = alice.balance;
        uint256 aliceSharesBefore = magma.balanceOf(alice);

        // Alice redeems shares for native MON
        vm.prank(alice);
        uint256 assets = magma.redeemMon(redeemShares, alice, alice);

        // Check Alice received native MON
        assertEq(alice.balance, aliceBalanceBefore + assets);
        assertEq(assets, redeemShares); // 1:1 ratio

        // Check shares were burned
        assertEq(magma.balanceOf(alice), aliceSharesBefore - redeemShares);
    }

    function test_RedeemMonToReceiver() public {
        uint256 depositAmount = 2 ether;
        uint256 redeemShares = 1 ether;

        // Alice deposits native MON
        vm.prank(alice);
        magma.depositMon{value: depositAmount}();

        uint256 bobBalanceBefore = bob.balance;

        // Alice redeems but native MON goes to Bob
        vm.prank(alice);
        uint256 assets = magma.redeemMon(redeemShares, bob, alice);

        // Check Bob received the native MON
        assertEq(bob.balance, bobBalanceBefore + assets);
        assertEq(alice.balance, 100 ether - depositAmount); // Alice only spent deposit
    }

    function test_RedeemMonWithAllowance() public {
        uint256 depositAmount = 2 ether;
        uint256 redeemShares = 1 ether;

        // Alice deposits and approves Bob
        vm.prank(alice);
        magma.depositMon{value: depositAmount}();

        vm.prank(alice);
        magma.approve(bob, redeemShares);

        uint256 bobBalanceBefore = bob.balance;

        // Bob redeems Alice's shares to himself
        vm.prank(bob);
        uint256 assets = magma.redeemMon(redeemShares, bob, alice);

        // Check Bob received the native MON
        assertEq(bob.balance, bobBalanceBefore + assets);

        // Check allowance was spent
        assertEq(magma.allowance(alice, bob), 0);
    }

    function test_RevertDepositMonZeroAmount() public {
        vm.expectRevert("Magma: zero native asset");
        vm.prank(alice);
        magma.depositMon{value: 0}();
    }

    function test_RevertDepositMonZeroAddress() public {
        // Not applicable anymore: receiver is msg.sender. Just ensure a normal deposit works.
        vm.prank(alice);
        magma.depositMon{value: 1 ether}();
    }

    function test_RevertRedeemMonZeroShares() public {
        vm.expectRevert("Magma: zero shares");
        vm.prank(alice);
        magma.redeemMon(0, alice, alice);
    }

    function test_RevertRedeemMonZeroAddress() public {
        // Alice needs shares first
        vm.prank(alice);
        magma.depositMon{value: 1 ether}();

        vm.expectRevert("Magma: zero address");
        vm.prank(alice);
        magma.redeemMon(1 ether, address(0), alice);
    }

    function test_RevertRedeemMonInsufficientAllowance() public {
        // Alice deposits
        vm.prank(alice);
        magma.depositMon{value: 1 ether}();

        // Bob tries to redeem Alice's shares without approval
        vm.expectRevert("Magma: insufficient allowance");
        vm.prank(bob);
        magma.redeemMon(1 ether, bob, alice);
    }

    function test_MultipleNativeOperations() public {
        // Alice deposits 3 ETH
        vm.prank(alice);
        magma.depositMon{value: 3 ether}();

        // Bob deposits 2 ETH
        vm.prank(bob);
        magma.depositMon{value: 2 ether}();

        // Check total vault state
        assertEq(magma.totalAssets(), 5 ether);
        assertEq(magma.balanceOf(alice), 3 ether);
        assertEq(magma.balanceOf(bob), 2 ether);

        // Alice redeems 1 ETH worth
        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        magma.redeemMon(1 ether, alice, alice);

        // Check final state
        assertEq(alice.balance, aliceBalanceBefore + 1 ether);
        assertEq(magma.balanceOf(alice), 2 ether);
        assertEq(magma.totalAssets(), 4 ether);
    }

    function test_PauseBlocksDeposit() public {
        // First wrap some native currency and approve
        vm.prank(alice);
        wmon.deposit{value: 10 ether}();
        vm.prank(alice);
        wmon.approve(address(magma), 1000e18);

        // Pause the contract
        vm.prank(admin);
        magma.pause();

        // Try to deposit - should revert
        vm.expectRevert("Magma: paused");
        vm.prank(alice);
        magma.deposit(10 ether, alice);
    }

    function test_PauseBlocksMint() public {
        // First wrap some native currency and approve
        vm.prank(alice);
        wmon.deposit{value: 10 ether}();
        vm.prank(alice);
        wmon.approve(address(magma), 1000e18);

        // Pause the contract
        vm.prank(admin);
        magma.pause();

        // Try to mint - should revert
        vm.expectRevert("Magma: paused");
        vm.prank(alice);
        magma.mint(10 ether, alice);
    }

    function test_PauseBlocksDepositMon() public {
        // Pause the contract
        vm.prank(admin);
        magma.pause();

        // Try to deposit native - should revert
        vm.expectRevert("Magma: paused");
        vm.prank(alice);
        magma.depositMon{value: 1 ether}();
    }

    function test_PauseBlocksRequestWithdraw() public {
        // First wrap some native currency and approve
        vm.prank(alice);
        wmon.deposit{value: 10 ether}();
        vm.prank(alice);
        wmon.approve(address(magma), 10 ether);

        // Make a deposit
        vm.prank(alice);
        magma.deposit(10 ether, alice);

        // Pause the contract
        vm.prank(admin);
        magma.pause();

        // Try to request withdraw - should revert
        vm.expectRevert("Magma: paused");
        vm.prank(alice);
        magma.requestWithdraw(5 ether, alice, alice);
    }

    function test_PauseBlocksRequestRedeem() public {
        // First wrap some native currency and approve
        vm.prank(alice);
        wmon.deposit{value: 10 ether}();
        vm.prank(alice);
        wmon.approve(address(magma), 10 ether);

        // Make a deposit
        vm.prank(alice);
        magma.deposit(10 ether, alice);

        // Pause the contract
        vm.prank(admin);
        magma.pause();

        // Try to request redeem - should revert
        vm.expectRevert("Magma: paused");
        vm.prank(alice);
        magma.requestRedeem(5 ether, alice, alice);
    }

    function test_PauseBlocksWithdrawClaim() public {
        // First wrap some native currency and approve
        vm.prank(alice);
        wmon.deposit{value: 10 ether}();
        vm.prank(alice);
        wmon.approve(address(magma), 10 ether);

        // Make a deposit and request withdrawal
        vm.prank(alice);
        magma.deposit(10 ether, alice);

        vm.prank(alice);
        magma.requestWithdraw(5 ether, alice, alice);

        // Fast forward time to make it claimable
        vm.warp(block.timestamp + 1 days);

        // Pause the contract
        vm.prank(admin);
        magma.pause();

        // Try to claim withdraw - should revert
        vm.expectRevert("Magma: paused");
        vm.prank(alice);
        magma.withdraw(5 ether, alice, alice);
    }

    function test_PauseBlocksRedeemClaim() public {
        // First wrap some native currency and approve
        vm.prank(alice);
        wmon.deposit{value: 10 ether}();
        vm.prank(alice);
        wmon.approve(address(magma), 10 ether);

        // Make a deposit and request redemption
        vm.prank(alice);
        magma.deposit(10 ether, alice);

        vm.prank(alice);
        magma.requestRedeem(5 ether, alice, alice);

        // Fast forward time to make it claimable
        vm.warp(block.timestamp + 1 days);

        // Pause the contract
        vm.prank(admin);
        magma.pause();

        // Try to claim redeem - should revert
        vm.expectRevert("Magma: paused");
        vm.prank(alice);
        magma.redeem(5 ether, alice, alice);
    }

    function test_PauseBlocksRedeemMon() public {
        // First make a deposit
        vm.prank(alice);
        magma.depositMon{value: 1 ether}();

        // Pause the contract
        vm.prank(admin);
        magma.pause();

        // Try to redeem native - should revert
        vm.expectRevert("Magma: paused");
        vm.prank(alice);
        magma.redeemMon(1 ether, alice, alice);
    }

    function test_UnpauseAllowsOperations() public {
        // First wrap some native currency and approve
        vm.prank(alice);
        wmon.deposit{value: 10 ether}();
        vm.prank(alice);
        wmon.approve(address(magma), 1000e18);

        // Pause the contract
        vm.prank(admin);
        magma.pause();

        // Unpause the contract
        vm.prank(admin);
        magma.unpause();

        // Now operations should work
        vm.prank(alice);
        magma.deposit(10 ether, alice);

        assertEq(magma.balanceOf(alice), 10 ether);
    }
}
