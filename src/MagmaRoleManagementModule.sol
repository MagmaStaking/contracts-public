// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {MagmaBase} from "./MagmaBase.sol";
import {ErrNotAdmin, ErrAlreadyPaused, ErrNotPaused, ErrZeroAddress, ErrPaused} from "./MagmaErrorsModule.sol";

abstract contract MagmaRoleManagementModule is MagmaBase {
    modifier whenNotPaused() {
        if (paused) revert ErrPaused();
        _;
    }

    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function setAdmin(address newAdmin) external {
        if (msg.sender != admin) revert ErrNotAdmin();
        if (newAdmin == address(0)) revert ErrZeroAddress();
        admin = newAdmin;
    }

    function pause() external {
        if (msg.sender != admin) revert ErrNotAdmin();
        if (paused) revert ErrAlreadyPaused();
        paused = true;
        emit Paused(admin);
    }

    function unpause() external {
        if (msg.sender != admin) revert ErrNotAdmin();
        if (!paused) revert ErrNotPaused();
        paused = false;
        emit Unpaused(admin);
    }

    function setVaults(address _coreVault, address _gVault) external {
        if (msg.sender != admin) revert ErrNotAdmin();
        if (_coreVault == address(0)) revert ErrZeroAddress();
        coreVault = _coreVault;
        gVault = _gVault;
    }
}
