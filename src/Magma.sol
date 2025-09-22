// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MagmaAsyncModule} from "./MagmaAsyncModule.sol";
import {MagmaRoleManagementModule} from "./MagmaRoleManagementModule.sol";
import {MagmaBase} from "./MagmaBase.sol";
import {ErrNotAdmin} from "./MagmaErrorsModule.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IGVault} from "../interfaces/IGVault.sol";

contract Magma is Initializable, UUPSUpgradeable, MagmaAsyncModule {
    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address admin_,
        address coreVault_,
        address gVault_,
        uint256 rewardsFee_,
        uint256 withdrawalFee_,
        address feeReceiver_
    ) external initializer {
        __MagmaBase_init(asset_, name_, symbol_, admin_, rewardsFee_, withdrawalFee_, feeReceiver_);

        coreVault = ICoreVault(coreVault_);
        gVault = IGVault(gVault_);
    }

    //TODO: refactor if (msg.sender != admin) revert ErrNotAdmin();
    function pause() external {
        if (msg.sender != admin) revert ErrNotAdmin();
        _pause();
    }

    function unpause() external {
        if (msg.sender != admin) revert ErrNotAdmin();
        _unpause();
    }

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != admin) revert ErrNotAdmin();
    }
}
