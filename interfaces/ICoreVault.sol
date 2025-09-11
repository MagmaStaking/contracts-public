// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMagma} from "./IMagma.sol";
import {IBaseVault} from "./IBaseVault.sol";

interface ICoreVault is IBaseVault {
    // Admin functions
    function addValidator(uint64 valId) external;
    function initiateValidatorRemoval(uint64 valId) external;
    function executeValidatorUndelegation(uint64 valId) external;
    function completeValidatorRemovalWithdrawal(uint64 valId) external;
    function adminRebalanceInitiate() external;
    function pause() external;
    function unpause() external;
    function setMinQueueDelaySeconds(uint256 secondsDelay) external;
    function setMinUserWithdrawAmount(uint256 amount) external;

    // Delegation functions (onlyMagma)
    function delegate() external payable;
    function undelegate(uint256 amount, address user) external;

    // Withdrawal completion function
    function completeUserWithdrawal(address user) external returns (uint256 totalWithdrawn);

    // Initialization
    function initialize(address _magma, uint256 _minQueueDelaySeconds, uint256 _epochSeconds) external;

    // View functions
    function delegatedAmount(uint64 valId) external view returns (uint256);
    function pendingUndelegateByValidator(uint64 valId) external view returns (uint256);
    function minQueueDelaySeconds() external view returns (uint256);
    function epochSeconds() external view returns (uint256);
    function minUserWithdrawAmount() external view returns (uint256);
    function lastRebalanceTimestamp() external view returns (uint256);
    function totalPendingUndelegations() external view returns (uint256);
    function totalPendingRedelegation() external view returns (uint256);
    function finishedLastRebalance() external view returns (bool);
    function paused() external view returns (bool);
    function getValidators() external view returns (uint64[] memory);
    function getValidatorCount() external view returns (uint256);
    function getTotalDelegated() external view returns (uint256);

    // Events
    event ValidatorAdded(uint64 indexed valId);
    event ValidatorRemoved(uint64 indexed valId);
    event ValidatorRemovalCompleted(uint64 indexed valId);
    event RebalanceInitiated();
    event RebalanceCompleted();
    event SubmittedUndelegate(uint8 withdrawalId, uint256 perValidatorAmount, uint256 validatorCount);
    // User withdrawal distribution events (mirrors gVault for consistency)
    event WithdrawalAmountMismatch(
        uint64 indexed valId,
        uint8 indexed withdrawalId,
        uint256 totalDue,
        uint256 totalDistributed,
        uint256 expectedDueForUser,
        address indexed user
    );
    event WithdrawalPaymentFailed(
        uint64 indexed valId, uint8 indexed withdrawalId, address indexed user, uint256 amount
    );
    event WithdrawalPaymentSuccess(
        uint64 indexed valId, uint8 indexed withdrawalId, address indexed user, uint256 amount
    );
    event WithdrawalFailed(uint64 indexed valId, uint8 indexed withdrawalId);

    event ValidatorRemovalInitiated(uint64 indexed valId);

    event RewardsClaimed(uint64 indexed valId, uint256 indexed amount);
    event RewardsFeeTransferFailed(uint256 indexed amount);
    event RewardsFeeTransferSuccess(uint256 indexed amount, address indexed receiver);
}
