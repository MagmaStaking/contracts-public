// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMagma} from "../interfaces/IMagma.sol";
import "./MagmaErrorsModule.sol";
import {MagmaDelegationModule} from "./MagmaDelegationModule.sol";
import {DelInfo} from "./MagmaDelegationModule.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {BitMapLib} from "./utils/BitMapLib.sol";

abstract contract VaultBase is MagmaDelegationModule, IBaseVault {
    using BitMapLib for BitMapLib.WithdrawalBitMap;

    // Per-validator withdrawal ID bitmap management
    mapping(uint64 => BitMapLib.WithdrawalBitMap) internal withdrawalIdBitmaps;

    uint8 internal constant ADMIN_WID = 255;
    uint256 public minUserWithdrawAmount;

    mapping(uint64 => bool) public override isWhitelisted;
    uint64[] public override validators;

    mapping(uint64 => ValidatorStatus) public override validatorStatus;

    // Pending redelegations totals
    mapping(uint64 => uint256) public override pendingRedelegateByValidator;
    uint256 public override totalPendingRedelegation;

    IMagma public magma;

    function __VaultBase_init(address _magma) internal {
        magma = IMagma(_magma);
    }

    modifier onlyAdmin() {
        if (msg.sender != magma.admin()) revert ErrNotAdmin();
        _;
    }

    modifier onlyMagma() {
        if (msg.sender != address(magma)) revert ErrNotMagma();
        _;
    }

    // Minimum user withdraw amount default amount is missing precision
    function setMinUserWithdrawAmount(uint256 amount) external onlyAdmin {
        if (amount >= 10000 ether) revert ErrInvalidAmount(amount);
        minUserWithdrawAmount = amount;
    }

    function _getTotalStakedToValidator(uint64 _valId) internal view returns (uint256) {
        DelInfo memory _delInfo = _getDelegatorInfo(_valId, address(this));
        return _delInfo.stake + _delInfo.delta_stake + _delInfo.next_delta_stake;
    }

    function _removeFromArray(uint64[] storage array, uint64 valId) internal {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == valId) {
                array[i] = array[array.length - 1];
                array.pop();
                break;
            }
        }
    }

    function _completeRedelegationWithdrawal(uint64 _valId, uint8 _withdrawalId, uint256 _amt) internal {
        if (_tryWithdraw(_valId, _withdrawalId)) {
            // Mark the withdrawal as completed in the bitmap
            _markWithdrawalCompleted(_valId, _withdrawalId);

            if (pendingRedelegateByValidator[_valId] >= _amt) {
                pendingRedelegateByValidator[_valId] -= _amt;
            } else {
                pendingRedelegateByValidator[_valId] = 0;
            }
        } else {
            emit WithdrawalFailed(_valId, _withdrawalId);
        }
    }

    /**
     * @dev Mark a withdrawal ID as free in the bitmap when withdrawal is completed
     * @param valId The validator ID
     * @param withdrawalId The withdrawal ID to mark as free
     */
    function _markWithdrawalCompleted(uint64 valId, uint8 withdrawalId) internal {
        withdrawalIdBitmaps[valId].markWithdrawalCompleted(withdrawalId);
    }
}
