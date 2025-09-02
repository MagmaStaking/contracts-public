// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MagmaDelegationModule} from "./MagmaDelegationModule.sol";
import {
    ErrNotMagma,
    ErrNotAdmin,
    ErrZeroValidatorId,
    ErrAlreadyWhitelisted,
    ErrEpochGuard,
    ErrMustPauseBeforeRemove,
    ErrNotWhitelisted,
    ErrInvalidBps,
    ErrInvalidAmount,
    ErrBelowMinWithdraw,
    ErrCapZero,
    ErrExceedsCap,
    ErrZeroAddress,
    ErrInsufficientPosition,
    ErrRebalanceInProgress,
    ErrQueueFull,
    ErrForwardFailed
} from "./MagmaErrorsModule.sol";
import {IMagma} from "../interfaces/IMagma.sol";

contract gVault is Initializable, UUPSUpgradeable, MagmaDelegationModule {
    IMagma public magma;

    // Whitelist of eligible validators (tracked by valId)
    mapping(uint64 => bool) public isWhitelisted;
    uint64[] public whitelistedValidators;

    // Track user positions: amount delegated per validator id
    mapping(address => mapping(uint64 => uint256)) public delegatedAmountOf; // user => valId => amount
    mapping(address => uint64[]) public userValidators; // user => list of valIds with non-zero positions
    mapping(address => mapping(uint64 => bool)) public userHasValidator; // user => valId => in list
    // Reverse index: valId => list of users with non-zero positions
    mapping(uint64 => address[]) public validatorUsers;
    mapping(uint64 => mapping(address => bool)) public validatorHasUser; // valId => user => in list

    // Per-validator next withdrawal id cursor (0..255)
    mapping(uint64 => uint8) private _nextWithdrawalId;
    uint256 public minQueueDelaySeconds;
    uint256 public lastRebalanceTimestamp;
    uint256 public epochSeconds;
    bool public finishedLastRebalance = true;
    uint256 public minUserWithdrawAmount;

    // Max number of queued undelegation entries per validator to prevent excessive gas
    uint256 public constant MAX_QUEUE_ITEMS_PER_VALIDATOR = 64;

    // Simple accrued undelegation amount per validator to submit next
    // amount waiting for a withdrawalId to become available
    mapping(uint64 => uint256) public queuedAmountByValidator;
    // only tracking withdrawals, not rebalances. For frontend visibility and being able to debug any errors/issues around failed withdrawals. Will not work for rebalances.
    // queued withdrawals
    // validatorId -> user -> amount
    mapping(uint64 => mapping(address => uint256)) public queuedUserAmount;
    // per transaction view into the queue
    mapping(uint64 => address[]) public queueTxUserAddress;
    mapping(uint64 => uint256[]) public queueTxUserAmount;

    // pending withdrawals
    // Pending withdrawals per validator (sum of amounts successfully submitted but not yet withdrawn)
    mapping(uint64 => uint256) public pendingTotalByValidator;
    // per transaction view into each batched withdrawal
    // validatorId -> withdrawalId -> data
    mapping(uint64 => mapping(uint64 => address[])) public pendingUserAddress;
    mapping(uint64 => mapping(uint64 => uint256[])) public pendingUserAmount;
    // validatorId -> withdrawalId
    mapping(uint64 => uint8) public pendingValidatorWithdrawalId;

    // pause withdrawals for a validator an epoch before removing
    mapping(uint64 => uint256) public pausedWithdrawalsForValidator;

    // Reserved admin-only withdrawal ID
    // ADMIN_WID_REBALANCE used for adminInitiateRebalanceBps and removing validator
    uint8 internal constant ADMIN_WID_REBALANCE = 254;

    // Per-validator deposit caps; if zero, use defaultCapPercent of Magma.totalAssets()
    mapping(uint64 => uint256) public validatorCap;
    // Default cap percent in basis points (1% = 100 bps)
    uint256 public defaultCapBps = 25; // 0.25%

    event ValidatorAdded(uint64 indexed valId);
    event ValidatorRemoved(uint64 indexed valId);
    event PositionUpdated(address indexed user, uint64 indexed valId, uint256 amount, bool isDelegate);
    event CapChanged(uint64 indexed valId, uint256 newCap);
    event DefaultCapUpdated(uint256 newDefaultBps);
    // Rebalance admin events
    event AdminInitiatedRebalance(uint16 bps);
    event AdminCompletedRebalance(uint256 amountForwarded);
    event AdminCompletedRebalanceWithdrawal(uint64 indexed valId, uint256 amount);

    event ProcessedBatch(uint64 indexed valId, uint8 withdrawalId, uint256 amount);

    // User withdrawal distribution events
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
    }

    // Accept native funds returned from delegation completion
    receive() external payable {}

    modifier onlyMagma() {
        if (msg.sender != address(magma)) revert ErrNotMagma();
        _;
    }

    modifier onlyMagmaAdmin() {
        if (msg.sender != magma.admin()) revert ErrNotAdmin();
        _;
    }

    function setMinQueueDelaySeconds(uint256 secondsDelay) external onlyMagmaAdmin {
        minQueueDelaySeconds = secondsDelay;
    }

    function pauseWithdrawalsForValidator(uint64 valId) external onlyMagmaAdmin {
        pausedWithdrawalsForValidator[valId] = block.timestamp;
    }

    function resumeWithdrawalsForValidator(uint64 valId) external onlyMagmaAdmin {
        pausedWithdrawalsForValidator[valId] = 0;
    }

    // Admin: manage whitelist
    function addValidator(uint64 valId) external onlyMagmaAdmin {
        if (valId == 0) revert ErrZeroValidatorId();
        if (isWhitelisted[valId]) revert ErrAlreadyWhitelisted();
        isWhitelisted[valId] = true;
        whitelistedValidators.push(valId);
        emit ValidatorAdded(valId);
    }

    function removeValidator(uint64 valId) external onlyMagmaAdmin {
        if (epochSeconds != 0) {
            if (block.timestamp < lastRebalanceTimestamp + epochSeconds) {
                revert ErrEpochGuard();
            }
        }

        if (
            !(
                pausedWithdrawalsForValidator[valId] > 0
                    && (block.timestamp - pausedWithdrawalsForValidator[valId]) > epochSeconds
            )
        ) revert ErrMustPauseBeforeRemove();

        if (!isWhitelisted[valId]) revert ErrNotWhitelisted();

        // 1) Undelegate all vault-level stake from this validator
        uint256 vaultAmt = _getDelegatorStake(valId, address(this));
        if (vaultAmt > 0) {
            uint8 wid = ADMIN_WID_REBALANCE;
            _undelegate(valId, vaultAmt, wid);
        }

        // 2) Clear all user positions for this validator
        address[] storage users = validatorUsers[valId];
        uint256 n = users.length;
        for (uint256 i = 0; i < n; i++) {
            address user = users[i];
            if (userHasValidator[user][valId]) {
                uint256 curr = delegatedAmountOf[user][valId];
                if (curr > 0) {
                    // zero the position
                    delegatedAmountOf[user][valId] = 0;
                    emit PositionUpdated(user, valId, curr, false);
                }
                // remove validator from user's list
                uint64[] storage list = userValidators[user];
                uint256 m = list.length;
                for (uint256 j = 0; j < m; j++) {
                    if (list[j] == valId) {
                        list[j] = list[m - 1];
                        list.pop();
                        break;
                    }
                }
                userHasValidator[user][valId] = false;
                validatorHasUser[valId][user] = false;
            }
        }
        // reset the reverse index array
        delete validatorUsers[valId];

        // 3) Remove validator from whitelist array and map
        uint256 len = whitelistedValidators.length;
        for (uint256 i = 0; i < len; i++) {
            if (whitelistedValidators[i] == valId) {
                whitelistedValidators[i] = whitelistedValidators[len - 1];
                whitelistedValidators.pop();
                break;
            }
        }
        isWhitelisted[valId] = false;
        emit ValidatorRemoved(valId);
        lastRebalanceTimestamp = block.timestamp;
    }

    function getWhitelistedValidators() external view returns (uint64[] memory) {
        return whitelistedValidators;
    }

    // Admin: set per-validator explicit cap (can increase or decrease)
    function changeValidatorCap(uint64 valId, uint256 newCap) external onlyMagmaAdmin {
        if (!isWhitelisted[valId]) revert ErrNotWhitelisted();
        validatorCap[valId] = newCap;
        emit CapChanged(valId, newCap);
    }

    // Admin: update default cap percent (bps)
    function setDefaultCapBps(uint256 newBps) external onlyMagmaAdmin {
        if (newBps > 10_000) revert ErrInvalidBps();
        defaultCapBps = newBps;
        emit DefaultCapUpdated(newBps);
    }

    function setMinUserWithdrawAmount(uint256 amount) external onlyMagmaAdmin {
        if (amount >= 10000) revert ErrInvalidAmount(amount);
        minUserWithdrawAmount = amount;
    }

    function _maxCapFor(uint64 valId) internal view returns (uint256) {
        uint256 cap = validatorCap[valId];
        if (cap != 0) return cap;

        (bool ok, bytes memory data) = address(magma).staticcall(abi.encodeWithSignature("totalAssets()"));
        // TVL bps based cap
        if (!ok || data.length == 0) return 0;
        uint256 total = abi.decode(data, (uint256));
        return (total * defaultCapBps) / 10_000;
    }

    function delegate(address user, uint64 valId, uint256 amount) external onlyMagma {
        if (!isWhitelisted[valId]) revert ErrNotWhitelisted();
        if (user == address(0)) revert ErrZeroAddress();
        // Cap check
        uint256 cap = _maxCapFor(valId);
        if (cap == 0) revert ErrCapZero();
        uint256 newAmt = delegatedAmountOf[user][valId] + amount;
        if (newAmt > cap) revert ErrExceedsCap();
        _delegate(valId, amount);
        // Update position
        delegatedAmountOf[user][valId] = newAmt;
        if (!userHasValidator[user][valId]) {
            userHasValidator[user][valId] = true;
            userValidators[user].push(valId);
            if (!validatorHasUser[valId][user]) {
                validatorHasUser[valId][user] = true;
                validatorUsers[valId].push(user);
            }
        }
        emit PositionUpdated(user, valId, amount, true);
    }

    function undelegate(address user, uint64 valId, uint256 amount) external onlyMagma {
        if (amount < minUserWithdrawAmount) {
            revert ErrBelowMinWithdraw(minUserWithdrawAmount);
        }
        //undelegate just adds to the queue
        if (!isWhitelisted[valId]) revert ErrNotWhitelisted();
        if (user == address(0)) revert ErrZeroAddress();
        if (queueTxUserAddress[valId].length >= MAX_QUEUE_ITEMS_PER_VALIDATOR) {
            revert ErrQueueFull();
        }
        uint256 curr = delegatedAmountOf[user][valId];
        if (curr < amount) revert ErrInsufficientPosition(amount, curr);
        // remove user delegated amount during pending
        uint256 newAmt = curr - amount;
        delegatedAmountOf[user][valId] = newAmt;
        // Accrue undelegation for this validator
        queuedAmountByValidator[valId] += amount;
        // Track per-user pending
        queueTxUserAddress[valId].push(user);
        queueTxUserAmount[valId].push(amount);
        queuedUserAmount[valId][user] += amount;

        // if user has no more positions, remove from user and validator lists
        if (newAmt == 0 && userHasValidator[user][valId]) {
            // remove from user's list
            uint64[] storage list = userValidators[user];
            uint256 n = list.length;
            for (uint256 i = 0; i < n; i++) {
                if (list[i] == valId) {
                    list[i] = list[n - 1];
                    list.pop();
                    break;
                }
            }
            userHasValidator[user][valId] = false;
            // remove user from validator's list
            address[] storage vUsers = validatorUsers[valId];
            uint256 uv = vUsers.length;
            for (uint256 i2 = 0; i2 < uv; i2++) {
                if (vUsers[i2] == user) {
                    vUsers[i2] = vUsers[uv - 1];
                    vUsers.pop();
                    break;
                }
            }
            validatorHasUser[valId][user] = false;
        }
        emit PositionUpdated(user, valId, amount, false);
        // check if we can complete undelegation now (free wid) and if so complete
        _completeUndelegation(valId);
    }

    function _completeUndelegation(uint64 valId) internal {
        uint256 sum = queuedAmountByValidator[valId];
        if (sum == 0) return;
        // allocate wid
        uint8 wid;
        bool found = false;
        uint8 start = _nextWithdrawalId[valId];
        for (uint16 k = 0; k < 256; k++) {
            uint8 cand = uint8(uint16(start) + k);
            if (cand == ADMIN_WID_REBALANCE) continue;
            (bool exists,,,) = _getWithdrawalRequest(valId, address(this), cand);
            if (!exists) {
                wid = cand;
                _nextWithdrawalId[valId] = uint8(uint16(cand) + 1);
                found = true;
                break;
            }
        }
        if (!found) return;
        uint256 available = _getDelegatorStake(valId, address(this));
        // CHECK: when would sum > available occur and how to ahndle this correctly
        if (available == 0 || sum > available) return; // wait until capacity exists
        _undelegate(valId, sum, wid);
        pendingTotalByValidator[valId] += sum;
        queuedAmountByValidator[valId] = 0;

        // loop through queueTxUserAddress
        // for each user, set queuedUserAmount to 0
        for (uint256 i = 0; i < queueTxUserAddress[valId].length; i++) {
            queuedUserAmount[valId][queueTxUserAddress[valId][i]] = 0;
        }

        // store wid for convenience
        pendingValidatorWithdrawalId[valId] = wid;

        // set pendingUserAddress and pendingUserAmount to equal queueTxUserAddress and queueTxUserAmount
        // reset queueTxUserAddress and queueTxUserAmount
        pendingUserAddress[valId][wid] = queueTxUserAddress[valId];
        pendingUserAmount[valId][wid] = queueTxUserAmount[valId];
        delete queueTxUserAddress[valId];
        delete queueTxUserAmount[valId];
    }

    // Keeper-friendly processing: submit accrued undelegation for a validator when a slot is free
    function processPending(uint64 valId) external {
        _completeUndelegation(valId);
    }

    function _completeWithdrawalForValidator(uint64 valId, uint8 wid) internal {
        if (wid == 0) {
            wid = pendingValidatorWithdrawalId[valId];
        }

        (bool exists, uint256 amt,,) = _getWithdrawalRequest(valId, address(this), wid);

        if (exists && amt > 0) {
            if (_tryWithdraw(valId, uint8(wid))) {
                //now we need to distribute thw withdrawals to users
                address[] storage users = pendingUserAddress[valId][wid];
                uint256[] storage amounts = pendingUserAmount[valId][wid];
                uint256 n = users.length;
                if (n == 0 || amt == 0) return;

                uint256 remaining = amt;
                uint256 totalDue = 0;
                uint256 totalDistributed = 0;

                // Distribute funds to users in order, up to the withdrawn amount.
                for (uint256 i = 0; i < n && remaining > 0; i++) {
                    address u = users[i];
                    uint256 due = amounts[i];
                    totalDue += due;
                    if (due == 0 || u == address(0)) continue;

                    if (due > remaining) {
                        emit WithdrawalAmountMismatch(valId, wid, totalDue, totalDistributed, due, u);
                        continue;
                    }

                    // Send funds to user
                    (bool ok,) = u.call{value: due}("");

                    if (!ok) {
                        emit WithdrawalPaymentFailed(valId, wid, u, due);
                    } else {
                        totalDistributed += due;
                        emit WithdrawalPaymentSuccess(valId, wid, u, due);
                    }

                    remaining -= due;
                }

                pendingTotalByValidator[valId] = 0;
                delete pendingUserAddress[valId][wid];
                delete pendingUserAmount[valId][wid];
                pendingValidatorWithdrawalId[valId] = 0;
            } else {
                emit WithdrawalFailed(valId, wid);
            }
        }
    }

    function completeWithdrawalForValidator(uint64 valId, uint8 wid) external {
        _completeWithdrawalForValidator(valId, wid);
    }

    // Admin: initiate undelegation across all validators by basis points
    // This function is used when liquidity for CoreVault is depleted. Similar functionality exists in Lido v3.
    function adminInitiateRebalanceBps(uint16 bps) external onlyMagmaAdmin {
        if (!finishedLastRebalance) revert ErrRebalanceInProgress();
        if (epochSeconds != 0) {
            if (block.timestamp < lastRebalanceTimestamp + epochSeconds) {
                revert ErrEpochGuard();
            }
        }
        if (bps > 10_000) revert ErrInvalidBps();
        uint64[] memory list = whitelistedValidators;
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            uint64 v = list[i];
            // Decode vault-level delegation from precompile
            uint256 amt = _getDelegatorStake(v, address(this));
            uint256 pull = (amt * bps) / 10_000;
            if (pull > 0) {
                uint8 wid = ADMIN_WID_REBALANCE;
                _undelegate(v, pull, wid);
            }
        }
        emit AdminInitiatedRebalance(bps);
        lastRebalanceTimestamp = block.timestamp;
    }

    // Admin: complete matured rebalancewithdrawals and forward to Magma
    function adminCompleteRebalance() public onlyMagmaAdmin {
        uint64[] memory list = whitelistedValidators;
        uint256 beforeBal = address(this).balance;
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            uint64 valId = list[i];

            (bool exists, uint256 amt,,) = _getWithdrawalRequest(valId, address(this), ADMIN_WID_REBALANCE);
            if (!exists || amt == 0) continue;
            if (_tryWithdraw(valId, ADMIN_WID_REBALANCE)) {
                emit AdminCompletedRebalanceWithdrawal(valId, amt);
            }
        }
        uint256 delta = address(this).balance - beforeBal;
        if (delta > 0) {
            (bool sent,) = address(magma).call{value: delta}(abi.encodeWithSignature("onRebalanceFundsReceived()"));
            if (!sent) revert ErrForwardFailed();
        }
        emit AdminCompletedRebalance(delta);
    }

    // Allocate a free withdrawal id in range 0..255 for given validator id (skips admin-only ids)
    function _allocateWithdrawalId(uint64 valId) internal returns (uint8 wid) {
        uint8 start = _nextWithdrawalId[valId];
        for (uint16 i = 0; i < 256; i++) {
            uint8 candidate = uint8(uint16(start) + i);
            if (candidate == ADMIN_WID_REBALANCE) continue; // skip reserved
            (bool exists,,,) = _getWithdrawalRequest(valId, address(this), candidate);
            if (!exists) {
                wid = candidate;
                _nextWithdrawalId[valId] = uint8(uint16(candidate) + 1);
                return wid;
            }
        }
        revert("gVault: no free withdrawal id");
    }

    // Helpers for reading user positions
    function getUserValidators(address user) external view returns (uint64[] memory) {
        return userValidators[user];
    }

    function getUserPositions(address user)
        external
        view
        returns (uint64[] memory validators, uint256[] memory amounts)
    {
        uint64[] memory list = userValidators[user];
        uint256 n = list.length;
        validators = new uint64[](n);
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint64 v = list[i];
            validators[i] = v;
            amounts[i] = delegatedAmountOf[user][v];
        }
    }

    function _authorizeUpgrade(address) internal override {
        if (msg.sender != magma.admin()) revert ErrNotAdmin();
    }

    uint256[50] private __gap;
}
