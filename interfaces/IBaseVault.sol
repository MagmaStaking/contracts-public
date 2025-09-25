// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IBaseVault {
    enum ValidatorStatus {
        NONE,
        PAUSED,
        UNDELEGATING
    }

    event ValidatorAdded(uint64 indexed valId);
    event ValidatorRemovalInitiated(uint64 indexed valId);
    event ValidatorRemoved(uint64 indexed valId);
    event ValidatorRemovalCompleted(uint64 indexed valId);
    event WithdrawalFeeTransferFailed(uint256 indexed amount);
    event WithdrawalFeeTransferSuccess(uint256 indexed amount, address indexed receiver);

    event UserWithdrawalCompleted(address indexed user, uint256 indexed totalWithdrawn);
    event WithdrawalPaymentSuccess(
        uint64 indexed valId, uint8 indexed withdrawalId, address indexed user, uint256 amount
    );
    event WithdrawalFailed(uint64 indexed valId, uint8 indexed withdrawalId);
    // Events for user withdrawal completion
    event WithdrawalNotReady(
        uint64 indexed valId, uint8 indexed withdrawalId, address indexed user, uint256 requestedAmount
    );

    event RewardsClaimed(uint64 indexed valId, uint256 indexed amount);
    event RewardsFeeTransferFailed(uint256 indexed amount);
    event RewardsFeeTransferSuccess(uint256 indexed amount, address indexed receiver);
    event DelegatorInfoUpdateIntervalChanged(uint256 indexed newInterval);
    event MinUserWithdrawAmountUpdated(uint256 indexed newAmount);

    function initiateValidatorRemoval(uint64 valId) external;
    function setMinUserWithdrawAmount(uint256 amount) external;
    function setDelegatorInfoUpdateInterval(uint256 interval) external;

    function isWhitelisted(uint64 valId) external view returns (bool);
    function pendingRedelegateByValidator(uint64 valId) external view returns (uint256);
    function pendingUndelegateByValidator(uint64 valId) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalPendingRedelegation() external view returns (uint256);
    function totalPendingUndelegations() external view returns (uint256);
    function validators(uint256 index) external view returns (uint64);
    function validatorStatus(uint64 valId) external view returns (ValidatorStatus);
    function lastDelegatorInfoUpdateTimestamp() external view returns (uint256);
    function delegatorInfoUpdateInterval() external view returns (uint256);
    function refreshCacheCheck() external;
    function refreshCache() external;
}
