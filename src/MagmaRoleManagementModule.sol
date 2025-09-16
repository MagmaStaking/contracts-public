// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {MagmaBase} from "./MagmaBase.sol";
import {ErrNotAdmin, ErrZeroAddress} from "./MagmaErrorsModule.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IGVault} from "../interfaces/IGVault.sol";

abstract contract MagmaRoleManagementModule is MagmaBase {
    function setAdmin(address newAdmin) external {
        if (msg.sender != admin) revert ErrNotAdmin();
        if (newAdmin == address(0)) revert ErrZeroAddress();
        admin = newAdmin;
    }

    function setVaults(address _coreVault, address _gVault) external {
        if (msg.sender != admin) revert ErrNotAdmin();
        if (_coreVault == address(0)) revert ErrZeroAddress();
        coreVault = ICoreVault(_coreVault);
        gVault = IGVault(_gVault);
    }

    function setRewardsFee(uint256 _rewardsFee) external {
        if (msg.sender != admin) revert ErrNotAdmin();
        rewardsFee = _rewardsFee;
    }

    function setRewardsFeeReceiver(address _rewardsFeeReceiver) external {
        if (msg.sender != admin) revert ErrNotAdmin();
        rewardsFeeReceiver = _rewardsFeeReceiver;
    }
}
