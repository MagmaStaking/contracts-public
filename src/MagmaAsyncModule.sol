// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MagmaBase} from "./MagmaBase.sol";
import {MagmaRoleManagementModule} from "./MagmaRoleManagementModule.sol";
import {ErrZeroAssets, ErrZeroShares, ErrNotAuthorized, ErrInsufficientShares, ErrInsufficientDelegated, ErrNoPendingWithdrawRequest, ErrNoPendingRedeemRequest, ErrInsufficientClaimableAssets, ErrInsufficientClaimableShares, ErrNotGVaultRequest, ErrZeroAddress, ErrNativeTransferFailed} from "./MagmaErrorsModule.sol";

abstract contract MagmaAsyncModule is MagmaRoleManagementModule {
    using Math for uint256;

    function requestWithdraw(
        uint256 assets,
        address controller,
        address owner
    ) external whenNotPaused returns (uint256 requestId) {
        if (assets == 0) revert ErrZeroAssets();
        if (!(owner == msg.sender || isOperator[owner][msg.sender]))
            revert ErrNotAuthorized();

        uint256 shares = previewWithdraw(assets);
        if (shares > balanceOf(owner))
            revert ErrInsufficientShares(shares, balanceOf(owner));

        delete pendingWithdrawals[controller];

        pendingWithdrawals[controller] = WithdrawalRequest({
            shares: shares,
            assets: assets,
            timestamp: block.timestamp,
            claimableTime: block.timestamp + DEFAULT_DELAY,
            isRedeem: false,
            validator: address(0)
        });

        _transfer(owner, address(this), shares);

        if (_delegatedNativeAssets < assets)
            revert ErrInsufficientDelegated(assets, _delegatedNativeAssets);
        _delegatedNativeAssets -= assets;
        _undelegate(assets);

        emit WithdrawRequest(controller, owner, 0, msg.sender, assets);
        return 0;
    }

    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    ) external whenNotPaused returns (uint256 requestId) {
        if (shares == 0) revert ErrZeroShares();
        if (!(owner == msg.sender || isOperator[owner][msg.sender]))
            revert ErrNotAuthorized();
        if (shares > balanceOf(owner))
            revert ErrInsufficientShares(shares, balanceOf(owner));

        delete pendingWithdrawals[controller];

        uint256 assets = previewRedeem(shares);

        pendingWithdrawals[controller] = WithdrawalRequest({
            shares: shares,
            assets: assets,
            timestamp: block.timestamp,
            claimableTime: block.timestamp + DEFAULT_DELAY,
            isRedeem: true,
            validator: address(0)
        });

        _transfer(owner, address(this), shares);

        if (_delegatedNativeAssets < assets)
            revert ErrInsufficientDelegated(assets, _delegatedNativeAssets);
        _delegatedNativeAssets -= assets;
        _undelegate(assets);

        emit RedeemRequest(controller, owner, 0, msg.sender, shares);
        return 0;
    }

    function requestRedeemFromVault(
        uint256 shares,
        uint64 valId,
        address controller,
        address owner
    ) external whenNotPaused returns (uint256 requestId) {
        if (shares == 0) revert ErrZeroShares();
        if (!(owner == msg.sender || isOperator[owner][msg.sender]))
            revert ErrNotAuthorized();
        if (shares > balanceOf(owner))
            revert ErrInsufficientShares(shares, balanceOf(owner));

        delete pendingWithdrawals[controller];

        uint256 assets = previewRedeem(shares);

        pendingWithdrawals[controller] = WithdrawalRequest({
            shares: shares,
            assets: assets,
            timestamp: block.timestamp,
            claimableTime: block.timestamp + DEFAULT_DELAY,
            isRedeem: true,
            validator: address(0)
        });

        _transfer(owner, address(this), shares);

        if (_delegatedNativeAssets < assets)
            revert ErrInsufficientDelegated(assets, _delegatedNativeAssets);
        _delegatedNativeAssets -= assets;
        _undelegateFromValidator(valId, assets);

        emit RedeemRequest(controller, owner, 0, msg.sender, shares);
        return 0;
    }

    function pendingWithdrawRequest(
        address controller
    ) external view returns (uint256) {
        WithdrawalRequest memory request = pendingWithdrawals[controller];
        if (request.shares == 0 || request.isRedeem) return 0;
        return request.assets;
    }

    function pendingRedeemRequest(
        address controller
    ) external view returns (uint256) {
        WithdrawalRequest memory request = pendingWithdrawals[controller];
        if (request.shares == 0 || !request.isRedeem) return 0;
        return request.shares;
    }

    function claimableWithdrawRequest(
        address controller
    ) external view returns (uint256) {
        WithdrawalRequest memory request = pendingWithdrawals[controller];
        if (request.shares == 0 || request.isRedeem) return 0;

        return
            _getClaimableAmount(
                request.assets,
                request.timestamp,
                request.claimableTime
            );
    }

    function claimableRedeemRequest(
        address controller
    ) external view returns (uint256) {
        WithdrawalRequest memory request = pendingWithdrawals[controller];
        if (request.shares == 0 || !request.isRedeem) return 0;

        uint256 claimableAssets = _getClaimableAmount(
            request.assets,
            request.timestamp,
            request.claimableTime
        );
        if (claimableAssets == 0) return 0;
        return
            claimableAssets.mulDiv(
                request.shares,
                request.assets,
                Math.Rounding.Floor
            );
    }

    function _getClaimableAmount(
        uint256 totalAmount,
        uint256 requestTime,
        uint256 claimableTime
    ) internal view returns (uint256) {
        if (block.timestamp >= claimableTime) {
            return totalAmount;
        }
        if (block.timestamp <= requestTime) {
            return 0;
        }
        uint256 elapsed = block.timestamp - requestTime;
        uint256 duration = claimableTime - requestTime;
        return totalAmount.mulDiv(elapsed, duration, Math.Rounding.Floor);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address controller
    ) public virtual override whenNotPaused returns (uint256) {
        if (!(controller == msg.sender || isOperator[controller][msg.sender]))
            revert ErrNotAuthorized();
        WithdrawalRequest storage request = pendingWithdrawals[controller];
        if (!(request.shares > 0 && !request.isRedeem))
            revert ErrNoPendingWithdrawRequest();
        uint256 claimableAssets = _getClaimableAmount(
            request.assets,
            request.timestamp,
            request.claimableTime
        );
        if (assets > claimableAssets)
            revert ErrInsufficientClaimableAssets(assets, claimableAssets);
        uint256 sharesToBurn = assets.mulDiv(
            request.shares,
            request.assets,
            Math.Rounding.Ceil
        );
        request.assets -= assets;
        request.shares -= sharesToBurn;
        if (request.assets == 0) {
            delete pendingWithdrawals[controller];
        }
        _burn(address(this), sharesToBurn);
        _completeUndelegationAndWrap(assets);
        IERC20(asset()).transfer(receiver, assets);
        emit Withdraw(controller, receiver, controller, assets, sharesToBurn);
        return sharesToBurn;
    }

    function redeem(
        uint256 shares,
        address receiver,
        address controller
    ) public virtual override whenNotPaused returns (uint256) {
        if (!(controller == msg.sender || isOperator[controller][msg.sender]))
            revert ErrNotAuthorized();
        WithdrawalRequest storage request = pendingWithdrawals[controller];
        if (!(request.shares > 0 && request.isRedeem))
            revert ErrNoPendingRedeemRequest();
        uint256 claimableAssets = _getClaimableAmount(
            request.assets,
            request.timestamp,
            request.claimableTime
        );
        uint256 claimableShares = claimableAssets.mulDiv(
            request.shares,
            request.assets,
            Math.Rounding.Floor
        );
        if (shares > claimableShares)
            revert ErrInsufficientClaimableShares(shares, claimableShares);
        uint256 assets = shares.mulDiv(
            request.assets,
            request.shares,
            Math.Rounding.Floor
        );
        request.assets -= assets;
        request.shares -= shares;
        if (request.shares == 0) {
            delete pendingWithdrawals[controller];
        }
        _burn(address(this), shares);
        _completeUndelegationAndWrap(assets);
        IERC20(asset()).transfer(receiver, assets);
        emit Withdraw(controller, receiver, controller, assets, shares);
        return assets;
    }

    function redeemMonFromVault(
        uint256 shares,
        address receiver,
        address controller
    ) external whenNotPaused returns (uint256 assets) {
        if (!(controller == msg.sender || isOperator[controller][msg.sender]))
            revert ErrNotAuthorized();
        if (receiver == address(0)) revert ErrZeroAddress();
        WithdrawalRequest storage request = pendingWithdrawals[controller];
        if (!(request.shares > 0 && request.isRedeem))
            revert ErrNoPendingRedeemRequest();
        if (request.validator == address(0)) revert ErrNotGVaultRequest();
        uint256 claimableAssets = _getClaimableAmount(
            request.assets,
            request.timestamp,
            request.claimableTime
        );
        uint256 claimableShares = claimableAssets.mulDiv(
            request.shares,
            request.assets,
            Math.Rounding.Floor
        );
        if (shares > claimableShares)
            revert ErrInsufficientClaimableShares(shares, claimableShares);
        assets = shares.mulDiv(
            request.assets,
            request.shares,
            Math.Rounding.Floor
        );
        request.assets -= assets;
        request.shares -= shares;
        if (request.shares == 0) {
            delete pendingWithdrawals[controller];
        }
        _burn(address(this), shares);
        _completeUndelegationFromGVault(assets);
        (bool sent, ) = payable(receiver).call{value: assets}("");
        if (!sent) revert ErrNativeTransferFailed();
        emit Withdraw(controller, receiver, controller, assets, shares);
        return assets;
    }

    function redeemMon(
        uint256 shares,
        address receiver,
        address owner
    ) external whenNotPaused returns (uint256 assets) {
        if (shares == 0) revert ErrZeroShares();
        if (receiver == address(0)) revert ErrZeroAddress();
        if (!(owner == msg.sender || allowance(owner, msg.sender) >= shares))
            revert ErrNotAuthorized();

        assets = previewRedeem(shares);
        if (assets == 0) revert ErrZeroAssets();

        if (owner != msg.sender) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);

        address assetAddress = address(asset());
        (bool success, ) = assetAddress.call(
            abi.encodeWithSignature("withdraw(uint256)", assets)
        );
        if (!success) revert ErrNativeTransferFailed();

        (bool sent, ) = payable(receiver).call{value: assets}("");
        if (!sent) revert ErrNativeTransferFailed();

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }
}
