// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseTest} from "./BaseTest.t.sol";
import {MockStakingPrecompile} from "./mock/MockStakingPrecompile.sol";

// Minimal test harness for rewards claiming + fee and per-validator compounding paths for gVault
contract GVaultRewardsTest is BaseTest {
    function _mulDivCeil1000(uint256 x, uint256 y) internal pure returns (uint256) {
        uint256 prod = x * y;
        return (prod + 9990) / 10_000;
    }

    uint64 constant VAL_1 = 1;

    function setUp() public override {
        BaseTest.setUp();

        // gVault manages its own validator list; add a validator to gVault for this test
        vm.prank(admin);
        gvault.addValidator(VAL_1);
    }

    // Test: fee charged and sent to receiver; remainder is redelegated back to the same validator in gVault
    function testRewardsFeeAndPerValidatorCompounding() public {
        MockStakingPrecompile mock = MockStakingPrecompile(STAKING_PRECOMPILE);

        // Seed rewards for gVault on the validator
        mock.setDelegatorRewards(VAL_1, address(gvault), 10 ether);

        uint256 feeReceiverBefore = admin.balance; // BaseTest initializes rewardsFeeReceiver = admin
        uint256 gvaultBefore = address(gvault).balance;

        // Call: gVault compounds rewards per validator
        gvault.claimAndCompoundRewards(VAL_1);

        // Rewards total = 10 ether; fee uses magma.rewardsFee() per 10_000
        uint256 feeReceiverAfter = admin.balance;
        uint256 expectedFee = _mulDivCeil1000(10 ether, magma.rewardsFee());
        assertEq(feeReceiverAfter - feeReceiverBefore, expectedFee, "fee incorrect");

        // Remaining rewards should be immediately re-delegated to VAL_1;
        // Assert that gVault did not retain funds
        uint256 gvaultAfter = address(gvault).balance;
        assertEq(gvaultAfter, gvaultBefore, "gVault should not retain funds after compounding");
    }

    function testWithdrawalsFeeIsCharged() public {
        // Configure withdrawal fee and receiver as admin
        vm.startPrank(admin);
        magma.setWithdrawalFee(100); // 100 per 10_000 = 1%
        magma.setFeeReceiver(admin);
        vm.stopPrank();

        // Seed large base stake to avoid 1/20 cap issues
        uint256 depositAmt = 10 ether;
        uint256 booster = depositAmt * 100;

        // Set explicit cap so deposits to VAL_1 won't hit default cap logic
        vm.prank(admin);
        gvault.changeValidatorCap(VAL_1, booster + depositAmt);

        vm.deal(address(1000), booster);
        vm.startPrank(address(1000));
        wmon.deposit{value: booster}();
        wmon.approve(address(magma), booster);
        // deposit to gVault path on Magma for validator VAL_1
        magma.depositGVault(booster, address(1000), VAL_1, 0);
        vm.stopPrank();

        // User deposits into gVault
        vm.deal(user, depositAmt);
        vm.startPrank(user);
        wmon.deposit{value: depositAmt}();
        wmon.approve(address(magma), depositAmt);
        magma.depositGVault(depositAmt, user, VAL_1, 0);
        vm.stopPrank();

        _activateAllStakes();

        // Request redeem respecting 1/20 cap, targeting gVault
        uint256 shares = magma.balanceOf(user);
        uint256 sharesToRedeem = shares / 20;
        vm.prank(user);
        uint256 requestId = magma.requestRedeemGVault(sharesToRedeem, user, user, VAL_1);

        // Wait for async delay and withdrawal maturity in the mock
        vm.warp(block.timestamp + magma.redeemDelay());
        _advanceEpochsForWithdrawal();

        // Balances before completion
        uint256 feeReceiverBefore = admin.balance;
        uint256 magmaBefore = address(magma).balance;

        // Complete withdrawal directly on gVault from Magma context
        vm.prank(address(magma));
        (uint256 gross,) = gvault.completeUserWithdrawal(user);

        // Expect 1% fee (per 1000 rounding) on gross ~= deposit/20
        uint256 expectedGross = depositAmt / 20;
        uint256 expectedFee = _mulDivCeil1000(expectedGross, magma.withdrawalFee());
        assertEq(gross, expectedGross, "gross withdrawn should equal expected gross");

        // Assert actual transfers: fee to admin, net to Magma
        assertEq(admin.balance - feeReceiverBefore, expectedFee, "fee receiver received fee");
        assertEq(address(magma).balance - magmaBefore, expectedGross - expectedFee, "magma received net amount");
    }
}
