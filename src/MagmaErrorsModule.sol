// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// Generic access/role
error ErrNotAdmin();
error ErrPaused();
error ErrAlreadyPaused();
error ErrNotPaused();
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
error ErrCoreVaultNotSet();
error ErrGVaultNotSet();
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

// External call failures
error ErrDelegateFailed();
error ErrUndelegateFailed();
error ErrCompleteUndelegationFailed();
error ErrGVDelegateFailed();
error ErrGVUndelegateFailed();
error ErrGVCompleteFailed();
error ErrWrapFailed();
error ErrNativeTransferFailed();
error ErrForwardFailed();
error ErrRebalanceInitiateFailed();
error ErrRebalanceCompleteFailed();

// Queues / IDs
error ErrQueueFull();
error ErrNoFreeWithdrawalId();

// Validator admin ops
error ErrMustPauseBeforeRemove();
