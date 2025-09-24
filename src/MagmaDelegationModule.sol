// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ErrZeroAssets, ErrDelegateFailed, ErrUndelegateFailed, ErrWithdrawalFailed} from "./MagmaErrorsModule.sol";
import {IMonadStaking} from "../interfaces/IMonadStaking.sol";

/**
 * @title MagmaDelegationModule
 * @dev Abstract thin adapter over Monad staking precompile. Inherit in vaults so msg.sender == delegator.
 */
struct DelInfo {
    uint256 stake; // Current active stake
    uint256 acc; // Last checked accumulator
    uint256 rewards; // Last checked rewards
    uint256 deltaStake; // Stake to be activated next epoch
    uint256 nextDeltaStake; // Stake to be activated in 2 epochs
    uint64 deltaEpoch; // Epoch when deltaStake becomes active
    uint64 nextDeltaEpoch; // Epoch when nextDeltaStake becomes active
}

struct WithdrawalRequest {
    uint256 amount; // Amount to undelegate from validator
    uint256 acc; // Validator accumulator when undelegate was called
    uint64 epoch; // Epoch when undelegate stake deactivates
}

struct Accumulator {
    uint256 val; // Current accumulator value
    uint256 refcount; // Reference count for this accumulator value
}

abstract contract MagmaDelegationModule {
    address internal constant STAKING_PRECOMPILE = address(0x0000000000000000000000000000000000001000);
    IMonadStaking internal constant STAKING = IMonadStaking(STAKING_PRECOMPILE);

    function _delegate(uint64 valId, uint256 amount) internal {
        if (amount == 0) revert ErrZeroAssets();
        bool success = STAKING.delegate{value: amount}(valId);
        if (!success) revert ErrDelegateFailed();
    }

    function _undelegate(uint64 valId, uint256 amount, uint8 withdrawalId) internal {
        if (amount == 0) revert ErrZeroAssets();
        bool success = STAKING.undelegate(valId, amount, withdrawalId);
        if (!success) revert ErrUndelegateFailed();
    }

    function _withdraw(uint64 valId, uint8 withdrawalId) internal {
        bool success = STAKING.withdraw(valId, withdrawalId);
        if (!success) revert ErrWithdrawalFailed(valId, withdrawalId);
    }

    function _compound(uint64 valId) internal {
        bool success = STAKING.compound(valId);
        if (!success) revert ErrDelegateFailed();
    }

    function _claim(uint64 valId) internal {
        bool success = STAKING.claimRewards(valId);
        if (!success) revert ErrDelegateFailed();
    }

    function _getWithdrawalRequest(uint64 valId, address delegator, uint8 withdrawalId)
        internal
        returns (bool exists, uint256 amount, uint256 acc, uint64 epoch)
    {
        try STAKING.getWithdrawalRequest(valId, delegator, withdrawalId) returns (
            uint256 withdrawalAmount, uint256 accRewardPerToken, uint64 withdrawEpoch
        ) {
            amount = withdrawalAmount;
            acc = accRewardPerToken;
            epoch = withdrawEpoch;
            exists = (amount != 0);
        } catch {
            return (false, 0, 0, 0);
        }
    }

    // Typed function for delegator info: return stake amount (first word) per docs
    function _getDelegatorStake(uint64 valId, address delegator) internal view returns (uint256 stake) {
        try STAKING.getDelegator(valId, delegator) returns (
            uint256 _stake, uint256, uint256, uint256, uint256, uint64, uint64
        ) {
            stake = _stake;
        } catch {
            stake = 0;
        }
    }

    function _getDelegatorInfo(uint64 valId, address delegator) internal view returns (DelInfo memory del) {
        try STAKING.getDelegator(valId, delegator) returns (
            uint256 stake,
            uint256 accRewardPerToken,
            uint256 unclaimedRewards,
            uint256 deltaStake,
            uint256 nextDeltaStake,
            uint64 deltaEpoch,
            uint64 nextDeltaEpoch
        ) {
            del = DelInfo({
                stake: stake,
                acc: accRewardPerToken,
                rewards: unclaimedRewards,
                deltaStake: deltaStake,
                nextDeltaStake: nextDeltaStake,
                deltaEpoch: deltaEpoch,
                nextDeltaEpoch: nextDeltaEpoch
            });
        } catch {
            return DelInfo(0, 0, 0, 0, 0, 0, 0);
        }
    }
}
