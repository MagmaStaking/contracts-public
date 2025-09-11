// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseTest} from "./BaseTest.t.sol";
import {MockStakingPrecompile} from "./mock/MockStakingPrecompile.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Minimal test harness for rewards claiming + fee and redistribution paths.
contract RevertingReceiver {
    receive() external payable {
        revert();
    }
}

contract CoreVaultRewardsTest is BaseTest {
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
        uint256 expectedFee = Math.mulDiv(10 ether, magma.rewardsFee(), 1000, Math.Rounding.Ceil);
        assertEq(feeReceiverAfter - feeReceiverBefore, expectedFee, "fee incorrect");

        // Remaining rewards should be redelegated equally to validators; we can only assert CoreVault didn't keep funds
        uint256 coreAfter = address(coreVault).balance;
        assertEq(coreAfter, coreBefore, "coreVault should not retain funds after redistribution");
    }

    // todo: Test: zero fee
}
