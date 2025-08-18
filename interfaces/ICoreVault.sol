// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface ICoreVault {
    // Events
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event Rebalanced();

    // Admin functions
    function addValidator(address validator) external;
    function removeValidator(address validator) external;
    function rebalance() external;

    // Delegation functions (onlyMagma)
    function delegate(uint256 amount) external;
    function undelegate(uint256 amount) external;
    function completeUndelegation(uint256 unbondingIndex) external;

    // View functions
    function validators(uint256 index) external view returns (address);
    function isWhitelisted(address validator) external view returns (bool);
    function delegatedAmount(address validator) external view returns (uint256);
    function getValidators() external view returns (address[] memory);
    function getValidatorCount() external view returns (uint256);
    function getTotalDelegated() external view returns (uint256);
    function magma() external view returns (address);
    function magmaDelegation() external view returns (address);
}
