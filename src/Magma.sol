// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MagmaNativeDepositModule} from "./MagmaNativeDepositModule.sol";
import {MagmaERC4626Module} from "./MagmaERC4626Module.sol";
import {MagmaAsyncModule} from "./MagmaAsyncModule.sol";
import {MagmaVaultManager} from "./MagmaVaultManager.sol";
import {MagmaRoleManagementModule} from "./MagmaRoleManagementModule.sol";
import {MagmaBase} from "./MagmaBase.sol";
import {ErrNotAdmin} from "./MagmaErrorsModule.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IGVault} from "../interfaces/IGVault.sol";

contract Magma is
    Initializable,
    UUPSUpgradeable,
    MagmaNativeDepositModule,
    MagmaERC4626Module,
    MagmaAsyncModule,
    MagmaVaultManager
{
    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address admin_,
        address coreVault_,
        address gVault_
    ) external initializer {
        __MagmaBase_init(asset_, name_, symbol_, admin_);
        coreVault = ICoreVault(coreVault_);
        gVault = IGVault(gVault_);
    }

    function _authorizeUpgrade(address) internal override {
        if (msg.sender != admin) revert ErrNotAdmin();
    }
    // Resolve function collisions from multiple inheritance

    function deposit(uint256 assets, address receiver)
        public
        virtual
        override(MagmaERC4626Module, ERC4626Upgradeable)
        returns (uint256)
    {
        return MagmaERC4626Module.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        virtual
        override(MagmaERC4626Module, ERC4626Upgradeable)
        returns (uint256)
    {
        return MagmaERC4626Module.mint(shares, receiver);
    }

    function maxWithdraw(address owner)
        public
        view
        virtual
        override(MagmaERC4626Module, ERC4626Upgradeable)
        returns (uint256)
    {
        return MagmaERC4626Module.maxWithdraw(owner);
    }

    function maxRedeem(address owner)
        public
        view
        virtual
        override(MagmaERC4626Module, ERC4626Upgradeable)
        returns (uint256)
    {
        return MagmaERC4626Module.maxRedeem(owner);
    }

    function previewWithdraw(uint256 assets)
        public
        view
        virtual
        override(MagmaERC4626Module, ERC4626Upgradeable)
        returns (uint256)
    {
        return MagmaERC4626Module.previewWithdraw(assets);
    }

    function previewRedeem(uint256 shares)
        public
        view
        virtual
        override(MagmaERC4626Module, ERC4626Upgradeable)
        returns (uint256)
    {
        return MagmaERC4626Module.previewRedeem(shares);
    }

    function withdraw(uint256 assets, address receiver, address controller)
        public
        virtual
        override(MagmaAsyncModule, ERC4626Upgradeable)
        returns (uint256)
    {
        return MagmaAsyncModule.withdraw(assets, receiver, controller);
    }

    function redeem(uint256 shares, address receiver, address controller)
        public
        virtual
        override(MagmaAsyncModule, ERC4626Upgradeable)
        returns (uint256)
    {
        return MagmaAsyncModule.redeem(shares, receiver, controller);
    }
}
