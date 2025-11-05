// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Generic access/role
error ErrNotAuthorized();
error ErrNotMagma();

// Address/inputs
error ErrZeroAddress();
error ErrZeroAssets();
error ErrZeroShares();
error ErrInvalidBps();
error ErrInvalidAmount(uint256 amount);
error ErrBelowMinWithdraw(uint256 min);
error ErrZeroAmount();
error ErrZeroValidatorId();

// State/availability
error ErrInsufficientShares(uint256 requested, uint256 balance);
error ErrRequestPending();
error ErrInsufficientDelegated(uint256 required, uint256 available);
error ErrNoPendingWithdrawRequest();
error ErrNotWhitelisted();
error ErrAlreadyWhitelisted();
error ErrNoValidators();
error ErrEpochGuard();
error ErrRebalanceInProgress();
error ErrRebalanceNotInProgress();
error ErrCapZero();
error ErrExceedsCap();
error ErrRequestInexistent();
error ErrNotEnoughAssetsGVault();
error ErrVaultsSet();
error ErrValidatorAdded();
error ErrValidatorInRemoval();

// External call failures
error ErrDelegateFailed();
error ErrUndelegateFailed();
error ErrNativeTransferFailed();
error ErrTokenTransferFailed();

// Queues / IDs
error ErrAdminWidInUse();

// Validator admin ops
error ErrPendingStakeNotZero();
error ErrInvalidStatus();
error ErrNotEnoughValidators();
error ErrMaxValidators(uint64 errMaxValidators);

// Withdrawal ordering errors
error ErrExistingWithdrawalInProgress();
error ErrWithdrawalFailed(uint64 valId, uint8 withdrawalId);

// Reward claiming errors
error ErrRewardsClaimOverdue();
