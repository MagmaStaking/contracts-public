// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMagma} from "../interfaces/IMagma.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import "./MagmaErrorsModule.sol";
import {MagmaDelegationModule} from "./MagmaDelegationModule.sol";
import {DelInfo} from "./MagmaDelegationModule.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {BitMapLib} from "./utils/BitMapLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
    mapping(uint64 valId => uint256 amount) public override pendingRedelegateByValidator;
    uint256 public override totalPendingRedelegation;

    // Pending withdrawals totals
    mapping(uint64 valId => uint256 amount) public override pendingUndelegateByValidator;
    uint256 public override totalPendingUndelegations;

    struct WithdrawalRequestInfo {
        uint256 amount;
        uint64 validator;
        uint8 withdrawalId;
    }

    // Storage for withdrawal requests - mapping from user to their withdrawal requests
    mapping(address => WithdrawalRequestInfo[]) public userWithdrawalRequests;

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

    // Function totalAssets to get all the stake, delta stake, next delta stake, and pending redelegations for all validators
    function totalAssets() external view returns (uint256) {
        return _getTotalStakedToAllValidators() + totalPendingRedelegation;
    }

    // Minimum user withdraw amount default amount is missing precision
    function setMinUserWithdrawAmount(uint256 _amount) external onlyAdmin {
        if (_amount >= 10000 ether) revert ErrInvalidAmount(_amount);
        minUserWithdrawAmount = _amount;
    }

    function _chargeWithdrawalFee(uint256 _totalWithdrawalAmount) internal returns (uint256) {
        if (_totalWithdrawalAmount == 0) return 0;
        if (magma.withdrawalFee() == 0) return 0;
        uint256 _fee = Math.mulDiv(_totalWithdrawalAmount, magma.withdrawalFee(), 10_000, Math.Rounding.Ceil);
        if (_fee > 0) {
            (bool okFee,) = magma.feeReceiver().call{value: _fee}("");
            if (!okFee) {
                emit WithdrawalFeeTransferFailed(_fee);
            } else {
                emit WithdrawalFeeTransferSuccess(_fee, magma.feeReceiver());
            }
        }
        return _fee;
    }

    function _completeValidatorRemovalWithdrawal(uint64 _valId) internal returns (uint256) {
        if (validatorStatus[_valId] != ValidatorStatus.UNDELEGATING) revert ErrInvalidStatus();

        // Check bitmap first - if ADMIN_WID is not in use, no pending withdrawal exists
        if (!withdrawalIdBitmaps[_valId].isWithdrawalIdInUse(ADMIN_WID)) {
            revert ErrNoPendingWithdrawRequest();
        }

        // Get the withdrawal amount before completing withdrawal
        (bool _exists, uint256 _withdrawalAmount,,) = _getWithdrawalRequest(_valId, address(this), ADMIN_WID);
        if (!(_exists && _withdrawalAmount > 0)) revert ErrNoPendingWithdrawRequest();

        // Complete the withdrawal using the admin withdrawal ID
        _completeRedelegationWithdrawal(_valId, ADMIN_WID, _withdrawalAmount);

        // Reduce the pending redistribution amount by the amount we just redistributed
        if (totalPendingRedelegation >= _withdrawalAmount) {
            totalPendingRedelegation -= _withdrawalAmount;
        } else {
            totalPendingRedelegation = 0;
        }

        delete validatorStatus[_valId];
        emit ValidatorRemovalCompleted(_valId);

        return _withdrawalAmount;
    }

    /**
     * @notice Step 2: Remove validator from validators array this function forces all stake to be in an active state
     * @dev Remove validator from validators array
     * @param _valId The validator ID to remove
     */
    function _executeValidatorUndelegation(uint64 _valId) internal {
        if (validatorStatus[_valId] != ValidatorStatus.PAUSED) revert ErrInvalidStatus();

        DelInfo memory _coreVaultDelInfo = _getDelegatorInfo(_valId, address(this));

        if (_coreVaultDelInfo.deltaStake > 0 || _coreVaultDelInfo.nextDeltaStake > 0) {
            revert ErrPendingStakeNotZero();
        }

        // Claim rewards for this validator before undelegation
        if (_coreVaultDelInfo.rewards > 0) {
            _claimValidatorRewards(_valId);
        }

        uint256 _amountToRedelegate = _coreVaultDelInfo.stake;

        // Undelegate all from this validator first
        if (_amountToRedelegate > 0) {
            _checkFreeAdminWid(_valId);
            _allocateADMIN_WIDandUndelegate(_valId, _amountToRedelegate);
            validatorStatus[_valId] = ValidatorStatus.UNDELEGATING;
            emit ValidatorRemoved(_valId);
        } else {
            delete validatorStatus[_valId];
            emit ValidatorRemovalCompleted(_valId);
        }
    }

    function _registerValidator(uint64 _valId) internal {
        if (_valId == 0) revert ErrZeroValidatorId();
        if (isWhitelisted[_valId]) revert ErrAlreadyWhitelisted();

        validators.push(_valId);
        isWhitelisted[_valId] = true;

        emit ValidatorAdded(_valId);
    }

    function _initiateValidatorRemoval(uint64 _valId) internal {
        if (!isWhitelisted[_valId]) revert ErrNotWhitelisted();
        validatorStatus[_valId] = ValidatorStatus.PAUSED;
        isWhitelisted[_valId] = false;
        _removeFromArray(validators, _valId);

        uint256 _totalStakedToValidator = _getTotalStakedToValidator(_valId);
        if (_totalStakedToValidator > 0) {
            pendingRedelegateByValidator[_valId] = _totalStakedToValidator;
            totalPendingRedelegation += _totalStakedToValidator;
        }

        emit ValidatorRemovalInitiated(_valId);
    }

    function _getTotalStakedToAllValidators() internal view returns (uint256) {
        uint256 _total = 0;
        for (uint256 _i = 0; _i < validators.length; _i++) {
            _total += _getTotalStakedToValidator(validators[_i]);
        }
        return _total;
    }

    function _allocateWIDandUndelegate(uint64 _valId, uint256 _amount) internal returns (uint8 _wid) {
        _wid = withdrawalIdBitmaps[_valId].allocateWithdrawalId();
        _undelegate(_valId, _amount, _wid);
        return _wid;
    }

    function _allocateADMIN_WIDandUndelegate(uint64 _valId, uint256 _amount) internal returns (uint8 _wid) {
        withdrawalIdBitmaps[_valId].allocateADMIN_WID();
        _undelegate(_valId, _amount, ADMIN_WID);
        return _wid;
    }

    /**
     * @dev Store withdrawal request information for tracking
     * @param _user The user making the withdrawal request
     * @param _amount The amount being withdrawn
     * @param _validator The validator from which to withdraw
     * @param _withdrawalId The withdrawal ID assigned
     */
    function _storeWithdrawalRequest(address _user, uint256 _amount, uint64 _validator, uint8 _withdrawalId) internal {
        userWithdrawalRequests[_user].push(
            WithdrawalRequestInfo({amount: _amount, validator: _validator, withdrawalId: _withdrawalId})
        );
    }

    function _getTotalStakedWithPendingToValidator(uint64 _valId) internal view returns (uint256) {
        DelInfo memory _delInfo = _getDelegatorInfo(_valId, address(this));
        return _delInfo.stake + _delInfo.deltaStake + _delInfo.nextDeltaStake + pendingRedelegateByValidator[_valId];
    }

    function _getTotalStakedToValidator(uint64 _valId) internal view returns (uint256) {
        DelInfo memory _delInfo = _getDelegatorInfo(_valId, address(this));
        return _delInfo.stake + _delInfo.deltaStake + _delInfo.nextDeltaStake;
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

    function _completeUserWithdrawal(address _user)
        internal
        returns (uint256 _totalWithdrawn, uint256 _totalWithdrawnAfterFee)
    {
        WithdrawalRequestInfo[] storage _userRequests = userWithdrawalRequests[_user];
        if (_userRequests.length == 0) revert ErrNoPendingWithdrawRequest();

        _totalWithdrawn = 0;
        _totalWithdrawnAfterFee = 0;
        uint256 _totalSuccessfulWithdrawals = 0;

        // Process each withdrawal request for this user
        for (uint256 i = 0; i < _userRequests.length; i++) {
            WithdrawalRequestInfo storage _request = _userRequests[i];
            uint64 _valId = _request.validator;
            uint8 _withdrawalId = _request.withdrawalId;

            // Check if withdrawal is ready
            (bool _exists, uint256 _availableAmount,,) = _getWithdrawalRequest(_valId, address(this), _withdrawalId);
            if (!(_exists && _availableAmount > 0)) {
                // Withdrawal not ready yet, skip this request
                emit WithdrawalNotReady(_valId, _withdrawalId, _user, _availableAmount);
                continue;
            }

            // Attempt to withdraw from precompile
            _withdraw(_valId, _withdrawalId);
            _totalSuccessfulWithdrawals += _availableAmount;
            emit WithdrawalPaymentSuccess(_valId, _withdrawalId, _user, _availableAmount);

            // Update pending undelegation tracking
            if (pendingUndelegateByValidator[_valId] >= _availableAmount) {
                pendingUndelegateByValidator[_valId] -= _availableAmount;
            } else {
                pendingUndelegateByValidator[_valId] = 0;
            }

            totalPendingUndelegations =
                (_availableAmount > totalPendingUndelegations) ? 0 : (totalPendingUndelegations - _availableAmount);

            // Mark withdrawal ID as completed
            _markWithdrawalCompleted(_valId, _withdrawalId);
        }

        // Send all accumulated ETH to user in a single transaction
        if (_totalSuccessfulWithdrawals > 0) {
            uint256 _fee = _chargeWithdrawalFee(_totalSuccessfulWithdrawals);
            uint256 _remaining = _totalSuccessfulWithdrawals - _fee;
            (bool success,) = address(magma).call{value: _remaining}("");
            if (!success) {
                revert ErrNativeTransferFailed();
            }
            _totalWithdrawn = _totalSuccessfulWithdrawals;
            _totalWithdrawnAfterFee = _remaining;
        }

        // Clear all withdrawal requests for this user after processing
        delete userWithdrawalRequests[_user];

        emit UserWithdrawalCompleted(_user, _totalWithdrawnAfterFee);
    }

    function _completeRedelegationWithdrawal(uint64 _valId, uint8 _withdrawalId, uint256 _amt) internal {
        _withdraw(_valId, _withdrawalId);
        // Mark the withdrawal as completed in the bitmap
        _markWithdrawalCompleted(_valId, _withdrawalId);

        if (pendingRedelegateByValidator[_valId] >= _amt) {
            pendingRedelegateByValidator[_valId] -= _amt;
        } else {
            pendingRedelegateByValidator[_valId] = 0;
        }
    }

    /**
     * @dev Mark a withdrawal ID as free in the bitmap when withdrawal is completed
     * @param _valId The validator ID
     * @param _withdrawalId The withdrawal ID to mark as free
     */
    function _markWithdrawalCompleted(uint64 _valId, uint8 _withdrawalId) internal {
        withdrawalIdBitmaps[_valId].markWithdrawalCompleted(_withdrawalId);
    }

    function _checkFreeAdminWid(uint64 _valId) internal view {
        if (withdrawalIdBitmaps[_valId].isWithdrawalIdInUse(ADMIN_WID)) revert AdminWidInUse();
    }

    /**
     * @dev Claim rewards for a specific validator and send to CoreVault for distribution
     * @param _valId The validator ID to claim rewards for
     */
    function _claimValidatorRewards(uint64 _valId) internal {
        uint256 _balanceBefore = address(this).balance;

        // Try to claim rewards from the validator - if there are no rewards, this will fail gracefully
        _claim(_valId);

        uint256 _balanceAfter = address(this).balance;
        uint256 _rewardsClaimed = _balanceAfter - _balanceBefore;

        if (_rewardsClaimed > 0) {
            // Calculate and send fee to fee receiver
            uint256 _fee = _calculateRewardsFeeAndSend(_rewardsClaimed);

            uint256 _remaining = _rewardsClaimed - _fee;

            // Send remaining rewards to CoreVault for distribution
            if (_remaining > 0) {
                ICoreVault _coreVault = ICoreVault(magma.coreVault());
                // Call delegate function on CoreVault to distribute to remaining validators
                _coreVault.delegate{value: _remaining}();
            }
        }
    }

    function _calculateRewardsFeeAndSend(uint256 _totalRewards) internal returns (uint256 _fee) {
        _fee = Math.mulDiv(_totalRewards, magma.rewardsFee(), 10_000, Math.Rounding.Ceil);
        if (_fee > 0) {
            // send fee to fee receiver
            (bool _ok,) = magma.feeReceiver().call{value: _fee}("");
            if (!_ok) {
                emit RewardsFeeTransferFailed(_fee);
            } else {
                emit RewardsFeeTransferSuccess(_fee, magma.feeReceiver());
            }
        }
        return _fee;
    }
}
