// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {MagmaBase} from "./MagmaBase.sol";
import {MagmaRoleManagementModule} from "./MagmaRoleManagementModule.sol";
import {ErrDelegateFailed, ErrUnwrapFailed} from "./MagmaErrorsModule.sol";

abstract contract MagmaERC4626Module is MagmaRoleManagementModule {
    function deposit(uint256 assets, address receiver) public virtual override whenNotPaused returns (uint256) {
        uint256 shares = super.deposit(assets, receiver);
        (bool successUnwrap,) = address(asset()).call(abi.encodeWithSignature("withdraw(uint256)", assets));
        if (!successUnwrap) revert ErrUnwrapFailed();
        _delegatedNativeAssets += assets;
        (bool successDelegate,) = coreVault.call(abi.encodeWithSignature("delegate(uint256)", assets));
        if (!successDelegate) revert ErrDelegateFailed();
        return shares;
    }

    function mint(uint256 shares, address receiver) public virtual override whenNotPaused returns (uint256) {
        uint256 assets = previewMint(shares);
        uint256 minted = super.mint(shares, receiver);
        (bool successUnwrap,) = address(asset()).call(abi.encodeWithSignature("withdraw(uint256)", assets));
        if (!successUnwrap) revert ErrUnwrapFailed();
        _delegatedNativeAssets += assets;
        (bool successDelegate,) = coreVault.call(abi.encodeWithSignature("delegate(uint256)", assets));
        if (!successDelegate) revert ErrDelegateFailed();
        return minted;
    }

    function maxWithdraw(address /*owner*/ ) public view virtual override returns (uint256) {
        return 0;
    }

    function maxRedeem(address /*owner*/ ) public view virtual override returns (uint256) {
        return 0;
    }

    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        return super.previewWithdraw(assets);
    }

    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        return super.previewRedeem(shares);
    }
}
