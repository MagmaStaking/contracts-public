// // Test contract for native MON deposit/redeem functionality
// contract MagmaNativeTest is BaseTest {
//     address public alice = address(0x1);
//     address public bob = address(0x2);

//     function setUp() public override {
//         super.setUp();

//         // Give test accounts some native currency
//         vm.deal(alice, 100 ether);
//         vm.deal(bob, 100 ether);
//     }

//     // Helper function to be called in tests after deposits
//     function _activateStakes() internal {
//         _activateDelegatedStakes();
//     }

//     function testRedeemMonWithAllowance() public {
//         uint256 depositAmount = 2 ether;
//         uint256 redeemShares = 1 ether;

//         // Native deposit
//         vm.prank(alice);
//         magma.depositMon{value: depositAmount}();

//         // Activate the delegated stakes in the mock
//         _activateStakes();

//         // Async: Alice schedules redeem to controller Bob, then Bob claims ERC20 assets to himself
//         vm.prank(alice);
//         magma.requestRedeem(redeemShares, bob, alice);
//         vm.warp(block.timestamp + 1 days);
//         // Simulate completed withdrawal by funding contract with ETH for wrapping
//         vm.deal(address(magma), redeemShares);
//         uint256 wmonBeforeBob = wmon.balanceOf(bob);
//         vm.prank(bob);
//         uint256 assets = magma.redeem(redeemShares, bob, bob);
//         assertEq(wmon.balanceOf(bob), wmonBeforeBob + assets);
//     }

//     function testRevertRedeemMonInsufficientAllowance() public {
//         // Alice deposits
//         vm.prank(alice);
//         magma.depositMon{value: 1 ether}();

//         // Bob tries to redeem Alice's shares without approval
//         vm.expectRevert(ErrNotAuthorized.selector);
//         vm.prank(bob);
//         magma.redeemMon(1 ether, bob, alice);
//     }

//     function testMultipleNativeOperations() public {
//         // Native deposits
//         vm.prank(alice);
//         magma.depositMon{value: 3 ether}();
//         vm.prank(bob);
//         magma.depositMon{value: 2 ether}();

//         // Activate the delegated stakes in the mock
//         _activateStakes();

//         // Check total vault state
//         assertEq(magma.totalAssets(), 5 ether);
//         assertEq(magma.balanceOf(alice), 3 ether);
//         assertEq(magma.balanceOf(bob), 2 ether);

//         // Async redeem: request and claim ERC20 asset
//         vm.prank(alice);
//         magma.requestRedeem(1 ether, alice, alice);
//         vm.warp(block.timestamp + 1 days);
//         // Simulate completed withdrawal by funding contract with ETH for wrapping
//         vm.deal(address(magma), 1 ether);
//         uint256 wmonBefore = wmon.balanceOf(alice);
//         vm.prank(alice);
//         uint256 assets = magma.redeem(1 ether, alice, alice);
//         assertEq(wmon.balanceOf(alice), wmonBefore + assets);
//         assertEq(magma.balanceOf(alice), 2 ether);
//         assertEq(magma.totalAssets(), 4 ether);
//     }

// TODO: do the pause for everything
//     function testPauseBlocksDeposit() public {
//         // First wrap some native currency and approve
//         vm.prank(alice);
//         wmon.deposit{value: 10 ether}();
//         vm.prank(alice);
//         wmon.approve(address(magma), 1000e18);

//         // Pause the contract
//         vm.prank(admin);
//         magma.pause();

//         // Try to deposit - should revert
//         vm.expectRevert(ErrPaused.selector);
//         vm.prank(alice);
//         magma.deposit(10 ether, alice);
//     }

//     function testPauseBlocksMint() public {
//         // First wrap some native currency and approve
//         vm.prank(alice);
//         wmon.deposit{value: 10 ether}();
//         vm.prank(alice);
//         wmon.approve(address(magma), 1000e18);

//         // Pause the contract
//         vm.prank(admin);
//         magma.pause();

//         // Try to mint - should revert
//         vm.expectRevert(ErrPaused.selector);
//         vm.prank(alice);
//         magma.mint(10 ether, alice);
//     }

//     function testPauseBlocksDepositMon() public {
//         // Pause the contract
//         vm.prank(admin);
//         magma.pause();

//         // Try to deposit native - should revert
//         vm.expectRevert(ErrPaused.selector);
//         vm.prank(alice);
//         magma.depositMon{value: 1 ether}();
//     }

//     function testPauseBlocksRequestWithdraw() public {
//         // First wrap some native currency and approve
//         vm.prank(alice);
//         wmon.deposit{value: 10 ether}();
//         vm.prank(alice);
//         wmon.approve(address(magma), 10 ether);

//         // Make a deposit
//         vm.prank(alice);
//         magma.deposit(10 ether, alice);

//         // Pause the contract
//         vm.prank(admin);
//         magma.pause();

//         // Try to request withdraw - should revert
//         vm.expectRevert(ErrPaused.selector);
//         vm.prank(alice);
//         magma.requestWithdraw(5 ether, alice, alice);
//     }

//     function testPauseBlocksRequestRedeem() public {
//         // First wrap some native currency and approve
//         vm.prank(alice);
//         wmon.deposit{value: 10 ether}();
//         vm.prank(alice);
//         wmon.approve(address(magma), 10 ether);

