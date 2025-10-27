// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMagma} from "../interfaces/IMagma.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {MagmaDelegationModule} from "./MagmaDelegationModule.sol";
import {DelInfo} from "./MagmaDelegationModule.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {BitMapLib} from "./utils/BitMapLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ErrNotMagma,
    ErrInvalidAmount,
    ErrInvalidStatus,
    ErrNoPendingWithdrawRequest,
    ErrPendingStakeNotZero,
    ErrZeroValidatorId,
    ErrAlreadyWhitelisted,
    ErrNativeTransferFailed,
    ErrAdminWidInUse,
    ErrNotWhitelisted,
    ErrRewardsClaimOverdue
} from "./MagmaErrorsModule.sol";

abstract contract BaseVault is MagmaDelegationModule, IBaseVault, PausableUpgradeable {
    using BitMapLib for BitMapLib.WithdrawalBitMap;

    /// @custom:storage-location erc7201:storage.BaseVault
    struct BaseVaultStorage {
        IMagma _magma;
        /// @dev Minimum amount users can withdraw in a single transaction (prevents dust attacks)
        uint256 _minUserWithdrawAmount;
        /// @dev Total pending redelegation across all validators
        uint256 _totalPendingRedelegation;
        /// @dev Total pending user withdrawals across all validators
        uint256 _totalPendingUndelegations;
        /// @dev Timestamp when cached delegator info was last updated
        uint256 _lastDelegatorInfoUpdateTimestamp;
        /// @dev How often cached delegator info can be refreshed (default: 1 hour)
        uint256 _delegatorInfoUpdateInterval;
        /// @dev Cached total assets across all validators (from last cache update)
        uint256 _cachedTotalAssets;
        /// @dev Net pending delegations since last cache update (positive = more delegations, negative = more undelegations)
        int256 _cachedTotalNetPendingDelegations;
        /// @dev Duration in seconds between allowed rebalance operations (0 = no time restriction)
        uint256 _epochSeconds;
        /// @dev Timestamp of the last rebalance operation, used for epoch guard timing
        uint256 _lastRebalanceTimestamp;
        /// @dev Flag indicating if the last rebalance operation has completed both phases
        bool _finishedLastRebalance;
        /// @dev Per-validator withdrawal ID bitmap management (tracks IDs 0-254 for users, 255 for admin)
        mapping(uint64 valId => BitMapLib.WithdrawalBitMap) _withdrawalIdBitmaps;
        /// @dev Tracks which validators are currently whitelisted for delegation
        mapping(uint64 valId => bool) _isWhitelisted;
        /// @dev Pending redelegation amounts per validator (used for admin operations like rebalancing)
        /// Only one admin redelegation can be pending per validator at a time
        mapping(uint64 valId => uint256 amount) _pendingRedelegateByValidator;
        /// @dev Pending user withdrawal amounts per validator (sum of all user withdrawal requests)
        mapping(uint64 valId => uint256 amount) _pendingUndelegateByValidator;
        /// @dev Cached delegator info from precompile to reduce gas costs and improve performance
        mapping(uint64 valId => DelInfo delInfo) _cachedDelegatorInfo;
        /// @dev Current status of each validator in the removal process lifecycle
        mapping(uint64 => ValidatorStatus) _validatorStatus;
        /// @dev Storage for user withdrawal requests: each user can have multiple pending withdrawals
        mapping(address => WithdrawalRequestInfo[]) _userWithdrawalRequests;
        /// @dev Active validator list (validators available for delegation)
        uint64[] _validators;
        /// @dev Maximum delay allowed between reward claims (default: 1 week)
        uint256 _maxRewardsClaimDelay;
        /// @dev Timestamp when rewards were last claimed from all validators
        uint256 _lastRewardsClaimTimestamp;
    }

    /// @dev Structure to track individual user withdrawal requests
    struct WithdrawalRequestInfo {
        uint256 amount; // Amount requested for withdrawal
        uint64 validator; // Validator from which to withdraw
        uint8 withdrawalId; // Unique withdrawal ID for tracking
    }

    /// @dev Reserved withdrawal ID for administrative operations (validator removal, rebalancing)
    uint8 internal constant ADMIN_WID = 255;
    /// @dev Basis points constant for percentage calculations (10,000 = 100%)
    uint256 internal constant BASE_BPS = 10_000;
    /// @dev Default maximum delay for reward claims (1 week)
    uint256 internal constant DEFAULT_MAX_REWARDS_CLAIM_DELAY = 7 days;

    // keccak256(abi.encode(uint256(keccak256("storage.BaseVault")) - 1)) & ~bytes32(uint256(0xff))
    /* solhint-disable-next-line const-name-snakecase */
    bytes32 private constant _BaseVaultStorageLocation =
        0x4f82f267b617ee475e66ea06cc7da3f52fc18aa1c88187614ba098035f896e00;

    modifier onlyOwner() {
        if (msg.sender != _getBaseVaultStorage()._magma.owner()) {
            revert Ownable.OwnableUnauthorizedAccount(_msgSender());
        }
        _;
    }

    modifier onlyMagma() {
        if (msg.sender != address(_getBaseVaultStorage()._magma)) revert ErrNotMagma();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the BaseVault contract with Magma protocol reference
     * @dev Sets the Magma protocol contract address for vault operations
     * @param _magma The address of the Magma protocol contract
     * @param _epochSeconds The duration of each epoch in seconds (0 disables epoch guard)
     */
    /* solhint-disable-next-line func-name-mixedcase */
    function __BaseVault_init(address _magma, uint256 _epochSeconds) internal onlyInitializing {
        __Pausable_init();
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        $._magma = IMagma(_magma);
        $._delegatorInfoUpdateInterval = 1 hours;
        $._epochSeconds = _epochSeconds;
        $._finishedLastRebalance = true;
        $._maxRewardsClaimDelay = DEFAULT_MAX_REWARDS_CLAIM_DELAY;
        $._lastRewardsClaimTimestamp = block.timestamp; // Initialize to current time
    }

    receive() external payable {}

    function _getBaseVaultStorage() private pure returns (BaseVaultStorage storage $) {
        assembly {
            $.slot := _BaseVaultStorageLocation
        }
    }

    /**
     * @notice Pause all vault operations
     * @dev Emergency function to halt deposits, withdrawals, and delegations. Only callable by admin
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Resume all vault operations
     * @dev Removes emergency pause from deposits, withdrawals, and delegations. Only callable by admin
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    function isWhitelisted(uint64 valId) public view returns (bool) {
        return _getBaseVaultStorage()._isWhitelisted[valId];
    }

    function magma() public view returns (IMagma) {
        return _getBaseVaultStorage()._magma;
    }

    function totalPendingUndelegations() public view returns (uint256) {
        return _getBaseVaultStorage()._totalPendingUndelegations;
    }

    function setTotalPendingUndelegations(uint256 _totalPendingUndelegations) internal {
        _getBaseVaultStorage()._totalPendingUndelegations = _totalPendingUndelegations;
    }

    function totalPendingRedelegation() public view returns (uint256) {
        return _getBaseVaultStorage()._totalPendingRedelegation;
    }

    function setTotalPendingRedelegation(uint256 _totalPendingRedelegation) internal {
        _getBaseVaultStorage()._totalPendingRedelegation = _totalPendingRedelegation;
    }

    function minUserWithdrawAmount() public view returns (uint256) {
        return _getBaseVaultStorage()._minUserWithdrawAmount;
    }

    function lastDelegatorInfoUpdateTimestamp() external view returns (uint256) {
        return _getBaseVaultStorage()._lastDelegatorInfoUpdateTimestamp;
    }

    function delegatorInfoUpdateInterval() external view returns (uint256) {
        return _getBaseVaultStorage()._delegatorInfoUpdateInterval;
    }

    function cachedTotalAssets() external view returns (uint256) {
        return _getBaseVaultStorage()._cachedTotalAssets;
    }

    function cachedTotalNetPendingDelegations() external view returns (int256) {
        return _getBaseVaultStorage()._cachedTotalNetPendingDelegations;
    }

    function epochSeconds() public view override returns (uint256) {
        return _getBaseVaultStorage()._epochSeconds;
    }

    function lastRebalanceTimestamp() public view override returns (uint256) {
        return _getBaseVaultStorage()._lastRebalanceTimestamp;
    }

    function finishedLastRebalance() public view override returns (bool) {
        return _getBaseVaultStorage()._finishedLastRebalance;
    }

    function setLastRebalanceTimestamp(uint256 _lastRebalanceTimestamp) internal {
        _getBaseVaultStorage()._lastRebalanceTimestamp = _lastRebalanceTimestamp;
    }

    function setFinishedLastRebalance(bool _finishedLastRebalance) internal {
        _getBaseVaultStorage()._finishedLastRebalance = _finishedLastRebalance;
    }

    function pendingRedelegateByValidator(uint64 valId) public view returns (uint256) {
        return _getBaseVaultStorage()._pendingRedelegateByValidator[valId];
    }

    function setPendingRedelegateByValidator(uint64 valId, uint256 amount) internal {
        _getBaseVaultStorage()._pendingRedelegateByValidator[valId] = amount;
    }

    function pendingUndelegateByValidator(uint64 valId) public view returns (uint256) {
        return _getBaseVaultStorage()._pendingUndelegateByValidator[valId];
    }

    function setPendingUndelegateByValidator(uint64 valId, uint256 amount) internal {
        _getBaseVaultStorage()._pendingUndelegateByValidator[valId] = amount;
    }

    function cachedDelegatorInfo(uint64 valId) public view returns (DelInfo memory) {
        return _getBaseVaultStorage()._cachedDelegatorInfo[valId];
    }

    function validatorStatus(uint64 valId) public view returns (ValidatorStatus) {
        return _getBaseVaultStorage()._validatorStatus[valId];
    }

    function userWithdrawalRequests(address user) public view returns (WithdrawalRequestInfo[] memory) {
        return _getBaseVaultStorage()._userWithdrawalRequests[user];
    }

    function validators(uint256 index) external view returns (uint64) {
        return _getBaseVaultStorage()._validators[index];
    }

    function getValidators() public view virtual returns (uint64[] memory) {
        return _getBaseVaultStorage()._validators;
    }

    function validatorsLength() public view returns (uint256) {
        return _getBaseVaultStorage()._validators.length;
    }

    /**
     * @notice Remove validator ID from storage array
     * @dev Efficiently removes validator by swapping with last element
     * @param valId The validator ID to remove
     */
    function _removeValidatorFromArray(uint64 valId) internal {
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        for (uint256 i = 0; i < $._validators.length; ++i) {
            if ($._validators[i] == valId) {
                $._validators[i] = $._validators[$._validators.length - 1];
                $._validators.pop();
                break;
            }
        }
    }

    /**
     * @dev Cache validator statistics from precompile to improve gas efficiency
     * @notice This function fetches fresh data from the staking precompile for all validators
     *         and stores it locally to avoid expensive precompile calls during normal operations
     */
    function _cacheValidatorStats() internal {
        uint256 _cachedTotalAssets = 0;
        BaseVaultStorage storage $ = _getBaseVaultStorage();

        // Fetch and cache delegator info for each active validator
        uint64[] memory _validators = getValidators();
        for (uint256 _i = 0; _i < _validators.length; ++_i) {
            uint64 _valId = _validators[_i];
            DelInfo memory _delInfo = _getDelegatorInfo(_valId, address(this)); // Expensive precompile call
            $._cachedDelegatorInfo[_valId] = _delInfo;
            // Sum total assets: active stake + pending stake changes
            _cachedTotalAssets += _delInfo.stake + _delInfo.deltaStake + _delInfo.nextDeltaStake;
        }

        // Reset pending delta tracking since we just refreshed from source of truth
        $._cachedTotalNetPendingDelegations = 0;
        $._cachedTotalAssets = _cachedTotalAssets;
    }

    /**
     * @notice Get total assets under management including pending operations
     * @dev Calculates total stake across all validators plus pending redelegations
     * @return Total assets in wei (active stake + pending redelegation amounts)
     */
    function totalAssets() external view returns (uint256) {
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        return uint256(int256($._cachedTotalAssets + $._totalPendingRedelegation) + $._cachedTotalNetPendingDelegations);
    }

    /**
     * @notice Conditionally refresh cache if enough time has passed
     * @dev Only refreshes if more than delegatorInfoUpdateInterval has passed since last update
     */
    function refreshCacheCheck() external {
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        if (
            block.timestamp - $._lastDelegatorInfoUpdateTimestamp > $._delegatorInfoUpdateInterval
                || $._lastDelegatorInfoUpdateTimestamp == 0
        ) {
            _refreshCache();
        }
    }

    /**
     * @notice Force refresh the validator cache immediately
     * @dev Bypasses time interval check and updates cache with fresh precompile data
     */
    function refreshCache() external {
        _refreshCache();
    }

    /**
     * @dev Internal function to refresh cached validator statistics
     * @notice Updates cached data and sets new timestamp
     */
    function _refreshCache() internal {
        _cacheValidatorStats();
        _getBaseVaultStorage()._lastDelegatorInfoUpdateTimestamp = block.timestamp;
    }

    /**
     * @notice Set the minimum withdrawal amount for users
     * @dev Updates the minimum amount users can withdraw in a single transaction
     * @param _amount The minimum withdrawal amount in wei (must be less than 10,000 ether)
     */
    function setMinUserWithdrawAmount(uint256 _amount) external onlyOwner {
        if (_amount >= 10000 ether) revert ErrInvalidAmount(_amount);
        _getBaseVaultStorage()._minUserWithdrawAmount = _amount;
        emit MinUserWithdrawAmountUpdated(_amount);
    }

    /**
     * @notice Set the delegator info cache update interval
     * @dev Updates how often the cached delegator info can be refreshed
     * @param _interval The cache update interval in seconds (must be between 1 minute and 24 hours)
     */
    function setDelegatorInfoUpdateInterval(uint256 _interval) external onlyOwner {
        if (_interval < 1 minutes || _interval > 24 hours) revert ErrInvalidAmount(_interval);
        _getBaseVaultStorage()._delegatorInfoUpdateInterval = _interval;
        emit DelegatorInfoUpdateIntervalChanged(_interval);
    }

    function setEpochSeconds(uint256 _epochSeconds) external onlyOwner {
        _getBaseVaultStorage()._epochSeconds = _epochSeconds;
        emit EpochSecondsUpdated(_epochSeconds);
    }

    /**
     * @notice Get the timestamp of the last reward claim
     * @dev Returns when rewards were last claimed from all validators
     * @return The timestamp of the last reward claim
     */
    function lastRewardsClaimTimestamp() external view virtual returns (uint256) {
        return _getBaseVaultStorage()._lastRewardsClaimTimestamp;
    }

    /**
     * @notice Get the maximum delay allowed between reward claims
     * @dev Returns the maximum time allowed between reward claims
     * @return The maximum delay in seconds
     */
    function maxRewardsClaimDelay() external view virtual returns (uint256) {
        return _getBaseVaultStorage()._maxRewardsClaimDelay;
    }

    /**
     * @notice Set the maximum delay allowed between reward claims
     * @dev Updates the maximum time allowed between reward claims (must be between 1 day and 30 days)
     * @param _delay The maximum delay in seconds
     */
    function setMaxRewardsClaimDelay(uint256 _delay) external virtual onlyOwner {
        _validateMaxRewardsClaimDelay(_delay);
        _getBaseVaultStorage()._maxRewardsClaimDelay = _delay;
        emit MaxRewardsClaimDelayUpdated(_delay);
    }

    /**
     * @notice Calculate and charge withdrawal fees
     * @dev Calculates withdrawal fee based on protocol fee rate and sends it to fee receiver
     * @param _totalWithdrawalAmount The total amount being withdrawn
     * @return The fee amount charged
     */
    function _chargeWithdrawalFee(uint256 _totalWithdrawalAmount) internal returns (uint256) {
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        if (_totalWithdrawalAmount == 0) return 0;
        if ($._magma.withdrawalFee() == 0) return 0;
        uint256 _fee = Math.mulDiv(_totalWithdrawalAmount, $._magma.withdrawalFee(), BASE_BPS, Math.Rounding.Ceil);
        if (_fee > 0) {
            (bool okFee,) = $._magma.feeReceiver().call{value: _fee}("");
            if (!okFee) {
                emit WithdrawalFeeTransferFailed(_fee);
            } else {
                emit WithdrawalFeeTransferSuccess(_fee, $._magma.feeReceiver());
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
        BaseVaultStorage storage $ = _getBaseVaultStorage();

        if ($._validatorStatus[_valId] != ValidatorStatus.UNDELEGATING) revert ErrInvalidStatus();

        // Check bitmap first - if ADMIN_WID is not in use, no pending withdrawal exists
        if (!$._withdrawalIdBitmaps[_valId].isWithdrawalIdInUse(ADMIN_WID)) {
            revert ErrNoPendingWithdrawRequest();
        }

        // Get the withdrawal amount before completing withdrawal
        (, uint256 _withdrawalAmount,,) = _getWithdrawalRequest(_valId, address(this), ADMIN_WID);
        if (!(_withdrawalAmount > 0)) revert ErrNoPendingWithdrawRequest();

        // Complete the withdrawal using the admin withdrawal ID
        $._totalPendingRedelegation -= $._pendingRedelegateByValidator[_valId];
        uint256 _beforeBal = address(this).balance;
        _completeRedelegationWithdrawal(_valId, ADMIN_WID);
        uint256 _delta = address(this).balance - _beforeBal;

        $._validatorStatus[_valId] = ValidatorStatus.REMOVED;
        emit ValidatorRemovalCompleted(_valId);

        return _delta;
    }

    /**
     * @notice Step 2: Remove validator from validators array this function forces all stake to be in an active state
     * @dev Remove validator from validators array
     * @param _valId The validator ID to remove
     */
    function _executeValidatorUndelegation(uint64 _valId) internal {
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        if ($._validatorStatus[_valId] != ValidatorStatus.PAUSED) revert ErrInvalidStatus();

        DelInfo memory _coreVaultDelInfo = _getDelegatorInfo(_valId, address(this));

        if (_coreVaultDelInfo.deltaStake > 0 || _coreVaultDelInfo.nextDeltaStake > 0) {
            revert ErrPendingStakeNotZero();
        }

        // Claim any accumulated rewards before removing validator
        if (_coreVaultDelInfo.rewards > 0) {
            _claimValidatorRewards(_valId);
        }

        uint256 _amountToRedelegate = _coreVaultDelInfo.stake;
        $._totalPendingRedelegation =
            $._totalPendingRedelegation - $._pendingRedelegateByValidator[_valId] + _amountToRedelegate;
        $._pendingRedelegateByValidator[_valId] = _amountToRedelegate;

        // Initiate undelegation of all remaining stake from this validator
        if (_amountToRedelegate > 0) {
            _checkFreeAdminWid(_valId); // Ensure admin withdrawal ID is available
            _allocateAdminWidAndUndelegate(_valId, _amountToRedelegate);
            // _trackCachedUndelegation(_amountToRedelegate) should not be called since we are already accounting _totalPendingRedelegation.
            $._validatorStatus[_valId] = ValidatorStatus.UNDELEGATING; // Move to final removal phase
            emit ValidatorRemoved(_valId);
        } else {
            // No stake to undelegate, validator removal is complete
            $._validatorStatus[_valId] = ValidatorStatus.REMOVED;
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
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        if ($._isWhitelisted[_valId]) revert ErrAlreadyWhitelisted();

        $._validatorStatus[_valId] = ValidatorStatus.NONE;
        $._validators.push(_valId);
        $._isWhitelisted[_valId] = true;

        emit ValidatorAdded(_valId);
    }

    /**
     * @notice Initiate the removal process for a validator
     * @dev Pauses validator, removes from active list, and tracks pending redelegation
     * @param _valId The validator ID to remove
     */
    function _initiateValidatorRemoval(uint64 _valId) internal {
        _checkFreeAdminWid(_valId);
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        if (!$._isWhitelisted[_valId]) revert ErrNotWhitelisted();

        // Step 1: Pause validator to prevent new delegations
        $._validatorStatus[_valId] = ValidatorStatus.PAUSED;
        $._isWhitelisted[_valId] = false;
        _removeValidatorFromArray(_valId); // Remove from active validators list

        // Track the total stake that will need to be redelegated
        uint256 _totalStakedToValidator = _getTotalStakedToValidator(_valId);
        if (_totalStakedToValidator > 0) {
            // Reserve this amount for pending redelegation tracking
            $._pendingRedelegateByValidator[_valId] = _totalStakedToValidator;
            $._totalPendingRedelegation += _totalStakedToValidator;
            _trackCachedUndelegation(_totalStakedToValidator);
        }

        emit ValidatorRemovalInitiated(_valId);
    }

    /**
     * @notice Get total stake delegated to all validators
     * @dev Calculates sum of stakes across all active validators
     * @return Total staked amount in wei
     */
    function _getTotalStakedToAllValidators() internal returns (uint256) {
        uint256 _total = 0;
        uint64[] memory _validators = getValidators();
        for (uint256 _i = 0; _i < _validators.length; ++_i) {
            _total += _getTotalStakedToValidator(_validators[_i]);
        }
        return _total;
    }

    /**
     * @notice Get total active stake across all validators using cached data
     * @dev Sums cached stake data for all validators to avoid expensive precompile calls
     * @return Total active stake amount across all validators from cached data
     */
    function _getCachedTotalStakedToAllValidators() internal view returns (uint256) {
        uint256 _total = 0;
        uint64[] memory _validators = getValidators();
        for (uint256 _i = 0; _i < _validators.length; ++_i) {
            (uint256 _validatorStake,) = _getCachedTotalStakedToValidator(_validators[_i]);
            _total += _validatorStake;
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
    function _allocateWidAndUndelegate(uint64 _valId, uint256 _amount) internal returns (uint8 _wid) {
        _wid = _getBaseVaultStorage()._withdrawalIdBitmaps[_valId].allocateWithdrawalId();
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
    function _allocateAdminWidAndUndelegate(uint64 _valId, uint256 _amount) internal returns (uint8) {
        _getBaseVaultStorage()._withdrawalIdBitmaps[_valId].allocateAdminWid();
        _undelegate(_valId, _amount, ADMIN_WID);
        return ADMIN_WID;
    }

    /**
     * @dev Store withdrawal request information for tracking
     * @param _user The user making the withdrawal request
     * @param _amount The amount being withdrawn
     * @param _validator The validator from which to withdraw
     * @param _withdrawalId The withdrawal ID assigned
     */
    function _storeWithdrawalRequest(address _user, uint256 _amount, uint64 _validator, uint8 _withdrawalId) internal {
        _getBaseVaultStorage()._userWithdrawalRequests[_user].push(
            WithdrawalRequestInfo({amount: _amount, validator: _validator, withdrawalId: _withdrawalId})
        );
    }

    /**
     * @notice Get total active stake for a validator
     * @dev Returns current active stake plus pending stake changes
     * @param _valId The validator ID to query
     * @return Total active stake amount
     */
    function _getTotalStakedToValidator(uint64 _valId) internal returns (uint256) {
        DelInfo memory _delInfo = _getDelegatorInfo(_valId, address(this));
        return _delInfo.stake + _delInfo.deltaStake + _delInfo.nextDeltaStake;
    }

    /**
     * @notice Get total active stake for a validator using cached data
     * @dev Returns current active stake plus pending stake changes from cache
     * @param _valId The validator ID to query
     * @return Total active stake amount from cached data
     */
    function _getCachedTotalStakedToValidator(uint64 _valId) internal view returns (uint256, uint256) {
        DelInfo memory _delInfo = cachedDelegatorInfo(_valId);
        return (_delInfo.stake + _delInfo.deltaStake + _delInfo.nextDeltaStake, _delInfo.stake);
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
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        WithdrawalRequestInfo[] storage _userRequests = $._userWithdrawalRequests[_user];
        if (_userRequests.length == 0) revert ErrNoPendingWithdrawRequest();

        uint256 _totalSuccessfulWithdrawals = 0;

        // Process each withdrawal request for this user
        for (uint256 i = 0; i < _userRequests.length; ++i) {
            WithdrawalRequestInfo storage _request = _userRequests[i];
            uint64 _valId = _request.validator;
            uint8 _withdrawalId = _request.withdrawalId;
            uint256 _beforeBal = address(this).balance;

            // Execute withdrawal from staking precompile
            _withdraw(_valId, _withdrawalId);
            uint256 _delta = address(this).balance - _beforeBal;

            _totalSuccessfulWithdrawals += _delta;
            emit WithdrawalPaymentSuccess(_valId, _withdrawalId, _user, _delta);

            // Update pending undelegation tracking (handle potential underflow from slashing)
            if (pendingUndelegateByValidator(_valId) >= _delta) {
                setPendingUndelegateByValidator(_valId, pendingUndelegateByValidator(_valId) - _delta);
            } else {
                // Prevent underflow in case of additional rewards during withdrawal period.
                setPendingUndelegateByValidator(_valId, 0);
            }

            // Update global pending undelegations (handle potential underflow)
            $._totalPendingUndelegations =
                (_delta > $._totalPendingUndelegations) ? 0 : ($._totalPendingUndelegations - _delta);

            // Mark withdrawal ID as completed and available for reuse
            _markWithdrawalCompleted(_valId, _withdrawalId);
        }

        // Clear all withdrawal requests for this user after processing
        delete $._userWithdrawalRequests[_user];

        // Send all accumulated ETH to user in a single transaction (gas efficient)
        if (_totalSuccessfulWithdrawals > 0) {
            uint256 _fee = _chargeWithdrawalFee(_totalSuccessfulWithdrawals);
            uint256 _remaining = _totalSuccessfulWithdrawals - _fee;

            // Transfer remaining funds to Magma contract which will forward to user
            (bool success,) = address($._magma).call{value: _remaining}("");
            if (!success) {
                revert ErrNativeTransferFailed();
            }

            _totalWithdrawn = _totalSuccessfulWithdrawals;
            _totalWithdrawnAfterFee = _remaining;
        }

        emit UserWithdrawalCompleted(_user, _totalWithdrawnAfterFee);
    }

    function _completeRedelegationWithdrawal(uint64 _valId, uint8 _withdrawalId) internal {
        _withdraw(_valId, _withdrawalId);
        // Mark the withdrawal as completed in the bitmap
        _markWithdrawalCompleted(_valId, _withdrawalId);
        setPendingRedelegateByValidator(_valId, 0);
    }

    /**
     * @dev Mark a withdrawal ID as free in the bitmap when withdrawal is completed
     * @param _valId The validator ID
     * @param _withdrawalId The withdrawal ID to mark as free
     */
    function _markWithdrawalCompleted(uint64 _valId, uint8 _withdrawalId) internal {
        _getBaseVaultStorage()._withdrawalIdBitmaps[_valId].markWithdrawalCompleted(_withdrawalId);
    }

    /**
     * @notice Check if admin withdrawal ID is available
     * @dev Reverts if admin withdrawal ID is already in use
     * @param _valId The validator ID to check
     */
    function _checkFreeAdminWid(uint64 _valId) internal view {
        if (_getBaseVaultStorage()._withdrawalIdBitmaps[_valId].isWithdrawalIdInUse(ADMIN_WID)) {
            revert ErrAdminWidInUse();
        }
    }

    /**
     * @dev Claim rewards for a specific validator and distribute them
     * @param _valId The validator ID to claim rewards for
     */
    function _claimValidatorRewards(uint64 _valId) internal virtual {
        uint256 _balanceBefore = address(this).balance;

        // Try to claim rewards from the validator - if there are no rewards, this will fail gracefully
        _claim(_valId);

        uint256 _balanceAfter = address(this).balance;
        uint256 _rewardsClaimed = _balanceAfter - _balanceBefore;

        if (_rewardsClaimed > 0) {
            // Calculate and send fee to fee receiver
            uint256 _fee = _calculateRewardsFeeAndSend(_rewardsClaimed);

            uint256 _remaining = _rewardsClaimed - _fee;

            // Distribute remaining rewards using vault-specific strategy
            if (_remaining > 0) {
                _distributeClaimedRewardsFromRemoval(_remaining);
            }
        }
    }

    /**
     * @dev Distribute claimed rewards - default implementation forwards to CoreVault
     * @param _amount The amount of rewards to distribute
     */
    function _distributeClaimedRewardsFromRemoval(uint256 _amount) internal virtual {
        ICoreVault _coreVault = ICoreVault(_getBaseVaultStorage()._magma.coreVault());
        // Call delegate function on CoreVault to distribute to remaining validators
        _coreVault.delegate{value: _amount}();
    }

    /**
     * @notice Calculate rewards fee and send to fee receiver
     * @dev Calculates protocol rewards fee and transfers it to the designated receiver
     * @param _totalRewards The total rewards amount to calculate fee from
     * @return _fee The fee amount calculated and sent
     */
    function _calculateRewardsFeeAndSend(uint256 _totalRewards) internal returns (uint256 _fee) {
        BaseVaultStorage storage $ = _getBaseVaultStorage();

        _fee = Math.mulDiv(_totalRewards, $._magma.rewardsFee(), BASE_BPS, Math.Rounding.Ceil);
        if (_fee > 0) {
            // send fee to fee receiver
            (bool _ok,) = $._magma.feeReceiver().call{value: _fee}("");
            if (!_ok) {
                emit RewardsFeeTransferFailed(_fee);
                return 0;
            } else {
                emit RewardsFeeTransferSuccess(_fee, $._magma.feeReceiver());
            }
        }
        return _fee;
    }

    /**
     * @dev Track delegation operations in cache to maintain accurate totalAssets calculation
     * @param _amount Amount being delegated
     */
    function _trackCachedDelegation(uint256 _amount) internal {
        _getBaseVaultStorage()._cachedTotalNetPendingDelegations += int256(_amount);
    }

    /**
     * @dev Track undelegation operations in cache to maintain accurate totalAssets calculation
     * @param _amount Amount being undelegated
     */
    function _trackCachedUndelegation(uint256 _amount) internal {
        _getBaseVaultStorage()._cachedTotalNetPendingDelegations -= int256(_amount);
    }

    /**
     * @dev Check if rewards need to be claimed based on the maximum delay
     * @notice Reverts if rewards haven't been claimed within the maximum allowed delay
     */
    function _checkRewardsClaimDelay() internal view virtual {
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        if (block.timestamp - $._lastRewardsClaimTimestamp > $._maxRewardsClaimDelay) {
            revert ErrRewardsClaimOverdue();
        }
    }

    /**
     * @dev Update the last rewards claim timestamp
     * @notice Should be called whenever rewards are claimed from all validators
     */
    function _updateLastRewardsClaimTimestamp() internal virtual {
        _getBaseVaultStorage()._lastRewardsClaimTimestamp = block.timestamp;
    }

    /**
     * @dev Validate the maximum rewards claim delay parameter
     * @notice Shared validation logic for both vault types
     * @param _delay The delay to validate (must be between 1 day and 30 days)
     */
    function _validateMaxRewardsClaimDelay(uint256 _delay) internal pure {
        if (_delay < 1 days || _delay > 30 days) revert ErrInvalidAmount(_delay);
    }

    /**
     * @dev Check if a withdrawal ID is in use for a validator
     * @param _valId The validator ID
     * @param _withdrawalId The withdrawal ID to check
     * @return true if the withdrawal ID is in use, false otherwise
     */
    function _isWithdrawalIdInUse(uint64 _valId, uint8 _withdrawalId) internal view returns (bool) {
        return _getBaseVaultStorage()._withdrawalIdBitmaps[_valId].isWithdrawalIdInUse(_withdrawalId);
    }
}
