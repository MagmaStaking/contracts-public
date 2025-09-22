// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseTest} from "./BaseTest.t.sol";
import {MockStakingPrecompile} from "./mock/MockStakingPrecompile.sol";

// Minimal test harness for rewards claiming + fee and redistribution paths.
contract RevertingReceiver {
    receive() external payable {
        revert();
    }
}

contract CoreVaultRewardsTest is BaseTest {
    function _mulDivCeil1000(uint256 x, uint256 y) internal pure returns (uint256) {
        // computes ceil(x * y / 1000)
        uint256 prod = x * y;
        return (prod + 999) / 1000;
    }

    uint64 constant VAL_1 = 1;
    uint64 constant VAL_2 = 2;

    function setUp() public override {
        BaseTest.setUp();
    }

    // Test: fee charged and sent to receiver; remainder redelegated equally
    function testRewardsFeeAndRedistribution() public {
        // BaseTest already etched and initialized mock precompile and added validators 1,2
        MockStakingPrecompile mock = MockStakingPrecompile(STAKING_PRECOMPILE);

        mock.setDelegatorRewards(1, address(coreVault), 6 ether);
        mock.setDelegatorRewards(2, address(coreVault), 4 ether);

        uint256 feeReceiverBefore = admin.balance; // BaseTest initializes rewardsFeeReceiver = admin
        uint256 coreBefore = address(coreVault).balance;

        // Call
        coreVault.claimAndCompoundRewards();

        // Rewards total = 10 ether; fee uses magma.rewardsFee() per 1000
        uint256 feeReceiverAfter = admin.balance;
        uint256 expectedFee = _mulDivCeil1000(10 ether, magma.rewardsFee());
        assertEq(feeReceiverAfter - feeReceiverBefore, expectedFee, "fee incorrect");

        // Remaining rewards should be redelegated equally to validators; we can only assert CoreVault didn't keep funds
        uint256 coreAfter = address(coreVault).balance;
        assertEq(coreAfter, coreBefore, "coreVault should not retain funds after redistribution");
    }

    // todo: Test: zero fee

    function testWithdrawalsFeeIsCharged() public {
        // Configure withdrawal fee and receiver as admin
        vm.startPrank(admin);
        magma.setWithdrawalFee(10); // 10 per 1000 = 1%
        magma.setFeeReceiver(admin);
        vm.stopPrank();

        // Seed large base stake to avoid 1/20 cap issues (mirrors helpers in other tests)
        uint256 depositAmt = 10 ether;
        uint256 booster = depositAmt * 100;
        vm.deal(address(1000), booster);
        vm.startPrank(address(1000));
        wmon.deposit{value: booster}();
        wmon.approve(address(magma), booster);
        magma.deposit(booster, address(1000));
        vm.stopPrank();

        // User deposits into Magma (delegated to CoreVault)
        vm.deal(user, depositAmt);
        vm.prank(user);
        magma.depositMON{value: depositAmt}(user, 0);
        _activateAllStakes();

        // Request redeem respecting CoreVault 1/20 per-request cap
        uint256 shares = magma.balanceOf(user);
        uint256 sharesToRedeem = shares / 20;
        vm.prank(user);
        uint256 requestId = magma.requestRedeem(sharesToRedeem, user, user);

        // Wait for async delay and withdrawal maturity in the mock
        vm.warp(block.timestamp + magma.DEFAULT_DELAY());
        _advanceEpochsForWithdrawal();

        // Balances before completion
        uint256 feeReceiverBefore = admin.balance;
        uint256 magmaBefore = address(magma).balance;

        // Complete withdrawal directly on CoreVault from Magma context (mirrors other tests)
        vm.prank(address(magma));
        (uint256 gross,) = coreVault.completeUserWithdrawal(user);

        // Expect 1% fee (per 1000 rounding) on gross ~= deposit/20 for first deposit
        uint256 expectedGross = depositAmt / 20;
        uint256 expectedFee = _mulDivCeil1000(expectedGross, magma.withdrawalFee());
        assertEq(gross, expectedGross, "gross withdrawn should equal expected gross");

        // Assert actual transfers: fee to admin, net to Magma
        assertEq(admin.balance - feeReceiverBefore, expectedFee, "fee receiver received fee");
        assertEq(address(magma).balance - magmaBefore, expectedGross - expectedFee, "magma received net amount");
    }
}
