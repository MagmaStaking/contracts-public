// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMagma} from "./IMagma.sol";
import {IBaseVault} from "./IBaseVault.sol";

interface IGVault is IBaseVault {
    // Admin functions
    function addValidator(uint64 valId) external;
    function removeValidator(uint64 valId) external;
    function changeValidatorCap(uint64 valId, uint256 newCap) external;
    function setDefaultCapBps(uint256 newBps) external;
    function setMinQueueDelaySeconds(uint256 secondsDelay) external;
    function setMinUserWithdrawAmount(uint256 amount) external;
    function pauseWithdrawalsForValidator(uint64 valId) external;
    function resumeWithdrawalsForValidator(uint64 valId) external;
    function adminInitiateRebalanceBps(uint16 bps) external;
    function adminCompleteRebalance() external;

    // Delegation functions (onlyMagma)
    function delegate(address user, uint64 valId) external payable;
    function undelegate(address user, uint64 valId, uint256 amount) external;

    // Withdrawal completion functions
    function completeWithdrawalForValidator(uint64 valId, uint8 wid) external;
    function processPending(uint64 valId) external;

    // Initialization
    function initialize(address _magma, uint256 _minQueueDelaySeconds, uint256 _epochSeconds) external;

    // View functions
    function delegatedAmountOf(address user, uint64 valId) external view returns (uint256);
    function userValidators(address user, uint256 index) external view returns (uint64);
    function userHasValidator(address user, uint64 valId) external view returns (bool);
    function validatorUsers(uint64 valId, uint256 index) external view returns (address);
    function validatorHasUser(uint64 valId, address user) external view returns (bool);
    function minQueueDelaySeconds() external view returns (uint256);
    function lastRebalanceTimestamp() external view returns (uint256);
    function epochSeconds() external view returns (uint256);
    function finishedLastRebalance() external view returns (bool);
    function minUserWithdrawAmount() external view returns (uint256);
    function queuedAmountByValidator(uint64 valId) external view returns (uint256);
    function queuedUserAmount(uint64 valId, address user) external view returns (uint256);
    function queueTxUserAddress(uint64 valId, uint256 index) external view returns (address);
    function queueTxUserAmount(uint64 valId, uint256 index) external view returns (uint256);
    function pendingTotalByValidator(uint64 valId) external view returns (uint256);
    function pendingUserAddress(uint64 valId, uint64 withdrawalId, uint256 index) external view returns (address);
    function pendingUserAmount(uint64 valId, uint64 withdrawalId, uint256 index) external view returns (uint256);
    function pendingValidatorWithdrawalId(uint64 valId) external view returns (uint8);
    function pausedWithdrawalsForValidator(uint64 valId) external view returns (uint256);
    function validatorCap(uint64 valId) external view returns (uint256);
    function defaultCapBps() external view returns (uint256);
    function getUserValidators(address user) external view returns (uint64[] memory);
    function getUserPositions(address user)
        external
        view
        returns (uint64[] memory validators, uint256[] memory amounts);

    // Events
    event ValidatorAdded(uint64 indexed valId);
    event ValidatorRemoved(uint64 indexed valId);
    event PositionUpdated(address indexed user, uint64 indexed valId, uint256 amount, bool isDelegate);
    event CapChanged(uint64 indexed valId, uint256 newCap);
    event DefaultCapUpdated(uint256 newDefaultBps);
    // Rebalance admin events
    event AdminInitiatedRebalance(uint16 bps);
    event AdminCompletedRebalance(uint256 amountForwarded);
    event AdminCompletedRebalanceWithdrawal(uint64 indexed valId, uint256 amount);

    event ProcessedBatch(uint64 indexed valId, uint8 withdrawalId, uint256 amount);

    // User withdrawal distribution events
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
}
