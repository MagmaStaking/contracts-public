// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MagmaAsyncModule} from "./MagmaAsyncModule.sol";
import {MagmaVaultManager} from "./MagmaVaultManager.sol";
import {MagmaRoleManagementModule} from "./MagmaRoleManagementModule.sol";
import {MagmaBase} from "./MagmaBase.sol";
import {ErrNotAdmin} from "./MagmaErrorsModule.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IGVault} from "../interfaces/IGVault.sol";

contract Magma is Initializable, UUPSUpgradeable, MagmaAsyncModule, MagmaVaultManager {
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

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != admin) revert ErrNotAdmin();
    }

    function deposit(uint256 assets, address receiver)
        public
        override(MagmaAsyncModule, ERC4626Upgradeable)
        returns (uint256)
    {
        return MagmaAsyncModule.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override(MagmaAsyncModule, ERC4626Upgradeable)
        returns (uint256)
    {
        return MagmaAsyncModule.mint(shares, receiver);
    }

    /// @dev previewWithdraw MUST revert for all callers and inputs: https://eips.ethereum.org/EIPS/eip-7540#request-flows
    function previewWithdraw(uint256 /*assets*/ ) public view override returns (uint256) {
        revert();
    }

    /// @dev previewRedeem MUST revert for all callers and inputs: https://eips.ethereum.org/EIPS/eip-7540#request-flows
    function previewRedeem(uint256 /*shares*/ ) public view override returns (uint256) {
        revert();
    }

    /**
     * @dev The redeem and withdraw methods do not transfer shares to the Vault, this happens in a two step process via
     * _requestRedeem and claimRequest.
     */
    function withdraw(uint256, /*assets*/ address, /*receiver*/ address /*controller*/ )
        public
        override
        returns (uint256)
    {
        revert();
    }

    /**
     * @dev The redeem and withdraw methods do not transfer shares to the Vault, this happens in a two step process via
     * _requestRedeem and claimRequest.
     */
    function redeem(uint256, /*shares*/ address, /*receiver*/ address /*controller*/ )
        public
        override
        returns (uint256)
    {
        revert();
    }

    function totalAssets() public view override(MagmaAsyncModule, ERC4626Upgradeable) returns (uint256) {
        return MagmaAsyncModule.totalAssets();
    }
}
