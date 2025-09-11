// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMagma} from "../interfaces/IMagma.sol";
import "./MagmaErrorsModule.sol";

abstract contract VaultBase {
    IMagma public magma;

    function __VaultBase_init(address _magma) internal {
        magma = IMagma(_magma);
    }

    modifier onlyAdmin() {
        if (msg.sender != magma.admin()) revert ErrNotAdmin();
        _;
    }

    modifier onlyMagma() {
        if (msg.sender != address(magma)) revert ErrNotMagma();
        _;
    }
}
