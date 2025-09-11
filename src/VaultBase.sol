// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMagma} from "../interfaces/IMagma.sol";
import "./MagmaErrorsModule.sol";
import {MagmaDelegationModule} from "./MagmaDelegationModule.sol";
import {DelInfo} from "./MagmaDelegationModule.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";

abstract contract VaultBase is MagmaDelegationModule, IBaseVault {
    mapping(uint64 => bool) public override isWhitelisted;
    uint64[] public override validators;

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

    function _getTotalStakedToValidator(uint64 _valId) internal view returns (uint256) {
        DelInfo memory _delInfo = _getDelegatorInfo(_valId, address(this));
        return _delInfo.stake + _delInfo.delta_stake + _delInfo.next_delta_stake;
    }
}
