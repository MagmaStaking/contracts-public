// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MagmaBase} from "./MagmaBase.sol";
import {MagmaRoleManagementModule} from "./MagmaRoleManagementModule.sol";
import {ErrInvalidRewardsFee, ErrInvalidZeroInput} from "./MagmaErrorsModule.sol";

// TODO: fr -> this is not connected anywhere, we should first do a schema on how fees should be tracked
abstract contract MagmaRewardsCalculator is MagmaBase {
    event RewardsFeeSet(uint256 newFee);
    event RewardsFeeReceiverSet(address newFeeReceiver);
    // change fee

    function _setFee(uint256 newFee) internal {
        if (newFee == 0 || newFee > 100) revert ErrInvalidRewardsFee();
        rewardsFee = newFee;
        emit RewardsFeeSet(newFee);
    }

    // change fee receiver
    function _setFeeReceiver(address newFeeReceiver) internal {
        if (newFeeReceiver == address(0)) revert ErrInvalidZeroInput();
        rewardsFeeReceiver = newFeeReceiver;
        emit RewardsFeeReceiverSet(newFeeReceiver);
    }

    // set princal assets for user
    function _addPrincipalAssets(address user, uint256 amount) internal {
        principalAssets[user] += amount;
    }

    function _removePrincipalAssets(address user, uint256 amount) internal {
        principalAssets[user] -= amount;
    }

    function _calculateRewardsFee(uint256 withdrawalAmount, uint256 totalCurrentAssets, uint256 principalAssets)
        internal
        view
        returns (uint256 fee)
    {
        if (withdrawalAmount == 0 || rewardsFee == 0) return 0;

        uint256 accumulatedYield = totalCurrentAssets - principalAssets;
        if (accumulatedYield == 0) return 0;

        uint256 yieldShare = Math.mulDiv(withdrawalAmount, accumulatedYield, totalCurrentAssets);

        fee = Math.mulDiv(yieldShare, rewardsFee, 100, Math.Rounding.Ceil);
    }
}
