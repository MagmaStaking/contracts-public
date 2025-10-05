// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Generic access/role
error ErrNotAdmin();
error ErrNotAuthorized();
error ErrNotMagma();

// Address/inputs
error ErrZeroAddress();
error ErrZeroAssets();
error ErrZeroShares();
error ErrZeroNativeAsset();
error ErrInvalidBps();
error ErrInvalidAmount(uint256 amount);
error ErrBelowMinWithdraw(uint256 min);
error ErrZeroAmount();
error ErrZeroValidatorId();
error ErrInvalidRewardsFee();
error ErrInvalidZeroInput();

// State/availability
error ErrInsufficientShares(uint256 requested, uint256 balance);
error ErrRequestPending();
error ErrInsufficientDelegated(uint256 required, uint256 available);
error ErrNoPendingWithdrawRequest();
error ErrNotGVault();
error ErrNotWhitelisted();
error ErrAlreadyWhitelisted();
error ErrNoValidators();
error ErrAmountTooSmall();
error ErrInsufficientPosition(uint256 requested, uint256 balance);
error ErrEpochGuard();
error ErrRebalanceInProgress();
error ErrCapZero();
error ErrExceedsCap();
error ErrRequestInexistent();
error ErrNotEnoughAssetsGVault();
error ErrVaultsSet();
// External call failures
error ErrDelegateFailed();
error ErrUndelegateFailed();
error ErrGVUndelegateFailed();
error ErrGVCompleteFailed();
error ErrNativeTransferFailed();
error ErrTokenTransferFailed();
error ErrForwardFailed();
error ErrRebalanceInitiateFailed();
error ErrRebalanceCompleteFailed();

// Queues / IDs
error ErrQueueFull();
error ErrNoFreeWithdrawalId();
error ErrAdminWidInUse();

// Validator admin ops
error ErrMustPauseBeforeRemove();
error ErrPendingStakeNotZero();
error ErrInvalidStatus();
error ErrNotEnoughValidators();
error ErrMaxValidators(uint64 errMaxValidators);

// Withdrawal ordering errors
error ErrExceedsOnetwentiethThreshold(uint256 amount, uint256 threshold);
error ErrExistingWithdrawalInProgress();
error ErrWithdrawalFailed(uint64 valId, uint8 withdrawalId);
