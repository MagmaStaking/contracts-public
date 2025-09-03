// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MagmaDelegationModule} from "./MagmaDelegationModule.sol";
import {
    ErrNotAdmin,
    ErrNotMagma,
    ErrPaused,
    ErrEpochGuard,
    ErrZeroValidatorId,
    ErrAlreadyWhitelisted,
    ErrNotWhitelisted,
    ErrNoValidators,
    ErrAmountTooSmall,
    ErrBelowMinWithdraw,
    ErrZeroAmount,
    ErrQueueFull,
    ErrNoFreeWithdrawalId,
    ErrRebalanceInProgress,
    ErrInvalidAmount,
    ErrInsufficientDelegated,
    ErrNoPendingWithdrawRequest
} from "./MagmaErrorsModule.sol";
import {IMagma} from "../interfaces/IMagma.sol";

contract CoreVault is Initializable, UUPSUpgradeable, MagmaDelegationModule {
    IMagma public magma;

    uint64[] public validators;
    mapping(uint64 => bool) public isWhitelisted;
    mapping(uint64 => uint256) public delegatedAmount;
    // Per-validator next withdrawal id cursor (0..255)
    mapping(uint64 => uint8) private _nextWithdrawalId;
    // Per-validator amounts submitted for undelegation but not yet completed
    mapping(uint64 => uint256) public pendingUndelegateByValidator;

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
    uint256 public totalPendingUndelegations;
    uint256 public pendingRebalanceTotal;
    bool public finishedLastRebalance;

    // Pause state
    bool public paused;

    event ValidatorAdded(uint64 indexed valId);
    event ValidatorRemoved(uint64 indexed valId);
    event ValidatorRemovalCompleted(uint64 indexed valId);
    event RebalanceInitiated();
    event RebalanceCompleted();
    event EnqueuedUndelegate(uint256 amount, address indexed caller);
    event SubmittedUndelegate(uint8 withdrawalId, uint256 perValidatorAmount, uint256 validatorCount);
    // User withdrawal distribution events (mirrors gVault for consistency)
    event WithdrawalAmountMismatch(
        uint64 indexed valId,
        uint8 indexed withdrawalId,
        uint256 totalDue,
        uint256 totalDistributed,
        uint256 expectedDueForUser,
        address indexed user
    );
    event WithdrawalPaymentFailed(
        uint64 indexed valId, uint8 indexed withdrawalId, address indexed user, uint256 amount
    );
    event WithdrawalPaymentSuccess(
        uint64 indexed valId, uint8 indexed withdrawalId, address indexed user, uint256 amount
    );
    event WithdrawalFailed(uint64 indexed valId, uint8 indexed withdrawalId);

    function initialize(address _magma, uint256 _minQueueDelaySeconds, uint256 _epochSeconds) external initializer {
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

    modifier whenNotPaused() {
        if (paused) revert ErrPaused();
        _;
    }

    modifier onlyAfterEpoch() {
        if (epochSeconds != 0) {
            if (block.timestamp < lastRebalanceTimestamp + epochSeconds) {
                revert ErrEpochGuard();
            }
        }
        _;
    }

    function pause() external onlyAdmin {
        paused = true;
    }

    function unpause() external onlyAdmin {
        paused = false;
    }

    function setMinQueueDelaySeconds(uint256 secondsDelay) external onlyAdmin {
        minQueueDelaySeconds = secondsDelay;
    }

    // Minimum user withdraw amount default amount is missing precision
    function setMinUserWithdrawAmount(uint256 amount) external onlyAdmin {
        if (amount >= 10000 ether) revert ErrInvalidAmount(amount);
        minUserWithdrawAmount = amount;
    }

    function addValidator(uint64 valId) external onlyAdmin onlyAfterEpoch {
        if (valId == 0) revert ErrZeroValidatorId();
        if (isWhitelisted[valId]) revert ErrAlreadyWhitelisted();

        validators.push(valId);
        isWhitelisted[valId] = true;

        emit ValidatorAdded(valId);
        _rebalanceInitiate();
        _rebalanceRedistribute();
        lastRebalanceTimestamp = block.timestamp;
    }

    function removeValidator(uint64 valId) external onlyAdmin onlyAfterEpoch {
        if (!isWhitelisted[valId]) revert ErrNotWhitelisted();

        // Store the amount that was delegated to this validator
        // Question: does this include pending rewards or previously compounded rewards?
        uint256 _amountToUndelegate = _getDelegatorStake(valId, address(this));

        // Undelegate all from this validator first
        if (_amountToUndelegate > 0) {
            _undelegate(valId, _amountToUndelegate, ADMIN_WID);
            delegatedAmount[valId] = 0;
            pendingRebalanceTotal += _amountToUndelegate;
        }

        // Remove from array
        for (uint256 i = 0; i < validators.length; i++) {
            if (validators[i] == valId) {
                validators[i] = validators[validators.length - 1];
                validators.pop();
                break;
            }
        }

        isWhitelisted[valId] = false;

        // NOTE: Do NOT redistribute immediately!
        // The undelegated funds are locked in a withdrawal request for WITHDRAWAL_DELAY epochs.
        // After the delay period, call completeValidatorRemovalWithdrawal() to complete the process
        // and redistribute the recovered funds.

        emit ValidatorRemoved(valId);
        lastRebalanceTimestamp = block.timestamp;
    }

    function delegate(uint256 amount) external onlyMagma whenNotPaused {
        if (validators.length == 0) revert ErrNoValidators();

        uint256 _amountPerValidator = amount / validators.length;
        if (_amountPerValidator == 0) revert ErrAmountTooSmall();

        _distributeToValidators(amount);
    }

    function undelegate(uint256 amount) external onlyMagma whenNotPaused {
        if (amount < minUserWithdrawAmount) {
            revert ErrBelowMinWithdraw(minUserWithdrawAmount);
        }
        if (validators.length == 0) revert ErrNoValidators();

        uint256 _amountPerValidator = amount / validators.length;
        if (_amountPerValidator == 0) revert ErrAmountTooSmall();

        for (uint256 _i = 0; _i < validators.length; _i++) {
            uint64 _v = validators[_i];
            uint256 _effective = delegatedAmount[_v] + pendingUndelegateByValidator[_v];
            if (_effective < _amountPerValidator) {
                revert ErrInsufficientDelegated(_amountPerValidator, _effective);
            }
            uint8 _wid = _allocateWithdrawalId(_v);
            _undelegate(_v, _amountPerValidator, _wid);
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
            if (delegatedAmount[_v] < _perValidator) {
                return; // wait until capacity; no partials for simplicity
            }
        }
        // Allocate wid per validator and submit equal-split, while attributing per-user amounts proportionally
        uint256 _nUsers = queueTxUserAddress.length;
        for (uint256 _i = 0; _i < _vCount; _i++) {
            uint64 _v = validators[_i];
            uint8 _wid = _allocateWithdrawalId(_v);
            _undelegate(_v, _perValidator, _wid);
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
            // Lower local delegated now that completion finalized
            if (pendingUndelegateByValidator[valId] >= amt) {
                pendingUndelegateByValidator[valId] -= amt;
            } else {
                pendingUndelegateByValidator[valId] = 0;
            }
            if (delegatedAmount[valId] >= amt) {
                delegatedAmount[valId] -= amt;
            } else {
                delegatedAmount[valId] = 0;
            }

            totalPendingUndelegations = (amt > totalPendingUndelegations) ? 0 : (totalPendingUndelegations - amt);
        } else {
            emit WithdrawalFailed(valId, withdrawalId);
        }
    }

    function completeWithdrawal(uint64 valId, uint8 withdrawalId) external {
        _completeWithdrawal(valId, withdrawalId);
    }

    // Convenience overload: try for all validators for this withdrawalId
    function completeWithdrawal(uint8 withdrawalId) external {
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
        _rebalanceInitiate();
        lastRebalanceTimestamp = block.timestamp;
    }

    // Phase 2: redistribute by delegating to under-target validators
    function adminRebalanceRedistribute() external onlyAdmin {
        _rebalanceRedistribute();
    }

    /**
     * @dev Complete the withdrawal process for a removed validator
     * This should be called after the WITHDRAWAL_DELAY period has passed
     * @param valId The validator ID that was removed
     */
    function completeValidatorRemovalWithdrawal(uint64 valId) external onlyAdmin {
        // TODO: Claim rewards
        // Get the withdrawal amount before completing withdrawal
        (bool exists, uint256 withdrawalAmount,,) = _getWithdrawalRequest(valId, address(this), ADMIN_WID);
        if (!(exists && withdrawalAmount > 0)) revert ErrNoPendingWithdrawRequest();

        // Complete the withdrawal using the admin withdrawal ID
        _completeWithdrawal(valId, ADMIN_WID);

        // Distribute the recovered funds to remaining validators
        _distributeToValidators(withdrawalAmount);

        emit ValidatorRemovalCompleted(valId);
    }

    function _rebalanceInitiate() internal {
        if (validators.length == 0) return;

        uint256 _totalDelegated = 0;
        for (uint256 _i = 0; _i < validators.length; _i++) {
            _totalDelegated += delegatedAmount[validators[_i]];
        }
        if (_totalDelegated == 0) return;

        uint256 _targetPerValidator = _totalDelegated / validators.length;
        for (uint256 _i = 0; _i < validators.length; _i++) {
            uint64 _v = validators[_i];
            if (delegatedAmount[_v] > _targetPerValidator) {
                uint256 _excess = delegatedAmount[_v] - _targetPerValidator;
                _undelegate(_v, _excess, ADMIN_WID);
                // Track pending excess; keep local delegated until completion
                pendingUndelegateByValidator[_v] += _excess;
                pendingRebalanceTotal += _excess;
            }
        }
        emit RebalanceInitiated();
    }

    function _rebalanceRedistribute() internal {
        if (validators.length == 0) return;

        uint256 _totalDelegated = 0;
        for (uint256 _i = 0; _i < validators.length; _i++) {
            _totalDelegated += delegatedAmount[validators[_i]];
        }
        if (_totalDelegated == 0) return;

        uint256 _targetPerValidator = _totalDelegated / validators.length;
        for (uint256 _i = 0; _i < validators.length; _i++) {
            uint64 _v = validators[_i];
            if (delegatedAmount[_v] < _targetPerValidator) {
                uint256 _deficit = _targetPerValidator - delegatedAmount[_v];
                _delegate(_v, _deficit);
                delegatedAmount[_v] = _targetPerValidator;
            }
        }
        finishedLastRebalance = true;
        emit RebalanceCompleted();
    }

    // Allocate a free withdrawal id in range 0..255 for given validator id (skips admin wid)
    /**
     * @dev Distributes the specified amount equally among all validators
     * @param amount The total amount to distribute
     */
    function _distributeToValidators(uint256 amount) internal {
        if (validators.length == 0 || amount == 0) return;

        uint256 _amountPerValidator = amount / validators.length;
        for (uint256 _i = 0; _i < validators.length; _i++) {
            _delegate(validators[_i], _amountPerValidator);
            delegatedAmount[validators[_i]] += _amountPerValidator;
        }
    }

    function _allocateWithdrawalId(uint64 valId) internal returns (uint8 wid) {
        uint8 _start = _nextWithdrawalId[valId];
        for (uint16 _i = 0; _i < 256; _i++) {
            uint8 _candidate = uint8(uint16(_start) + _i);
            if (_candidate == ADMIN_WID) continue;
            (bool _exists,,,) = _getWithdrawalRequest(valId, address(this), _candidate);
            if (!_exists) {
                wid = _candidate;
                _nextWithdrawalId[valId] = uint8(uint16(_candidate) + 1);
                return wid;
            }
        }
        // If all 256 are occupied, revert; caller should withdraw some first
        revert ErrNoFreeWithdrawalId();
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
            _total += delegatedAmount[validators[_i]];
        }
        return _total;
    }

    function _authorizeUpgrade(address) internal override {
        if (msg.sender != magma.admin()) revert ErrNotAdmin();
    }

    uint256[50] private __gap;
}
