// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MagmaBase} from "./MagmaBase.sol";
import {MagmaRoleManagementModule} from "./MagmaRoleManagementModule.sol";
import {ErrZeroNativeAsset, ErrCoreVaultNotSet, ErrGVaultNotSet, ErrDelegateFailed, ErrGVDelegateFailed} from "./MagmaErrorsModule.sol";

abstract contract MagmaNativeDepositModule is MagmaRoleManagementModule {
    using Math for uint256;

    function depositMon()
        external
        payable
        whenNotPaused
        returns (uint256 shares)
    {
        if (msg.value == 0) revert ErrZeroNativeAsset();
        uint256 assets = msg.value;
        uint256 supply = totalSupply();
        uint256 totalAssetsBefore = totalAssets();
        shares = (supply == 0)
            ? assets
            : assets.mulDiv(supply, totalAssetsBefore, Math.Rounding.Floor);
        _mint(msg.sender, shares);
        _delegatedNativeAssets += assets;
        (bool success, ) = coreVault.call(
            abi.encodeWithSignature("delegate(uint256)", assets)
        );
        if (!success) revert ErrDelegateFailed();
        emit Deposit(msg.sender, msg.sender, assets, shares);
    }

    function depositMon(
        bytes32 referralId
    ) external payable whenNotPaused returns (uint256 shares) {
        if (msg.value == 0) revert ErrZeroNativeAsset();
        uint256 assets = msg.value;
        uint256 supply = totalSupply();
        uint256 totalAssetsBefore = totalAssets();
        shares = (supply == 0)
            ? assets
            : assets.mulDiv(supply, totalAssetsBefore, Math.Rounding.Floor);
        _mint(msg.sender, shares);
        _delegatedNativeAssets += assets;
        (bool success2, ) = coreVault.call(
            abi.encodeWithSignature("delegate(uint256)", assets)
        );
        if (!success2) revert ErrDelegateFailed();
        if (referralId != bytes32(0)) {
            emit Referral(msg.sender, msg.sender, assets, shares, referralId);
        }
    }

    function depositMonToVault(
        uint64 valId
    ) external payable whenNotPaused returns (uint256 shares) {
        if (msg.value == 0) revert ErrZeroNativeAsset();
        if (gVault == address(0)) revert ErrGVaultNotSet();
        uint256 assets = msg.value;
        uint256 supply = totalSupply();
        uint256 totalAssetsBefore = totalAssets();
        shares = (supply == 0)
            ? assets
            : assets.mulDiv(supply, totalAssetsBefore, Math.Rounding.Floor);
        _mint(msg.sender, shares);
        _delegatedNativeAssets += assets;
        (bool ok, ) = gVault.call(
            abi.encodeWithSignature("delegate(uint64,uint256)", valId, assets)
        );
        if (!ok) revert ErrGVDelegateFailed();
        emit Deposit(msg.sender, msg.sender, assets, shares);
    }
}
