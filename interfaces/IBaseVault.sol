// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IBaseVault {
    function isWhitelisted(uint64 valId) external view returns (bool);
    function validators(uint256 index) external view returns (uint64);
    function pendingRedelegateByValidator(uint64 valId) external view returns (uint256);
    function totalPendingRedelegation() external view returns (uint256);
    function initiateValidatorRemoval(uint64 valId) external;

    event ValidatorAdded(uint64 indexed valId);
    event ValidatorRemovalInitiated(uint64 indexed valId);
    event ValidatorRemoved(uint64 indexed valId);
    event ValidatorRemovalCompleted(uint64 indexed valId);
}
