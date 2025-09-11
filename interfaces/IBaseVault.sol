// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IBaseVault {
    function isWhitelisted(uint64 valId) external view returns (bool);
    function validators(uint256 index) external view returns (uint64);
}
