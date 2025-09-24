// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IMagma {
    // Functions used by gVault and VaultBase
    function admin() external view returns (address);
    function coreVault() external view returns (address);
    function feeReceiver() external view returns (address);
    function gVault() external view returns (address);
    function rewardsFee() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function withdrawalFee() external view returns (uint256);
}
