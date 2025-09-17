// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MagmaRoleManagementModule} from "./MagmaRoleManagementModule.sol";
import {ErrNotGVault, ErrZeroNativeAsset, ErrForwardFailed} from "./MagmaErrorsModule.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IGVault} from "../interfaces/IGVault.sol";
import {
    ErrNotAdmin,
    ErrDelegateFailed,
    ErrUndelegateFailed,
    ErrCompleteUndelegationFailed,
    ErrGVUndelegateFailed,
    ErrGVCompleteFailed,
    ErrRebalanceInitiateFailed,
    ErrRebalanceCompleteFailed
} from "./MagmaErrorsModule.sol";

abstract contract MagmaVaultManager is MagmaRoleManagementModule {
    /**
     * @dev Delegate through CoreVault (distributes equally among whitelisted validators)
     */
    function delegate(uint256 amount) external {
        coreVault.delegate{value: amount}();
    }

    /**
     * @dev Undelegate through CoreVault (undelegates equally from all validators)
     */
    function undelegate(uint256 amount) external {
        coreVault.undelegate(amount, msg.sender);
    }
}
