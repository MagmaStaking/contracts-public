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
    function delegateToValidator(uint64 valId, uint256 amount) external;
    function undelegate(uint256 amount) external;
    function undelegateFromValidator(uint64 valId, uint256 amount) external;
    function completeUndelegation(uint64 valId, uint8 withdrawalId) external;
    function completeUndelegationFromValidator(uint256 unbondingIndex) external;

    // Admin rebalance orchestration
    function rebalanceVaults() external;
    // Payable hook used by gVault to forward funds
    function onRebalanceFundsReceived() external payable;

    // Rewards functions
    function rewardsFee() external view returns (uint256);
    function rewardsFeeReceiver() external view returns (address);
}
