// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MagmaDelegationModule} from "./MagmaDelegationModule.sol";
import {ErrNotAdmin, ErrNotMagma, ErrPaused, ErrEpochGuard, ErrZeroValidatorId, ErrAlreadyWhitelisted, ErrNotWhitelisted, ErrNoValidators, ErrAmountTooSmall, ErrBelowMinWithdraw, ErrZeroAmount, ErrQueueFull, ErrNoFreeWithdrawalId, ErrRebalanceInProgress, ErrInvalidAmount, ErrInsufficientDelegated, ErrNoPendingWithdrawRequest} from "./MagmaErrorsModule.sol";
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
    uint256 public pendingTotal;
    uint256 public pendingRebalanceTotal;
    bool public finishedLastRebalance;

    // Pause state
    bool public paused;

    event ValidatorAdded(uint64 indexed valId);
    event ValidatorRemoved(uint64 indexed valId);
    event RebalanceInitiated();
    event RebalanceCompleted();
    event EnqueuedUndelegate(uint256 amount, address indexed caller);
    event SubmittedUndelegate(
        uint8 withdrawalId,
        uint256 perValidatorAmount,
        uint256 validatorCount
    );
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
        uint64 indexed valId,
        uint8 indexed withdrawalId,
        address indexed user,
        uint256 amount
    );
    event WithdrawalPaymentSuccess(
        uint64 indexed valId,
        uint8 indexed withdrawalId,
        address indexed user,
        uint256 amount
    );
    event WithdrawalFailed(uint64 indexed valId, uint8 indexed withdrawalId);

    function initialize(
        address _magma,
        uint256 _minQueueDelaySeconds,
        uint256 _epochSeconds
    ) external initializer {
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

    function pause() external onlyAdmin {
        paused = true;
    }

    function unpause() external onlyAdmin {
        paused = false;
    }

    function setMinQueueDelaySeconds(uint256 secondsDelay) external onlyAdmin {
        minQueueDelaySeconds = secondsDelay;
    }

    function setMinUserWithdrawAmount(uint256 amount) external onlyAdmin {
        if (amount >= 10000) revert ErrInvalidAmount(amount);
        minUserWithdrawAmount = amount;
    }

    function addValidator(uint64 valId) external onlyAdmin {
        if (epochSeconds != 0) {
            if (block.timestamp < lastRebalanceTimestamp + epochSeconds)
                revert ErrEpochGuard();
        }
        if (valId == 0) revert ErrZeroValidatorId();
        if (isWhitelisted[valId]) revert ErrAlreadyWhitelisted();

        validators.push(valId);
        isWhitelisted[valId] = true;

        emit ValidatorAdded(valId);
        _rebalanceInitiate();
        _rebalanceRedistribute();
        lastRebalanceTimestamp = block.timestamp;
    }

    function removeValidator(uint64 valId) external onlyAdmin {
        if (epochSeconds != 0) {
            if (block.timestamp < lastRebalanceTimestamp + epochSeconds)
                revert ErrEpochGuard();
        }
        if (!isWhitelisted[valId]) revert ErrNotWhitelisted();

        // Store the amount that was delegated to this validator
        uint256 amountToRedistribute = delegatedAmount[valId];

        // Undelegate all from this validator first
        if (amountToRedistribute > 0) {
            _undelegate(valId, amountToRedistribute, ADMIN_WID);
            delegatedAmount[valId] = 0;
            pendingRebalanceTotal += amountToRedistribute;
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

        // Redistribute the amount to remaining validators if any
        if (validators.length > 0 && amountToRedistribute > 0) {
            uint256 amountPerValidator = amountToRedistribute /
                validators.length;
            for (uint256 i = 0; i < validators.length; i++) {
                _delegate(validators[i], amountPerValidator);
                delegatedAmount[validators[i]] += amountPerValidator;
            }
        }

        emit ValidatorRemoved(valId);
        lastRebalanceTimestamp = block.timestamp;
    }

    function delegate(uint256 amount) external onlyMagma whenNotPaused {
        if (validators.length == 0) revert ErrNoValidators();

        uint256 amountPerValidator = amount / validators.length;
        if (amountPerValidator == 0) revert ErrAmountTooSmall();

        for (uint256 i = 0; i < validators.length; i++) {
            _delegate(validators[i], amountPerValidator);
            delegatedAmount[validators[i]] += amountPerValidator;
        }
    }

    function undelegate(uint256 amount) external onlyMagma whenNotPaused {
        if (amount < minUserWithdrawAmount)
            revert ErrBelowMinWithdraw(minUserWithdrawAmount);
        if (validators.length == 0) revert ErrNoValidators();

        uint256 amountPerValidator = amount / validators.length;
        if (amountPerValidator == 0) revert ErrAmountTooSmall();

        for (uint256 i = 0; i < validators.length; i++) {
            uint64 v = validators[i];
            uint256 effective = delegatedAmount[v] +
                pendingUndelegateByValidator[v];
            if (effective < amountPerValidator)
                revert ErrInsufficientDelegated(amountPerValidator, effective);
            uint8 wid = _allocateWithdrawalId(v);
            _undelegate(v, amountPerValidator, wid);
            // Track pending; do not lower local delegated until completion
            pendingUndelegateByValidator[v] += amountPerValidator;
            pendingTotal += amountPerValidator;
        }
    }

    function enqueueUndelegate(
        uint256 amount
    ) external onlyMagma whenNotPaused {
        if (amount == 0) revert ErrZeroAmount();
        if (queueTxUserAddress.length >= MAX_QUEUE_ITEMS) revert ErrQueueFull();
        queuedUndelegateAmount += amount;
        queueTxUserAddress.push(msg.sender);
        queueTxUserAmount.push(amount);
        emit EnqueuedUndelegate(amount, msg.sender);
    }

    function _completeUndelegation() internal {
        uint256 sum = queuedUndelegateAmount;
        if (sum == 0) return;
        uint256 vCount = validators.length;
        if (vCount == 0) return;
        uint256 perValidator = sum / vCount;
        if (perValidator == 0) return;
        // Ensure each validator has capacity
        for (uint256 i = 0; i < vCount; i++) {
            uint64 v = validators[i];
            if (delegatedAmount[v] < perValidator) {
                return; // wait until capacity; no partials for simplicity
            }
        }
        // Allocate wid per validator and submit equal-split, while attributing per-user amounts proportionally
        uint256 nUsers = queueTxUserAddress.length;
        for (uint256 i = 0; i < vCount; i++) {
            uint64 v = validators[i];
            uint8 wid = _allocateWithdrawalId(v);
            _undelegate(v, perValidator, wid);
            pendingUndelegateByValidator[v] += perValidator;
            emit SubmittedUndelegate(wid, perValidator, vCount);

            // Attribute per-user shares for this (v, wid)
            // Proportional split: userShare = userAmount * perValidator / sum, with last index receiving remainder
            address[] storage usersStore = pendingUserAddresses[v][wid];
            uint256[] storage amountsStore = pendingUserAmounts[v][wid];
            // copy addresses
            for (uint256 j = 0; j < nUsers; j++) {
                usersStore.push(queueTxUserAddress[j]);
            }
            // compute scaled amounts
            uint256 remaining = perValidator;
            for (uint256 j2 = 0; j2 < nUsers; j2++) {
                uint256 alloc = (queueTxUserAmount[j2] * perValidator) / sum;
                // prevent over-allocation due to rounding
                if (alloc > remaining) alloc = remaining;
                amountsStore.push(alloc);
                remaining -= alloc;
            }
            if (nUsers > 0 && remaining > 0) {
                // add leftover to last entry
                amountsStore[nUsers - 1] += remaining;
            }
        }
        pendingTotal += perValidator * vCount;
        queuedUndelegateAmount = 0;
        // Clear the queue after fully attributing this batch
        delete queueTxUserAddress;
        delete queueTxUserAmount;
    }

    function processPending() external {
        _completeUndelegation();
    }

    function _completeWithdrawal(uint64 valId, uint8 withdrawalId) internal {
        // Read amount before withdrawing to update pendingTotal
        (bool exists, uint256 amt, , ) = _getWithdrawalRequest(
            valId,
            address(this),
            withdrawalId
        );
        if (!(exists && amt > 0)) revert ErrNoPendingWithdrawRequest();

        if (_tryWithdraw(valId, withdrawalId)) {
            // Distribute expected amount to users in order; leave leftovers if any send fails
            uint256 remaining = amt;
            uint256 n = pendingUserAddresses[valId][withdrawalId].length;
            uint256 totalDistributed = 0;
            uint256 totalDue = 0;

            for (uint256 i = 0; i < n && remaining > 0; i++) {
                address u = pendingUserAddresses[valId][withdrawalId][i];
                uint256 due = pendingUserAmounts[valId][withdrawalId][i];
                totalDue += due;
                if (due == 0 || u == address(0)) continue;
                if (due > remaining) {
                    emit WithdrawalAmountMismatch(
                        valId,
                        withdrawalId,
                        totalDue,
                        totalDistributed,
                        due,
                        u
                    );
                    continue;
                }
                (bool ok, ) = u.call{value: due}("");
                if (!ok) {
                    emit WithdrawalPaymentFailed(valId, withdrawalId, u, due);
                    continue;
                } else {
                    totalDistributed += due;
                    emit WithdrawalPaymentSuccess(valId, withdrawalId, u, due);
                }
                remaining -= due;
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

            pendingTotal = (amt > pendingTotal) ? 0 : (pendingTotal - amt);
        } else {
            emit WithdrawalFailed(valId, withdrawalId);
        }
    }

    function completeWithdrawal(uint64 valId, uint8 withdrawalId) external {
        _completeWithdrawal(valId, withdrawalId);
    }

    // Convenience overload: try for all validators for this withdrawalId
    function completeWithdrawal(uint8 withdrawalId) external {
        uint256 vCount = validators.length;
        for (uint256 i = 0; i < vCount; i++) {
            uint64 v = validators[i];
            (bool exists, , , ) = _getWithdrawalRequest(
                v,
                address(this),
                withdrawalId
            );
            if (exists) {
                _completeWithdrawal(v, withdrawalId);
            }
        }
    }

    // Phase 1: initiate by undelegating excess from over-target validators
    function adminRebalanceInitiate() external onlyAdmin {
        if (!finishedLastRebalance) revert ErrRebalanceInProgress();
        finishedLastRebalance = false;
        if (epochSeconds != 0) {
            if (block.timestamp < lastRebalanceTimestamp + epochSeconds)
                revert ErrEpochGuard();
        }
        _rebalanceInitiate();
        lastRebalanceTimestamp = block.timestamp;
    }

    // Phase 2: redistribute by delegating to under-target validators
    function adminRebalanceRedistribute() external onlyAdmin {
        _rebalanceRedistribute();
    }

    function _rebalanceInitiate() internal {
        if (validators.length == 0) return;

        uint256 totalDelegated = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            totalDelegated += delegatedAmount[validators[i]];
        }
        if (totalDelegated == 0) return;

        uint256 targetPerValidator = totalDelegated / validators.length;
        for (uint256 i = 0; i < validators.length; i++) {
            uint64 v = validators[i];
            if (delegatedAmount[v] > targetPerValidator) {
                uint256 excess = delegatedAmount[v] - targetPerValidator;
                _undelegate(v, excess, ADMIN_WID);
                // Track pending excess; keep local delegated until completion
                pendingUndelegateByValidator[v] += excess;
                pendingRebalanceTotal += excess;
            }
        }
        emit RebalanceInitiated();
    }

    function _rebalanceRedistribute() internal {
        if (validators.length == 0) return;

        uint256 totalDelegated = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            totalDelegated += delegatedAmount[validators[i]];
        }
        if (totalDelegated == 0) return;

        uint256 targetPerValidator = totalDelegated / validators.length;
        for (uint256 i = 0; i < validators.length; i++) {
            uint64 v = validators[i];
            if (delegatedAmount[v] < targetPerValidator) {
                uint256 deficit = targetPerValidator - delegatedAmount[v];
                _delegate(v, deficit);
                delegatedAmount[v] = targetPerValidator;
            }
        }
        finishedLastRebalance = true;
        emit RebalanceCompleted();
    }

    // Allocate a free withdrawal id in range 0..255 for given validator id (skips admin wid)
    function _allocateWithdrawalId(uint64 valId) internal returns (uint8 wid) {
        uint8 start = _nextWithdrawalId[valId];
        for (uint16 i = 0; i < 256; i++) {
            uint8 candidate = uint8(uint16(start) + i);
            if (candidate == ADMIN_WID) continue;
            (bool exists, , , ) = _getWithdrawalRequest(
                valId,
                address(this),
                candidate
            );
            if (!exists) {
                wid = candidate;
                _nextWithdrawalId[valId] = uint8(uint16(candidate) + 1);
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
        uint256 total = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            total += delegatedAmount[validators[i]];
        }
        return total;
    }

    function _authorizeUpgrade(address) internal override {
        if (msg.sender != magma.admin()) revert ErrNotAdmin();
    }

    uint256[50] private __gap;
}
