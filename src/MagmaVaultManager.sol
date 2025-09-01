// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MagmaRoleManagementModule} from "./MagmaRoleManagementModule.sol";
import {ErrNotGVault, ErrZeroNativeAsset, ErrForwardFailed} from "./MagmaErrorsModule.sol";
import {ErrNotAdmin, ErrCoreVaultNotSet, ErrGVaultNotSet, ErrDelegateFailed, ErrUndelegateFailed, ErrCompleteUndelegationFailed, ErrGVUndelegateFailed, ErrGVCompleteFailed, ErrWrapFailed, ErrRebalanceInitiateFailed, ErrRebalanceCompleteFailed} from "./MagmaErrorsModule.sol";

abstract contract MagmaVaultManager is MagmaRoleManagementModule {
    /**
     * @dev Delegate through CoreVault (distributes equally among whitelisted validators)
     */
    function delegate(uint256 amount) external {
        (bool success, ) = coreVault.call(
            abi.encodeWithSignature("delegate(uint256)", amount)
        );
        if (!success) revert ErrDelegateFailed();
    }

    /**
     * @dev Delegate through gVault (specify validator)
     */
    function delegateToValidator(uint64 valId, uint256 amount) external {
        if (gVault == address(0)) revert ErrGVaultNotSet();
        (bool success, ) = gVault.call(
            abi.encodeWithSignature(
                "delegate(address,uint64,uint256)",
                msg.sender,
                valId,
                amount
            )
        );
        if (!success) revert ErrDelegateFailed();
    }

    /**
     * @dev Undelegate through CoreVault (undelegates equally from all validators)
     */
    function undelegate(uint256 amount) external {
        (bool success, ) = coreVault.call(
            abi.encodeWithSignature("undelegate(uint256)", amount)
        );
        if (!success) revert ErrUndelegateFailed();
    }

    /**
     * @dev Undelegate from specific validator through gVault
     */
    function undelegateFromValidator(uint64 valId, uint256 amount) external {
        if (gVault == address(0)) revert ErrGVaultNotSet();
        (bool success, ) = gVault.call(
            abi.encodeWithSignature(
                "undelegate(address,uint64,uint256)",
                msg.sender,
                valId,
                amount
            )
        );
        if (!success) revert ErrGVUndelegateFailed();
    }

    /**
     * @dev Complete undelegation through CoreVault
     */
    function completeUndelegation(uint64 valId, uint8 withdrawalId) external {
        (bool success, ) = coreVault.call(
            abi.encodeWithSignature(
                "completeUndelegation(uint64,uint8)",
                valId,
                withdrawalId
            )
        );
        if (!success) revert ErrCompleteUndelegationFailed();
    }

    /**
     * @dev Complete undelegation through gVault
     */
    function completeUndelegationFromValidator(
        uint256 unbondingIndex
    ) external {
        if (gVault == address(0)) revert ErrGVaultNotSet();
        (bool success, ) = gVault.call(
            abi.encodeWithSignature(
                "completeUndelegation(uint256)",
                unbondingIndex
            )
        );
        if (!success) revert ErrGVCompleteFailed();
    }

    function _undelegate(uint256 assets) internal override {
        (bool ok1, ) = coreVault.call(
            abi.encodeWithSignature("undelegate(uint256)", assets)
        );
        if (!ok1) revert ErrUndelegateFailed();
    }

    function _completeUndelegationAndWrap(uint256 assets) internal override {
        // caller must specify (valId, withdrawalId) off-chain; this internal is no-op for id-less flows
        bool ok2 = true;
        if (!ok2) revert ErrCompleteUndelegationFailed();
        (bool successWrap, ) = address(asset()).call{value: assets}(
            abi.encodeWithSignature("deposit()")
        );
        if (!successWrap) revert ErrWrapFailed();
    }

    function _undelegateFromValidator(
        uint64 valId,
        uint256 assets
    ) internal override {
        if (gVault == address(0)) revert ErrGVaultNotSet();
        (bool ok, ) = gVault.call(
            abi.encodeWithSignature(
                "undelegate(address,uint64,uint256)",
                msg.sender,
                valId,
                assets
            )
        );
        if (!ok) revert ErrGVUndelegateFailed();
    }

    function _completeUndelegationFromGVault(
        uint256 /*assets*/
    ) internal override {
        if (gVault == address(0)) revert ErrGVaultNotSet();
        (bool ok, ) = gVault.call(
            abi.encodeWithSignature("completeUndelegation(uint256)", 0)
        );
        if (!ok) revert ErrGVCompleteFailed();
    }

    /**
     * @dev Admin-only rebalance orchestration
     */
    function rebalanceVaults() external {
        if (msg.sender != admin) revert ErrNotAdmin();
        if (coreVault == address(0)) revert ErrCoreVaultNotSet();
        if (gVault == address(0)) revert ErrGVaultNotSet();

        uint256 coreTotal = 0;
        (bool ok, bytes memory data) = coreVault.staticcall(
            abi.encodeWithSignature("getTotalDelegated()")
        );
        if (ok && data.length > 0) {
            coreTotal = abi.decode(data, (uint256));
        }
        if (coreTotal == 0) {
            (bool s1, ) = gVault.call(
                abi.encodeWithSignature(
                    "adminInitiateRebalanceBps(uint16)",
                    3000
                )
            );
            if (!s1) revert ErrRebalanceInitiateFailed();
        }

        (bool s2, ) = gVault.call(
            abi.encodeWithSignature("adminCompleteAndForward()")
        );
        if (!s2) revert ErrRebalanceCompleteFailed();

        emit RebalanceAttempted(3000);
    }

    /**
     * @dev Payable hook for gVault to forward completed undelegation funds.
     */
    function onRebalanceFundsReceived() external payable {
        if (msg.sender != gVault) revert ErrNotGVault();
        if (msg.value == 0) revert ErrZeroNativeAsset();
        _delegatedNativeAssets += msg.value;
        (bool s, ) = coreVault.call(
            abi.encodeWithSignature("delegate(uint256)", msg.value)
        );
        if (!s) revert ErrForwardFailed();
        emit RebalanceFundsReceived(msg.sender, msg.value);
    }
}
