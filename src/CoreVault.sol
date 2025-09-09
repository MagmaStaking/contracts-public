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

contract CoreVault is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    MagmaDelegationModule,
    ICoreVault
{
    using BitMapLib for BitMapLib.WithdrawalBitMap;

    IMagma public magma;

    uint64[] public validators;

    enum ValidatorStatus {
        NONE,
        PAUSED,
        UNDELEGATING
    }

    mapping(uint64 => ValidatorStatus) public validatorStatus;
    mapping(uint64 => bool) public isWhitelisted;

    uint256 public totalDelegated;
    // Per-validator withdrawal ID bitmap management
    mapping(uint64 => BitMapLib.WithdrawalBitMap) private withdrawalIdBitmaps;
    // Per-validator amounts submitted for undelegation but not yet completed

    // Simple accrued undelegation amount to submit next
    uint256 public queuedUndelegateAmount;
    // Per-tx visibility (optional, for ops/debug)
    address[] public queueTxUserAddress;
    uint256[] public queueTxUserAmount;
    // pending attribution keyed by (validator, withdrawalId)
    mapping(uint64 => mapping(uint8 => address[])) public pendingUserAddresses;
    mapping(uint64 => mapping(uint8 => uint256[])) public pendingUserAmounts;
    uint256 public minQueueDelaySeconds;
    uint256 public epochSeconds;

    // Minimum user undelegation amount
    uint256 public minUserWithdrawAmount;

    // Reserved admin-only withdrawal ID
    uint8 internal constant ADMIN_WID = 255;

    // Max number of queued undelegation entries to prevent excessive gas
    uint256 public constant MAX_QUEUE_ITEMS = 64;

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

    /**
     * @dev Override to resolve interface conflict with OpenZeppelin's PausableUpgradeable
     */
    function paused() public view override(ICoreVault, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    function initialize(address _magma, uint256 _minQueueDelaySeconds, uint256 _epochSeconds) external initializer {
        __ReentrancyGuard_init();
        __Pausable_init();
        magma = IMagma(_magma);
        minQueueDelaySeconds = _minQueueDelaySeconds;
        epochSeconds = _epochSeconds;
        finishedLastRebalance = true;
    }

    // Accept native funds returned from precompile withdrawals
    receive() external payable {}

    modifier onlyAdmin() {
        if (msg.sender != magma.admin()) revert ErrNotAdmin();
        _;
    }

    modifier onlyMagma() {
        if (msg.sender != address(magma)) revert ErrNotMagma();
        _;
    }

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
        withdrawalIdBitmaps[_valId].initForCoreVault();

        emit ValidatorAdded(_valId);
        _redelegateInitiate();
    }

    /**
     * @notice Step 2: Redistribute to validators
     * @dev Completes pending withdrawals and redistributes funds to balance validator stakes
     */
    function redelegateToValidators() external onlyAdmin {
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

    function delegate() external payable onlyMagma whenNotPaused {
        _distributeAmountEquallyToValidators(msg.value);
    }

    function undelegate(uint256 _amount) external onlyMagma whenNotPaused {
        if (_amount < minUserWithdrawAmount) {
            revert ErrBelowMinWithdraw(minUserWithdrawAmount);
        }
        if (validators.length == 0) revert ErrNoValidators();

        uint256 _amountPerValidator = _amount / validators.length;
        if (_amountPerValidator == 0) revert ErrAmountTooSmall();

        for (uint256 _i = 0; _i < validators.length; _i++) {
            uint64 _v = validators[_i];
            uint256 _effective = _getTotalStakedToValidator(_v) + pendingUndelegateByValidator[_v];
            if (_effective < _amountPerValidator) {
                revert ErrInsufficientDelegated(_amountPerValidator, _effective);
            }
            _allocateWIDandUndelegate(_v, _amountPerValidator);
            // Track pending; do not lower local delegated until completion
            pendingUndelegateByValidator[_v] += _amountPerValidator;
            totalPendingUndelegations += _amountPerValidator;
        }
    }

    function enqueueUndelegate(uint256 amount) external onlyMagma whenNotPaused {
        if (amount == 0) revert ErrZeroAmount();
        if (queueTxUserAddress.length >= MAX_QUEUE_ITEMS) revert ErrQueueFull();
        queuedUndelegateAmount += amount;
        queueTxUserAddress.push(msg.sender);
        queueTxUserAmount.push(amount);
        emit EnqueuedUndelegate(amount, msg.sender);
    }

    function _completeUndelegation() internal {
        uint256 _sum = queuedUndelegateAmount;
        if (_sum == 0) return;
        uint256 _vCount = validators.length;
        if (_vCount == 0) return;
        uint256 _perValidator = _sum / _vCount;
        if (_perValidator == 0) return;
        // Ensure each validator has capacity
        for (uint256 _i = 0; _i < _vCount; _i++) {
            uint64 _v = validators[_i];
            if (_getTotalStakedToValidator(_v) < _perValidator) {
                return; // wait until capacity; no partials for simplicity
            }
        }
        // Allocate wid per validator and submit equal-split, while attributing per-user amounts proportionally
        uint256 _nUsers = queueTxUserAddress.length;
        for (uint256 _i = 0; _i < _vCount; _i++) {
            uint64 _v = validators[_i];
            uint8 _wid = _allocateWIDandUndelegate(_v, _perValidator);
            pendingUndelegateByValidator[_v] += _perValidator;
            emit SubmittedUndelegate(_wid, _perValidator, _vCount);

            // Attribute per-user shares for this (_v, _wid)
            // Proportional split: userShare = userAmount * _perValidator / _sum, with last index receiving remainder
            address[] storage _usersStore = pendingUserAddresses[_v][_wid];
            uint256[] storage _amountsStore = pendingUserAmounts[_v][_wid];
            // copy addresses
            for (uint256 _j = 0; _j < _nUsers; _j++) {
                _usersStore.push(queueTxUserAddress[_j]);
            }
            // compute scaled amounts
            uint256 _remaining = _perValidator;
            for (uint256 _j2 = 0; _j2 < _nUsers; _j2++) {
                uint256 _alloc = (queueTxUserAmount[_j2] * _perValidator) / _sum;
                // prevent over-allocation due to rounding
                if (_alloc > _remaining) _alloc = _remaining;
                _amountsStore.push(_alloc);
                _remaining -= _alloc;
            }
            if (_nUsers > 0 && _remaining > 0) {
                // add leftover to last entry
                _amountsStore[_nUsers - 1] += _remaining;
            }
        }
        totalPendingUndelegations += _perValidator * _vCount;
        queuedUndelegateAmount = 0;
        // Clear the queue after fully attributing this batch
        delete queueTxUserAddress;
        delete queueTxUserAmount;
    }

    function processPending() external {
        _completeUndelegation();
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

    function _completeWithdrawal(uint64 valId, uint8 withdrawalId) internal {
        // Read amount before withdrawing to update totalPendingUndelegations
        (bool exists, uint256 amt,,) = _getWithdrawalRequest(valId, address(this), withdrawalId);
        if (!(exists && amt > 0)) revert ErrNoPendingWithdrawRequest();

        if (_tryWithdraw(valId, withdrawalId)) {
            // Distribute expected amount to users in order; leave leftovers if any send fails
            uint256 _remaining = amt;
            uint256 _n = pendingUserAddresses[valId][withdrawalId].length;
            uint256 _totalDistributed = 0;
            uint256 _totalDue = 0;

            for (uint256 _i = 0; _i < _n && _remaining > 0; _i++) {
                address _u = pendingUserAddresses[valId][withdrawalId][_i];
                uint256 _due = pendingUserAmounts[valId][withdrawalId][_i];
                _totalDue += _due;
                if (_due == 0 || _u == address(0)) continue;
                if (_due > _remaining) {
                    emit WithdrawalAmountMismatch(valId, withdrawalId, _totalDue, _totalDistributed, _due, _u);
                    continue;
                }
                (bool _ok,) = _u.call{value: _due}("");
                if (!_ok) {
                    emit WithdrawalPaymentFailed(valId, withdrawalId, _u, _due);
                    continue;
                } else {
                    _totalDistributed += _due;
                    emit WithdrawalPaymentSuccess(valId, withdrawalId, _u, _due);
                }
                _remaining -= _due;
            }
            delete pendingUserAddresses[valId][withdrawalId];
            delete pendingUserAmounts[valId][withdrawalId];
            // Mark withdrawal ID as free in bitmap
            _markWithdrawalCompleted(valId, withdrawalId);
            // Lower local delegated now that completion finalized
            if (pendingUndelegateByValidator[valId] >= amt) {
                pendingUndelegateByValidator[valId] -= amt;
            } else {
                pendingUndelegateByValidator[valId] = 0;
            }

            totalPendingUndelegations = (amt > totalPendingUndelegations) ? 0 : (totalPendingUndelegations - amt);
        } else {
            emit WithdrawalFailed(valId, withdrawalId);
        }
    }

    function completeWithdrawal(uint64 valId, uint8 withdrawalId) external nonReentrant onlyMagma {
        _completeWithdrawal(valId, withdrawalId);
    }

    // Convenience overload: try for all validators for this withdrawalId
    function completeWithdrawal(uint8 withdrawalId) external nonReentrant onlyMagma {
        uint256 _vCount = validators.length;
        for (uint256 _i = 0; _i < _vCount; _i++) {
            uint64 _v = validators[_i];
            (bool _exists,,,) = _getWithdrawalRequest(_v, address(this), withdrawalId);
            if (_exists) {
                _completeWithdrawal(_v, withdrawalId);
            }
        }
    }

    // Phase 1: initiate by undelegating excess from over-target validators
    function adminRebalanceInitiate() external onlyAdmin onlyAfterEpoch {
        if (!finishedLastRebalance) revert ErrRebalanceInProgress();
        finishedLastRebalance = false;
        _redelegateInitiate();
        lastRebalanceTimestamp = block.timestamp;
    }

    // Phase 2: redistribute by delegating to under-target validators
    function adminRebalanceRedistribute() external onlyAdmin {
        _rebalanceRedistribute();
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
    //--------------------------------------------------------------------------------------------------------------
    // Internal functions
    //--------------------------------------------------------------------------------------------------------------

    function _getTotalStakedToAllValidators() internal view returns (uint256) {
        uint256 _total = 0;
        for (uint256 _i = 0; _i < validators.length; _i++) {
            _total += _getTotalStakedToValidator(validators[_i]);
        }
        return _total;
    }

    function _getTotalStakedToValidator(uint64 _valId) internal view returns (uint256) {
        DelInfo memory _delInfo = _getDelegatorInfo(_valId, address(this));
        return _delInfo.stake + _delInfo.delta_stake + _delInfo.next_delta_stake;
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

    function _rebalanceRedistribute() internal {
        if (validators.length == 0) return;

        uint256 _totalDelegated = 0;
        for (uint256 _i = 0; _i < validators.length; _i++) {
            _totalDelegated += _getTotalStakedToValidator(validators[_i]);
        }
        if (_totalDelegated == 0) return;

        uint256 _targetPerValidator = _totalDelegated / validators.length;
        for (uint256 _i = 0; _i < validators.length; _i++) {
            uint64 _v = validators[_i];
            if (_getTotalStakedToValidator(_v) < _targetPerValidator) {
                uint256 _deficit = _targetPerValidator - _getTotalStakedToValidator(_v);
                _delegate(_v, _deficit);
            }
        }
        finishedLastRebalance = true;
        emit RebalanceCompleted();
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
        if (validators.length == 0 || amount == 0) return;

        uint256 _amountPerValidator = amount / validators.length;
        for (uint256 _i = 0; _i < validators.length; _i++) {
            _delegate(validators[_i], _amountPerValidator);
        }
    }

    function _allocateWIDandUndelegate(uint64 valId, uint256 amount) internal returns (uint8 wid) {
        wid = withdrawalIdBitmaps[valId].allocateWithdrawalIdForCoreVault();
        _undelegate(valId, amount, wid);
        return wid;
    }

    /**
     * @dev Mark a withdrawal ID as free in the bitmap when withdrawal is completed
     * @param valId The validator ID
     * @param withdrawalId The withdrawal ID to mark as free
     */
    function _markWithdrawalCompleted(uint64 valId, uint8 withdrawalId) internal {
        withdrawalIdBitmaps[valId].markWithdrawalCompletedForCoreVault(withdrawalId);
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

    function _authorizeUpgrade(address) internal override {
        if (msg.sender != magma.admin()) revert ErrNotAdmin();
    }

    uint256[50] private __gap;
}
