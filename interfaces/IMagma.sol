// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IMagma {
    // Admin functions
    function setAdmin(address newAdmin) external;
    function setVaults(address _coreVault, address _gVault) external;
    function pause() external;
    function unpause() external;

    // Rewards functions
    function rewardsFee() external view returns (uint256);
    function withdrawalFee() external view returns (uint256);
    function feeReceiver() external view returns (address);

    // Total assets functions
    function totalAssets() external view returns (uint256);
    function refreshCache() external;

    function admin() external view returns (address);
    function coreVault() external view returns (address);
    function gVault() external view returns (address);
    function paused() external view returns (bool);
}
