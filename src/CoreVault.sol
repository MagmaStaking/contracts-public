// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {MagmaDelegationModule, DelInfo} from "./MagmaDelegationModule.sol";
import "./MagmaErrorsModule.sol";
import {IMagma} from "../interfaces/IMagma.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {BitMapLib} from "./utils/BitMapLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VaultBase} from "./VaultBase.sol";

contract CoreVault is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ICoreVault,
    VaultBase
{
    using BitMapLib for BitMapLib.WithdrawalBitMap;

    enum ValidatorStatus {
        NONE,
        PAUSED,
        UNDELEGATING
    }

    mapping(uint64 => ValidatorStatus) public validatorStatus;

    // Per-validator withdrawal ID bitmap management
    mapping(uint64 => BitMapLib.WithdrawalBitMap) private withdrawalIdBitmaps;
    // Per-validator amounts submitted for undelegation but not yet completed

    uint256 public minQueueDelaySeconds;
    uint256 public epochSeconds;

    // Minimum user undelegation amount
    uint256 public minUserWithdrawAmount;

    // Reserved admin-only withdrawal ID
    uint8 internal constant ADMIN_WID = 255;

    // Rebalance pacing guard
    uint256 public lastRebalanceTimestamp;

    // Pending withdrawals totals
    mapping(uint64 => uint256) public pendingUndelegateByValidator;
    uint256 public totalPendingUndelegations;

    // Pending redelegations totals
    mapping(uint64 => uint256) public pendingRedelegateByValidator;
    uint256 public totalPendingRedelegation;

    bool public finishedLastRebalance;

    struct ValidatorAmount {
        uint64 valId;
        uint256 amount;
    }

    struct WithdrawalRequestInfo {
        uint256 amount;
        uint64 validator;
        uint8 withdrawalId;
    }

    // Storage for withdrawal requests - mapping from user to their withdrawal requests
    mapping(address => WithdrawalRequestInfo[]) public userWithdrawalRequests;

    /**
     * @dev Override to resolve interface conflict with OpenZeppelin's PausableUpgradeable
     */
    function paused() public view override(ICoreVault, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    function initialize(address _magma, uint256 _minQueueDelaySeconds, uint256 _epochSeconds) external initializer {
        __ReentrancyGuard_init();
        __Pausable_init();
        __VaultBase_init(_magma);
        minQueueDelaySeconds = _minQueueDelaySeconds;
        epochSeconds = _epochSeconds;
        finishedLastRebalance = true;
    }

    // Accept native funds returned from precompile withdrawals
    receive() external payable {}

    // whenNotPaused modifier is now inherited from PausableUpgradeable

    modifier onlyAfterEpoch() {
        if (epochSeconds != 0) {
            if (block.timestamp < lastRebalanceTimestamp + epochSeconds) {
                revert ErrEpochGuard();
            }
        }
        _;
    }

    function pause() external onlyAdmin {
        _pause();
    }

    function unpause() external onlyAdmin {
        _unpause();
    }

    function setMinQueueDelaySeconds(uint256 secondsDelay) external onlyAdmin {
        minQueueDelaySeconds = secondsDelay;
    }

    // Minimum user withdraw amount default amount is missing precision
    function setMinUserWithdrawAmount(uint256 amount) external onlyAdmin {
        if (amount >= 10000 ether) revert ErrInvalidAmount(amount);
        minUserWithdrawAmount = amount;
    }

    // --------------------------------------------------------------------------------------------------------------
    // Validator management functions
    // --------------------------------------------------------------------------------------------------------------

    /**
     * @notice Step 1: Add a validator and initiate rebalance phase 1 (undelegation)
     * @dev Add a validator and trigger excess undelegation. Redistribution must be done manually via redistributeToValidators()
     * @param _valId The validator ID to add
     */
    function addValidator(uint64 _valId) external onlyAdmin onlyAfterEpoch {
        if (_valId == 0) revert ErrZeroValidatorId();
        if (isWhitelisted[_valId]) revert ErrAlreadyWhitelisted();

        validators.push(_valId);
        isWhitelisted[_valId] = true;

        // Initialize bitmap with ADMIN_WID marked as reserved
        withdrawalIdBitmaps[_valId].init();

        emit ValidatorAdded(_valId);
        _redelegateInitiate();
    }

    // Phase 1: initiate by undelegating excess from over-target validators
    function adminRebalanceInitiate() external onlyAdmin onlyAfterEpoch {
        if (!finishedLastRebalance) revert ErrRebalanceInProgress();
        finishedLastRebalance = false;
        _redelegateInitiate();
        lastRebalanceTimestamp = block.timestamp;
    }

    /**
     * @notice Step 2: Redistribute to validators called after addValidator and adminRebalanceInitiate
     * @dev Completes pending withdrawals and redistributes funds to balance validator stakes
     */
    function redelegateToValidators() external onlyAdmin {
        _redelegateRedistribute();
    }

    /**
     * @notice Step 1: Initiate validator removal by adding to pendingRemovalValidators this way no new delegations
     *  can be made to the validator and we can ensure that the validator does not have pending stake stuck in the pending epochs (50k blocks, 5.5 hours)
     * @dev Initiate validator removal by adding to pendingRemovalValidators
     * @param _valId The validator ID to remove
     */
    function initiateValidatorRemoval(uint64 _valId) external onlyAdmin {
        if (validators.length == 1) revert ErrNotEnoughValidators();
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
     * @notice Step 2: Remove validator from validators array this function forces all stake to be in an active state
     * @dev Remove validator from validators array
     * @param _valId The validator ID to remove
     */
    function executeValidatorUndelegation(uint64 _valId) external onlyAdmin {
        if (validatorStatus[_valId] != ValidatorStatus.PAUSED) revert ErrInvalidStatus();

        DelInfo memory _coreVaultDelInfo = _getDelegatorInfo(_valId, address(this));

        if (_coreVaultDelInfo.delta_stake > 0 || _coreVaultDelInfo.next_delta_stake > 0) {
            revert ErrPendingStakeNotZero();
        }

        // TODO: Claim rewards here as well and distribute to remaining validators

        uint256 _amountToRedelegate = _coreVaultDelInfo.stake;

        // Undelegate all from this validator first
        if (_amountToRedelegate > 0) {
            _undelegate(_valId, _amountToRedelegate, ADMIN_WID);

            validatorStatus[_valId] = ValidatorStatus.UNDELEGATING;
            emit ValidatorRemoved(_valId);
        } else {
            delete validatorStatus[_valId];
            emit ValidatorRemovalCompleted(_valId);
        }
    }

    /**
     * @dev Complete the withdrawal process for a removed validator
     * This should be called after the WITHDRAWAL_DELAY period has passed
     * @param _valId The validator ID that was removed
     */
    function completeValidatorRemovalWithdrawal(uint64 _valId) external onlyAdmin {
        if (validatorStatus[_valId] != ValidatorStatus.UNDELEGATING) revert ErrInvalidStatus();

        // TODO: Claim rewards
        // Check bitmap first - if ADMIN_WID is not in use, no pending withdrawal exists
        if (!withdrawalIdBitmaps[_valId].isWithdrawalIdInUse(ADMIN_WID)) {
            revert ErrNoPendingWithdrawRequest();
        }

        // Get the withdrawal amount before completing withdrawal
        (bool exists, uint256 _withdrawalAmount,,) = _getWithdrawalRequest(_valId, address(this), ADMIN_WID);
        if (!(exists && _withdrawalAmount > 0)) revert ErrNoPendingWithdrawRequest();

        // Complete the withdrawal using the admin withdrawal ID
        _completeRedelegationWithdrawal(_valId, ADMIN_WID, _withdrawalAmount);

        // Distribute the recovered funds to remaining validators
        _distributeAmountEquallyToValidators(_withdrawalAmount);

        // Reduce the pending redistribution amount by the amount we just redistributed
        if (totalPendingRedelegation >= _withdrawalAmount) {
            totalPendingRedelegation -= _withdrawalAmount;
        } else {
            totalPendingRedelegation = 0;
        }

        lastRebalanceTimestamp = block.timestamp;

        delete validatorStatus[_valId];
        emit ValidatorRemovalCompleted(_valId);
    }

    // --------------------------------------------------------------------------------------------------------------
    // Delegation functions
    // --------------------------------------------------------------------------------------------------------------

    function delegate() external payable onlyMagma whenNotPaused {
        _distributeAmountEquallyToValidators(msg.value);
    }

    function undelegate(uint256 _amount, address _user) external onlyMagma whenNotPaused {
        if (_amount < minUserWithdrawAmount) {
            revert ErrBelowMinWithdraw(minUserWithdrawAmount);
        }
        if (validators.length == 0) revert ErrNoValidators();

        // only one withdrawal per user
        if (userWithdrawalRequests[_user].length > 0) revert ErrExistingWithdrawalInProgress();

        // Get validators sorted by stake (highest first) and total stake in one go
        (ValidatorAmount[] memory _sortedValidators, uint256 _totalActiveStake) =
            _getSortedValidatorsByActiveStakeDescendingWithTotal();

        uint256 _remainingAmount = _amount;
        uint256 _onetwentiethThreshold = _totalActiveStake / 20; // 1/20th of total active stake across all validators

        for (uint256 _i = 0; _i < _sortedValidators.length && _remainingAmount > 0; _i++) {
            uint64 _valId = _sortedValidators[_i].valId;
            uint256 _availableStake = _sortedValidators[_i].amount; // Use stake from sorted array

            if (_availableStake == 0) continue;

            // Check if request exceeds 1/20th of total active stake
            uint256 _maxAllowedFromValidator =
                _remainingAmount > _onetwentiethThreshold ? _onetwentiethThreshold : _remainingAmount;

            uint256 _amountFromValidator = _remainingAmount;
            if (_amountFromValidator > _maxAllowedFromValidator) {
                _amountFromValidator = _maxAllowedFromValidator;
            }
            if (_amountFromValidator > _availableStake) {
                _amountFromValidator = _availableStake;
            }

            if (_amountFromValidator > 0) {
                uint8 _wid = _allocateWIDandUndelegate(_valId, _amountFromValidator);

                // Store withdrawal request information
                _storeWithdrawalRequest(_user, _amountFromValidator, _valId, _wid);

                // Track pending; do not lower local delegated until completion
                pendingUndelegateByValidator[_valId] += _amountFromValidator;
                totalPendingUndelegations += _amountFromValidator;
                _remainingAmount -= _amountFromValidator;
            }
        }

        // If we couldn't fulfill the full amount, revert
        if (_remainingAmount > 0) {
            revert ErrInsufficientDelegated(_amount, _amount - _remainingAmount);
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
     * @notice Complete withdrawal for a specific user's undelegation requests
     * @dev Processes all withdrawal requests for the user and returns total amount distributed
     * @param _user The user whose withdrawal requests to complete
     * @return _totalWithdrawn The actual amount successfully withdrawn and sent to the user
     */
    function completeUserWithdrawal(address _user) external nonReentrant onlyMagma returns (uint256 _totalWithdrawn) {
        WithdrawalRequestInfo[] storage _userRequests = userWithdrawalRequests[_user];
        if (_userRequests.length == 0) revert ErrNoPendingWithdrawRequest();

        _totalWithdrawn = 0;
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
            if (_tryWithdraw(_valId, _withdrawalId)) {
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
            } else {
                emit WithdrawalFailed(_valId, _withdrawalId);
            }
        }

        // Send all accumulated ETH to user in a single transaction
        if (_totalSuccessfulWithdrawals > 0) {
            (bool success,) = _user.call{value: _totalSuccessfulWithdrawals}("");
            if (success) {
                _totalWithdrawn = _totalSuccessfulWithdrawals;
            } else {
                // If the single payment fails, emit failure event
                emit WithdrawalPaymentFailed(0, 0, _user, _totalSuccessfulWithdrawals);
                _totalWithdrawn = 0;
            }
        }

        // Clear all withdrawal requests for this user after processing
        delete userWithdrawalRequests[_user];

        emit UserWithdrawalCompleted(_user, _totalWithdrawn);
    }

    function getValidators() external view returns (uint64[] memory) {
        return validators;
    }

    function getValidatorCount() external view returns (uint256) {
        return validators.length;
    }

    function getTotalDelegated() external view returns (uint256) {
        uint256 _total = 0;
        for (uint256 _i = 0; _i < validators.length; _i++) {
            _total += _getTotalStakedToValidator(validators[_i]);
        }
        return _total;
    }

    // Function totalAssets to get all the stake, delta stake, next delta stake, and pending redelegations for all validators
    function totalAssets() external view returns (uint256) {
        return _getTotalStakedToAllValidators() + totalPendingRedelegation;
    }

    function delegatedAmount(uint64 _valId) external view returns (uint256) {
        return _getTotalStakedToValidator(_valId);
    }

    function claimAndCompoundRewards() external {
        _claimAndCompoundRewards();
    }
    //--------------------------------------------------------------------------------------------------------------
    // Internal functions
    //--------------------------------------------------------------------------------------------------------------

    function _claimAndCompoundRewards() internal {
        uint256 _startingBalance = address(this).balance;
        for (uint256 _i = 0; _i < validators.length; _i++) {
            uint256 _before = address(this).balance;
            _claim(validators[_i]);
            emit RewardsClaimed(validators[_i], address(this).balance - _before);
        }
        uint256 _endingBalance = address(this).balance;
        uint256 _rewards = _endingBalance - _startingBalance;

        uint256 _fee = Math.mulDiv(_rewards, magma.rewardsFee(), 1000, Math.Rounding.Ceil);

        // send fee to fee receiver
        (bool _ok,) = magma.rewardsFeeReceiver().call{value: _fee}("");
        if (!_ok) {
            emit RewardsFeeTransferFailed(_fee);
        } else {
            emit RewardsFeeTransferSuccess(_fee, magma.rewardsFeeReceiver());
        }

        uint256 _remaining = _rewards - _fee;
        _distributeAmountEquallyToValidators(_remaining);
    }

    function _getTotalStakedToAllValidators() internal view returns (uint256) {
        uint256 _total = 0;
        for (uint256 _i = 0; _i < validators.length; _i++) {
            _total += _getTotalStakedToValidator(validators[_i]);
        }
        return _total;
    }

    function _redelegateInitiate() internal {
        if (validators.length == 0) return;

        uint256 _totalDelegated = _getTotalStakedToAllValidators(); // contains pending redelegations
        if (_totalDelegated == 0) return;

        uint256 _targetPerValidator = _totalDelegated / validators.length;
        for (uint256 _i = 0; _i < validators.length; _i++) {
            uint64 _v = validators[_i];
            if (_getTotalStakedToValidator(_v) > _targetPerValidator) {
                uint256 _excess = _getTotalStakedToValidator(_v) - _targetPerValidator;

                // Check if validator has sufficient active stake for undelegation
                // Get actual stake from precompile to ensure we can undelegate
                DelInfo memory _delInfo = _getDelegatorInfo(_v, address(this));
                uint256 _availableStake = _delInfo.stake;

                // Undelegate the minimum of what we want and what's available
                uint256 _toUndelegate = _excess < _availableStake ? _excess : _availableStake;

                if (_toUndelegate > 0) {
                    _undelegate(_v, _toUndelegate, ADMIN_WID);
                    // Track pending excess; keep local delegated until completion
                    pendingRedelegateByValidator[_v] += _toUndelegate;
                    totalPendingRedelegation += _toUndelegate;
                }
            }
        }
        emit RebalanceInitiated();
    }

    function _redelegateRedistribute() internal {
        // Step 1: Complete all pending withdrawals
        uint256 _totalAmountToDistribute = _completeAllPendingRedelegationWithdrawals();

        if (_totalAmountToDistribute == 0) return;

        // Step 2: Get validators sorted by current stake (lowest first)
        ValidatorAmount[] memory _sortedValidators = _getSortedValidatorsByStake();

        // Step 3: Distribute stake to under-target validators in ascending order of stake
        _distributeStakeToValidatorsAscending(_sortedValidators, _totalAmountToDistribute);

        // Step 4: Update timestamp
        lastRebalanceTimestamp = block.timestamp;
    }

    /**
     * @notice Complete all pending withdrawals for admin withdrawal ID
     * @dev Internal helper function that completes withdrawals and returns total amount withdrawn
     * @return _totalWithdrawn The total amount withdrawn from all validators
     */
    function _completeAllPendingRedelegationWithdrawals() internal returns (uint256 _totalWithdrawn) {
        for (uint256 _i = 0; _i < validators.length; _i++) {
            uint64 _valId = validators[_i];

            // Check bitmap first - if ADMIN_WID is not in use, skip expensive precompile call
            if (!withdrawalIdBitmaps[_valId].isWithdrawalIdInUse(ADMIN_WID)) {
                continue;
            }

            (bool _exists, uint256 _amount,,) = _getWithdrawalRequest(_valId, address(this), ADMIN_WID);
            if (_exists && _amount > 0) {
                // For admin withdrawals, we need to handle pending redelegation amounts
                if (_tryWithdraw(_valId, ADMIN_WID)) {
                    // Update pending redelegation tracking
                    // TODO: consider slashing events
                    if (pendingRedelegateByValidator[_valId] >= _amount) {
                        pendingRedelegateByValidator[_valId] -= _amount;
                    } else {
                        pendingRedelegateByValidator[_valId] = 0;
                    }

                    if (totalPendingRedelegation >= _amount) {
                        totalPendingRedelegation -= _amount;
                    } else {
                        totalPendingRedelegation = 0;
                    }

                    // Mark withdrawal ID as completed
                    _markWithdrawalCompleted(_valId, ADMIN_WID);
                    _totalWithdrawn += _amount;
                }
            }
        }
    }

    /**
     * @notice Get validators sorted by their current stake (lowest first)
     * @dev Internal helper function that builds array of validators with current stakes and sorts them
     * @return _sortedValidators Array of ValidatorAmount structs sorted by stake amount (ascending)
     */
    function _getSortedValidatorsByStake() internal view returns (ValidatorAmount[] memory _sortedValidators) {
        _sortedValidators = new ValidatorAmount[](validators.length);

        for (uint256 _i = 0; _i < validators.length; _i++) {
            uint64 _valId = validators[_i];
            DelInfo memory _coreVaultDelInfo = _getDelegatorInfo(_valId, address(this));
            _sortedValidators[_i] = ValidatorAmount(
                _valId, _coreVaultDelInfo.stake + _coreVaultDelInfo.delta_stake + _coreVaultDelInfo.next_delta_stake
            );
        }

        _sort(_sortedValidators);
    }

    /**
     * @notice Get validators sorted by their current stake (highest first) and active stake
     * @dev Optimized version that calculates both sorted validators and active stake in one pass
     * @return _sortedValidators Array of ValidatorAmount structs sorted by stake amount (descending)
     * @return _activeStake Active stake across all validators
     */
    function _getSortedValidatorsByActiveStakeDescendingWithTotal()
        internal
        view
        returns (ValidatorAmount[] memory _sortedValidators, uint256 _activeStake)
    {
        _sortedValidators = new ValidatorAmount[](validators.length);
        _activeStake = 0;

        for (uint256 _i = 0; _i < validators.length; _i++) {
            uint64 _valId = validators[_i];
            DelInfo memory _coreVaultDelInfo = _getDelegatorInfo(_valId, address(this));
            uint256 _validatorStake = _coreVaultDelInfo.stake;
            _sortedValidators[_i] = ValidatorAmount(_valId, _validatorStake);
            _activeStake += _validatorStake;
        }

        _sortDescending(_sortedValidators);
    }

    /**
     * @notice Distribute stake to under-target validators
     * @dev Internal helper function that calculates targets and distributes stake to validators needing more
     * @param _sortedValidators Array of validators sorted by current stake (lowest first)
     * @param _totalAmountToDistribute Total amount available for distribution
     */
    function _distributeStakeToValidatorsAscending(
        ValidatorAmount[] memory _sortedValidators,
        uint256 _totalAmountToDistribute
    ) internal {
        if (_totalAmountToDistribute == 0) return;

        // Calculate total current stake to determine new target
        uint256 _currentTotalStake = 0;
        for (uint256 _i = 0; _i < _sortedValidators.length; _i++) {
            _currentTotalStake += _sortedValidators[_i].amount;
        }

        uint256 _newTotalStake = _currentTotalStake + _totalAmountToDistribute;
        uint256 _targetAmountPerValidator = _newTotalStake / validators.length;
        uint256 _remainingToDistribute = _totalAmountToDistribute;

        // Distribute to under-target validators, starting with lowest stake
        for (uint256 _i = 0; _i < _sortedValidators.length && _remainingToDistribute > 0; _i++) {
            uint64 _valId = _sortedValidators[_i].valId;
            uint256 _currentAmount = _sortedValidators[_i].amount;

            if (_currentAmount < _targetAmountPerValidator) {
                uint256 _needed = _targetAmountPerValidator - _currentAmount;
                uint256 _toDelegate = _needed > _remainingToDistribute ? _remainingToDistribute : _needed;

                if (_toDelegate > 0) {
                    _delegate(_valId, _toDelegate);
                    _remainingToDistribute -= _toDelegate;
                }
            }
        }
    }

    // Allocate a free withdrawal id in range 0..255 for given validator id (skips admin wid)
    /**
     * @dev Distributes the specified amount equally among all validators
     * @param amount The total amount to distribute
     */
    function _distributeAmountEquallyToValidators(uint256 amount) internal {
        if (validators.length == 0) {
            revert ErrNoValidators();
        }
        if (amount == 0) {
            revert ErrZeroAmount();
        }

        uint256 _amountPerValidator = amount / validators.length;
        for (uint256 _i = 0; _i < validators.length; _i++) {
            _delegate(validators[_i], _amountPerValidator);
        }
    }

    function _allocateWIDandUndelegate(uint64 valId, uint256 amount) internal returns (uint8 wid) {
        wid = withdrawalIdBitmaps[valId].allocateWithdrawalId();
        _undelegate(valId, amount, wid);
        return wid;
    }

    /**
     * @dev Mark a withdrawal ID as free in the bitmap when withdrawal is completed
     * @param valId The validator ID
     * @param withdrawalId The withdrawal ID to mark as free
     */
    function _markWithdrawalCompleted(uint64 valId, uint8 withdrawalId) internal {
        withdrawalIdBitmaps[valId].markWithdrawalCompleted(withdrawalId);
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

    /**
     * @dev Simple insertion sort for ValidatorAmount array (ascending by amount)
     */
    function _sort(ValidatorAmount[] memory _arr) internal pure {
        uint256 _length = _arr.length;
        for (uint256 _i = 1; _i < _length; _i++) {
            ValidatorAmount memory key = _arr[_i];
            uint256 _j = _i;
            while (_j > 0 && _arr[_j - 1].amount > key.amount) {
                _arr[_j] = _arr[_j - 1];
                _j--;
            }
            _arr[_j] = key;
        }
    }

    /**
     * @dev Simple insertion sort for ValidatorAmount array (descending by amount)
     */
    function _sortDescending(ValidatorAmount[] memory _arr) internal pure {
        uint256 _length = _arr.length;
        for (uint256 _i = 1; _i < _length; _i++) {
            ValidatorAmount memory key = _arr[_i];
            uint256 _j = _i;
            while (_j > 0 && _arr[_j - 1].amount < key.amount) {
                _arr[_j] = _arr[_j - 1];
                _j--;
            }
            _arr[_j] = key;
        }
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
     * @dev Get all withdrawal requests for a user
     * @param _user The user address
     * @return Array of withdrawal request information
     */
    function getUserWithdrawalRequests(address _user) external view returns (WithdrawalRequestInfo[] memory) {
        return userWithdrawalRequests[_user];
    }

    /**
     * @dev Get specific withdrawal request for a user by index
     * @param _user The user address
     * @param _index The index of the withdrawal request
     * @return The withdrawal request information
     */
    function getUserWithdrawalRequest(address _user, uint256 _index)
        external
        view
        returns (WithdrawalRequestInfo memory)
    {
        if (_index >= userWithdrawalRequests[_user].length) revert ErrInvalidAmount(_index);
        return userWithdrawalRequests[_user][_index];
    }

    /**
     * @dev Get total number of withdrawal requests for a user
     * @param _user The user address
     * @return The total count of withdrawal requests for the user
     */
    function getUserWithdrawalRequestCount(address _user) external view returns (uint256) {
        return userWithdrawalRequests[_user].length;
    }

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != magma.admin()) revert ErrNotAdmin();
    }

    uint256[50] private __gap;
}
