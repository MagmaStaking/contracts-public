// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MagmaRoleManagementModule} from "./MagmaRoleManagementModule.sol";
import {ErrNotGVault, ErrZeroNativeAsset, ErrForwardFailed} from "./MagmaErrorsModule.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IGVault} from "../interfaces/IGVault.sol";
import {
    ErrNotAdmin,
    ErrCoreVaultNotSet,
    ErrGVaultNotSet,
    ErrDelegateFailed,
    ErrUndelegateFailed,
    ErrCompleteUndelegationFailed,
    ErrGVUndelegateFailed,
    ErrGVCompleteFailed,
    ErrWrapFailed,
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
     * @dev Delegate through gVault (specify validator)
     */
    function delegateToValidator(uint64 valId, uint256 amount) external {
        if (address(gVault) == address(0)) revert ErrGVaultNotSet();
        gVault.delegate{value: amount}(msg.sender, valId);
    }

    /**
     * @dev Undelegate through CoreVault (undelegates equally from all validators)
     */
    function undelegate(uint256 amount) external {
        coreVault.undelegate(amount, msg.sender);
    }

    /**
     * @dev Undelegate from specific validator through gVault
     */
    function undelegateFromValidator(uint64 valId, uint256 amount) external {
        if (address(gVault) == address(0)) revert ErrGVaultNotSet();
        gVault.undelegate(msg.sender, valId, amount);
    }

    /**
     * @dev Complete undelegation through CoreVault for a specific user
     * @param user The user whose withdrawal requests to complete
     * @return totalWithdrawn The actual amount successfully withdrawn and sent to the user
     */
    function completeUndelegation(address user) external returns (uint256 totalWithdrawn) {
        return coreVault.completeUserWithdrawal(user);
    }

    /**
     * @dev Complete undelegation through gVault
     */
    function completeUndelegationFromValidator(uint64 valId, uint8 wid) external {
        if (address(gVault) == address(0)) revert ErrGVaultNotSet();
        gVault.completeWithdrawalForValidator(valId, wid);
    }

    function _undelegate(uint256 assets) internal override {
        coreVault.undelegate(assets, msg.sender);
    }

    function _completeUndelegationAndWrap(uint256 assets) internal override {
        // caller must specify (valId, withdrawalId) off-chain; this internal is no-op for id-less flows
        bool ok2 = true;
        if (!ok2) revert ErrCompleteUndelegationFailed();
        (bool successWrap,) = address(asset()).call{value: assets}(abi.encodeWithSignature("deposit()"));
        if (!successWrap) revert ErrWrapFailed();
    }

    function _undelegateFromValidator(uint64 valId, uint256 assets) internal override {
        if (address(gVault) == address(0)) revert ErrGVaultNotSet();
        gVault.undelegate(msg.sender, valId, assets);
    }

    function _completeUndelegationFromGVault(uint256 /*assets*/ ) internal override {
        if (address(gVault) == address(0)) revert ErrGVaultNotSet();
        // Note: This function signature doesn't match any function in IGVault interface
        // It might need to be updated to call a specific validator withdrawal completion
        revert("_completeUndelegationFromGVault: interface mismatch - needs specific valId and wid");
    }

    /**
     * @dev Admin-only rebalance orchestration
     */
    function rebalanceVaults() external {
        if (msg.sender != admin) revert ErrNotAdmin();
        if (address(coreVault) == address(0)) revert ErrCoreVaultNotSet();
        if (address(gVault) == address(0)) revert ErrGVaultNotSet();

        uint256 coreTotal = coreVault.getTotalDelegated();

        if (coreTotal == 0) {
            gVault.adminInitiateRebalanceBps(3000);
        }

        gVault.adminCompleteRebalance();

        emit RebalanceAttempted(3000);
    }

    /**
     * @dev Payable hook for gVault to forward completed undelegation funds.
     */
    function onRebalanceFundsReceived() external payable {
        if (msg.sender != address(gVault)) revert ErrNotGVault();
        if (msg.value == 0) revert ErrZeroNativeAsset();
        _delegatedNativeAssets += msg.value;
        coreVault.delegate{value: msg.value}();
        emit RebalanceFundsReceived(msg.sender, msg.value);
    }
}
