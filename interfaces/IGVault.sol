// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IGVault {
    // Delegation functions (onlyMagma)
    function delegate(address validator, uint256 amount) external;
    function undelegate(address validator, uint256 amount) external;
    function completeUndelegation(uint256 unbondingIndex) external;

    // View functions
    function magma() external view returns (address);
    function magmaDelegation() external view returns (address);
}