//         // Make a deposit
//         vm.prank(alice);
//         magma.deposit(10 ether, alice);

//         // Pause the contract
//         vm.prank(admin);
//         magma.pause();

//         // Try to request redeem - should revert
//         vm.expectRevert(ErrPaused.selector);
//         vm.prank(alice);
//         magma.requestRedeem(5 ether, alice, alice);
//     }

//     function testPauseBlocksWithdrawClaim() public {
//         // First wrap some native currency and approve
//         vm.prank(alice);
//         wmon.deposit{value: 10 ether}();
//         vm.prank(alice);
//         wmon.approve(address(magma), 10 ether);

//         // Make a deposit and request withdrawal
//         vm.prank(alice);
//         magma.deposit(10 ether, alice);

//         // Activate the delegated stakes in the mock
//         _activateStakes();

//         vm.prank(alice);
//         magma.requestWithdraw(5 ether, alice, alice);

//         // Fast forward time to make it claimable
//         vm.warp(block.timestamp + 1 days);

//         // Pause the contract
//         vm.prank(admin);
//         magma.pause();

//         // Try to claim withdraw - should revert
//         vm.expectRevert(ErrPaused.selector);
//         vm.prank(alice);
//         magma.withdraw(5 ether, alice, alice);
//     }

//     function testPauseBlocksRedeemClaim() public {
//         // First wrap some native currency and approve
//         vm.prank(alice);
//         wmon.deposit{value: 10 ether}();
//         vm.prank(alice);
//         wmon.approve(address(magma), 10 ether);

//         // Make a deposit and request redemption
//         vm.prank(alice);
//         magma.deposit(10 ether, alice);

//         // Activate the delegated stakes in the mock
//         _activateStakes();

//         vm.prank(alice);
//         magma.requestRedeem(5 ether, alice, alice);

//         // Fast forward time to make it claimable
//         vm.warp(block.timestamp + 1 days);

//         // Pause the contract
//         vm.prank(admin);
//         magma.pause();

//         // Try to claim redeem - should revert
//         vm.expectRevert(ErrPaused.selector);
//         vm.prank(alice);
//         magma.redeem(5 ether, alice, alice);
//     }

//     function testPauseBlocksRedeemMon() public {
//         // First make a deposit
//         vm.prank(alice);
//         magma.depositMon{value: 1 ether}();

//         // Pause the contract
//         vm.prank(admin);
//         magma.pause();

//         // Try to redeem native - should revert
//         vm.expectRevert(ErrPaused.selector);
//         vm.prank(alice);
//         magma.redeemMon(1 ether, alice, alice);
//     }

//     function test_Paused_Blocks_All_ERC4626_Methods() public {
//         // Pause: deposit and mint should revert
//         vm.prank(admin);
//         magma.pause();

//         vm.expectRevert(ErrPaused.selector);
//         vm.prank(alice);
//         magma.deposit(1 ether, alice);

//         vm.expectRevert(ErrPaused.selector);
//         vm.prank(alice);
//         magma.mint(1 ether, alice);

//         // Unpause to set up pending withdraw
//         vm.prank(admin);
//         magma.unpause();

//         // Provide WMON to allow ERC4626 deposit after unpause
//         vm.deal(alice, 20 ether);
//         vm.prank(alice);
//         wmon.deposit{value: 10 ether}();
//         vm.prank(alice);
//         wmon.approve(address(magma), 10 ether);
//         vm.prank(alice);
//         magma.deposit(10 ether, alice);

//         // Activate the delegated stakes in the mock
//         _activateStakes();

//         vm.prank(alice);
//         magma.requestWithdraw(5 ether, alice, alice);
//         vm.warp(block.timestamp + 1 days);

//         // Pause again: withdraw should revert
//         vm.prank(admin);
//         magma.pause();
//         vm.expectRevert();
//         vm.prank(alice);
//         magma.withdraw(5 ether, alice, alice);

//         // Unpause to set up redeem on Bob
//         vm.prank(admin);
//         magma.unpause();
//         vm.deal(bob, 20 ether);
//         vm.prank(bob);
//         wmon.deposit{value: 10 ether}();
//         vm.prank(bob);
//         wmon.approve(address(magma), 10 ether);
//         vm.prank(bob);
//         magma.deposit(10 ether, bob);
//         vm.prank(bob);
//         magma.requestRedeem(5 ether, bob, bob);
//         vm.warp(block.timestamp + 1 days);

//         // Pause again: redeem should revert
//         vm.prank(admin);
//         magma.pause();
//         vm.expectRevert();
//         vm.prank(bob);
//         magma.redeem(5 ether, bob, bob);
//     }

//     function testUnpauseAllowsOperations() public {
//         // First wrap some native currency and approve
//         vm.prank(alice);
//         wmon.deposit{value: 10 ether}();
//         vm.prank(alice);
//         wmon.approve(address(magma), 1000e18);

//         // Pause the contract
//         vm.prank(admin);
//         magma.pause();

//         // Unpause the contract
//         vm.prank(admin);
//         magma.unpause();

//         // Now operations should work
//         vm.prank(alice);
//         magma.deposit(10 ether, alice);

//         assertEq(magma.balanceOf(alice), 10 ether);
//     }
// }
