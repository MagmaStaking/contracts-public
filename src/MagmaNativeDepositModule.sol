// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MagmaBase} from "./MagmaBase.sol";
import {MagmaRoleManagementModule} from "./MagmaRoleManagementModule.sol";
import {
    ErrZeroNativeAsset,
    ErrCoreVaultNotSet,
    ErrGVaultNotSet,
    ErrDelegateFailed,
    ErrGVDelegateFailed
} from "./MagmaErrorsModule.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IGVault} from "../interfaces/IGVault.sol";

abstract contract MagmaNativeDepositModule is MagmaRoleManagementModule {
    using Math for uint256;

    // TODO: referralId?
    function depositMon(bytes32 referralId) external payable whenNotPaused returns (uint256 shares) {
        // shares = _processNativeDeposit();
        // _delegateToCoreVault(msg.value);
        if (referralId != bytes32(0)) {
            emit Referral(msg.sender, msg.sender, msg.value, shares, referralId);
        }
    }
}
