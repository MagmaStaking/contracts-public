// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {
    ErrZeroAssets,
    ErrDelegateFailed,
    ErrUndelegateFailed,
    ErrCompleteUndelegationFailed
} from "./MagmaErrorsModule.sol";

/**
 * @title MagmaDelegationModule
 * @dev Abstract thin adapter over Monad staking precompile. Inherit in vaults so msg.sender == delegator.
 */
abstract contract MagmaDelegationModule {
    address internal constant STAKING_PRECOMPILE = address(0x0000000000000000000000000000000000000100);
    bytes4 internal constant SEL_DELEGATE = 0x00000002;
    bytes4 internal constant SEL_UNDELEGATE = 0x00000003;
    bytes4 internal constant SEL_COMPOUND = 0x00000004;
    bytes4 internal constant SEL_WITHDRAW = 0x00000005;
    bytes4 internal constant SEL_CLAIM_REWARDS = 0x00000006;
    bytes4 internal constant SEL_GET_WITHDRAW = 0x00000009;
    bytes4 internal constant SEL_GET_DELEGATOR = 0x00000008;

    function _delegate(uint64 valId, uint256 amount) internal {
        if (amount == 0) revert ErrZeroAssets();
        (bool ok,) = STAKING_PRECOMPILE.call(abi.encodeWithSelector(SEL_DELEGATE, valId, amount));
        if (!ok) revert ErrDelegateFailed();
    }

    function _undelegate(uint64 valId, uint256 amount, uint8 withdrawalId) internal {
        if (amount == 0) revert ErrZeroAssets();
        (bool ok,) = STAKING_PRECOMPILE.call(abi.encodeWithSelector(SEL_UNDELEGATE, valId, amount, withdrawalId));
        if (!ok) revert ErrUndelegateFailed();
    }

    function _withdraw(uint64 valId, uint8 withdrawalId) internal {
        (bool ok,) = STAKING_PRECOMPILE.call(abi.encodeWithSelector(SEL_WITHDRAW, valId, withdrawalId));
        if (!ok) revert ErrCompleteUndelegationFailed();
    }

    function _tryWithdraw(uint64 valId, uint8 withdrawalId) internal returns (bool) {
        (bool ok,) = STAKING_PRECOMPILE.call(abi.encodeWithSelector(SEL_WITHDRAW, valId, withdrawalId));
        return ok;
    }

    function _compound(uint64 valId) internal {
        (bool ok,) = STAKING_PRECOMPILE.call(abi.encodeWithSelector(SEL_COMPOUND, valId));
        if (!ok) revert ErrDelegateFailed();
    }

    function _claim(uint64 valId) internal {
        (bool ok,) = STAKING_PRECOMPILE.call(abi.encodeWithSelector(SEL_CLAIM_REWARDS, valId));
        if (!ok) revert ErrDelegateFailed();
    }

    function _getWithdrawalRequest(uint64 valId, address delegator, uint8 withdrawalId)
        internal
        view
        returns (bool exists, uint256 amount, uint256 acc, uint64 epoch)
    {
        (bool ok, bytes memory ret) =
            STAKING_PRECOMPILE.staticcall(abi.encodeWithSelector(SEL_GET_WITHDRAW, valId, delegator, withdrawalId));
        if (!ok || ret.length == 0) return (false, 0, 0, 0);
        (amount, acc, epoch) = abi.decode(ret, (uint256, uint256, uint64));
        exists = (amount != 0);
    }

    // Typed view for delegator info: return stake amount (first word) per docs
    function _getDelegatorStake(uint64 valId, address delegator) internal view returns (uint256 stake) {
        (bool ok, bytes memory ret) =
            STAKING_PRECOMPILE.staticcall(abi.encodeWithSelector(SEL_GET_DELEGATOR, valId, delegator));
        if (!ok || ret.length == 0) return 0;
        (stake) = abi.decode(ret, (uint256));
    }
}
