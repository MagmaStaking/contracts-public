// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Magma} from "../src/Magma.sol";

/// @custom:oz-upgrades-from Magma
// this is outside the scope of audit just used for testing upgradeability
contract MagmaV2 is Magma {
    function version() external pure returns (uint256) {
        return 2;
    }
}
