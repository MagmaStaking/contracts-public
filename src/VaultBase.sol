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
    uint256 internal constant BASE_BPS = 10_000;
    uint256 public minUserWithdrawAmount;

    mapping(uint64 => bool) public override isWhitelisted;
    uint64[] public override validators;

    mapping(uint64 => ValidatorStatus) public override validatorStatus;

    // Pending redelegations totals for each validator (we can only use this once for an ADMIN_WID process)
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

    /**
     * @notice Initialize the VaultBase contract with Magma protocol reference
     * @dev Sets the Magma protocol contract address for vault operations
     * @param _magma The address of the Magma protocol contract
     */
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

    /**
     * @notice Get total assets under management including pending operations
     * @dev Calculates total stake across all validators plus pending redelegations
     * @return Total assets in wei (active stake + pending redelegation amounts)
     */
    function totalAssets() external view returns (uint256) {
        return _getTotalStakedToAllValidators() + totalPendingRedelegation;
    }

    /**
     * @notice Set the minimum withdrawal amount for users
     * @dev Updates the minimum amount users can withdraw in a single transaction
     * @param _amount The minimum withdrawal amount in wei (must be less than 10,000 ether)
     */
    function setMinUserWithdrawAmount(uint256 _amount) external onlyAdmin {
        if (_amount >= 10000 ether) revert ErrInvalidAmount(_amount);
        minUserWithdrawAmount = _amount;
    }

    /**
     * @notice Calculate and charge withdrawal fees
     * @dev Calculates withdrawal fee based on protocol fee rate and sends it to fee receiver
     * @param _totalWithdrawalAmount The total amount being withdrawn
     * @return The fee amount charged
     */
    function _chargeWithdrawalFee(uint256 _totalWithdrawalAmount) internal returns (uint256) {
        if (_totalWithdrawalAmount == 0) return 0;
        if (magma.withdrawalFee() == 0) return 0;
        uint256 _fee = Math.mulDiv(_totalWithdrawalAmount, magma.withdrawalFee(), BASE_BPS, Math.Rounding.Ceil);
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

    /**
     * @notice Complete withdrawal process for a removed validator
     * @dev Finalizes validator removal by completing pending withdrawal and updating state
     * @param _valId The validator ID being removed
     * @return The amount withdrawn from the validator
     */
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
        totalPendingRedelegation -= pendingRedelegateByValidator[_valId];
        _completeRedelegationWithdrawal(_valId, ADMIN_WID);

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

    /**
     * @notice Register a new validator in the vault
     * @dev Adds validator to the active validators list and marks as whitelisted
     * @param _valId The validator ID to register
     */
    function _registerValidator(uint64 _valId) internal {
        if (_valId == 0) revert ErrZeroValidatorId();
        if (isWhitelisted[_valId]) revert ErrAlreadyWhitelisted();

        validators.push(_valId);
        isWhitelisted[_valId] = true;

        emit ValidatorAdded(_valId);
    }

    /**
     * @notice Initiate the removal process for a validator
     * @dev Pauses validator, removes from active list, and tracks pending redelegation
     * @param _valId The validator ID to remove
     */
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

    /**
     * @notice Get total stake delegated to all validators
     * @dev Calculates sum of stakes across all active validators
     * @return Total staked amount in wei
     */
    function _getTotalStakedToAllValidators() internal view returns (uint256) {
        uint256 _total = 0;
        for (uint256 _i = 0; _i < validators.length; _i++) {
            _total += _getTotalStakedToValidator(validators[_i]);
        }
        return _total;
    }

    /**
     * @notice Allocate withdrawal ID and initiate undelegation
     * @dev Allocates a free withdrawal ID and starts undelegation process
     * @param _valId The validator ID to undelegate from
     * @param _amount The amount to undelegate
     * @return _wid The allocated withdrawal ID
     */
    function _allocateWIDandUndelegate(uint64 _valId, uint256 _amount) internal returns (uint8 _wid) {
        _wid = withdrawalIdBitmaps[_valId].allocateWithdrawalId();
        _undelegate(_valId, _amount, _wid);
        return _wid;
    }

    /**
     * @notice Allocate admin withdrawal ID and initiate undelegation
     * @dev Uses reserved admin withdrawal ID (255) for administrative operations
     * @param _valId The validator ID to undelegate from
     * @param _amount The amount to undelegate
     * @return _wid The admin withdrawal ID (always 255)
     */
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

    /**
     * @notice Get total stake for validator including pending operations
     * @dev Returns active stake plus pending stakes plus pending redelegation amounts
     * @param _valId The validator ID to query
     * @return Total stake including all pending operations
     */
    function _getTotalStakedWithPendingToValidator(uint64 _valId) internal view returns (uint256) {
        DelInfo memory _delInfo = _getDelegatorInfo(_valId, address(this));
        return _delInfo.stake + _delInfo.deltaStake + _delInfo.nextDeltaStake + pendingRedelegateByValidator[_valId];
    }

    /**
     * @notice Get total active stake for a validator
     * @dev Returns current active stake plus pending stake changes
     * @param _valId The validator ID to query
     * @return Total active stake amount
     */
    function _getTotalStakedToValidator(uint64 _valId) internal view returns (uint256) {
        DelInfo memory _delInfo = _getDelegatorInfo(_valId, address(this));
        return _delInfo.stake + _delInfo.deltaStake + _delInfo.nextDeltaStake;
    }

    /**
     * @notice Remove validator ID from storage array
     * @dev Efficiently removes validator by swapping with last element
     * @param array The storage array to modify
     * @param valId The validator ID to remove
     */
    function _removeFromArray(uint64[] storage array, uint64 valId) internal {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == valId) {
                array[i] = array[array.length - 1];
                array.pop();
                break;
            }
        }
    }

    /**
     * @notice Complete all pending withdrawal requests for a user
     * @dev Processes all user withdrawal requests, charges fees, and transfers funds
     * @param _user The user address whose withdrawals to complete
     * @return _totalWithdrawn The total amount withdrawn before fees
     * @return _totalWithdrawnAfterFee The amount transferred to user after fees
     */
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

    /**
     * @notice Complete a redelegation withdrawal process
     * @dev Withdraws funds and marks the withdrawal as completed
     * @param _valId The validator ID
     * @param _withdrawalId The withdrawal ID to complete
     */
    function _completeRedelegationWithdrawal(uint64 _valId, uint8 _withdrawalId) internal {
        _withdraw(_valId, _withdrawalId);
        // Mark the withdrawal as completed in the bitmap
        _markWithdrawalCompleted(_valId, _withdrawalId);

        pendingRedelegateByValidator[_valId] = 0;
    }

    /**
     * @dev Mark a withdrawal ID as free in the bitmap when withdrawal is completed
     * @param _valId The validator ID
     * @param _withdrawalId The withdrawal ID to mark as free
     */
    function _markWithdrawalCompleted(uint64 _valId, uint8 _withdrawalId) internal {
        withdrawalIdBitmaps[_valId].markWithdrawalCompleted(_withdrawalId);
    }

    /**
     * @notice Check if admin withdrawal ID is available
     * @dev Reverts if admin withdrawal ID is already in use
     * @param _valId The validator ID to check
     */
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

    /**
     * @notice Calculate rewards fee and send to fee receiver
     * @dev Calculates protocol rewards fee and transfers it to the designated receiver
     * @param _totalRewards The total rewards amount to calculate fee from
     * @return _fee The fee amount calculated and sent
     */
    function _calculateRewardsFeeAndSend(uint256 _totalRewards) internal returns (uint256 _fee) {
        _fee = Math.mulDiv(_totalRewards, magma.rewardsFee(), BASE_BPS, Math.Rounding.Ceil);
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
