// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IMagma {
    function admin() external view returns (address);
    function coreVault() external view returns (address);
    function gVault() external view returns (address);
    function paused() external view returns (bool);

    // Admin functions
    function setAdmin(address newAdmin) external;
    function setVaults(address _coreVault, address _gVault) external;
    function pause() external;
    function unpause() external;

    // Delegation functions
    function delegate(uint256 amount) external;
    function delegateToValidator(address validator, uint256 amount) external;
    function undelegate(uint256 amount) external;
    function undelegateFromValidator(
        address validator,
        uint256 amount
    ) external;
    function completeUndelegation(uint256 unbondingIndex) external;
    function completeUndelegationFromValidator(uint256 unbondingIndex) external;
}
