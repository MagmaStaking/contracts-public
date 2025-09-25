// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {DelInfo} from "./MagmaDelegationModule.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {BitMapLib} from "./utils/BitMapLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VaultBase} from "./VaultBase.sol";

import {
    ErrEpochGuard,
    ErrMaxValidators,
    ErrRebalanceInProgress,
    ErrNotEnoughValidators,
    ErrNotMagma,
    ErrBelowMinWithdraw,
    ErrNoValidators,
    ErrExistingWithdrawalInProgress,
    ErrInsufficientDelegated,
    ErrZeroAmount,
    ErrInvalidAmount,
    ErrNotAdmin
} from "./MagmaErrorsModule.sol";

contract CoreVault is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ICoreVault,
    VaultBase
{
    using BitMapLib for BitMapLib.WithdrawalBitMap;

    /// @custom:storage-location erc7201:storage.CoreVault
    struct CoreVaultStorage {
        /// @dev Duration in seconds between allowed rebalance operations (0 = no time restriction)
        uint256 _epochSeconds;
        /// @dev Timestamp of the last rebalance operation, used for epoch guard timing
        uint256 _lastRebalanceTimestamp;
        /// @dev Flag indicating if the last rebalance operation has completed both phases
        bool _finishedLastRebalance;
        /// @dev Maximum number of validators that can be added in a single batch to prevent gas limit issues
        uint64 _maxValidatorPerBatch;
    }

    /// @dev Struct to hold validator ID and associated amount for sorting operations
    struct ValidatorAmount {
        uint64 valId; // Validator identifier
        uint256 amount; // Stake amount associated with this validator
    }

    // keccak256(abi.encode(uint256(keccak256("storage.CoreVault")) - 1)) & ~bytes32(uint256(0xff))
    /* solhint-disable-next-line const-name-snakecase */
    bytes32 private constant _CoreVaultStorageLocation =
        0x52cc5b10e48806cc3038884ee015a89dc6583650d30099489137fff04e064c00;

    // whenNotPaused modifier is now inherited from PausableUpgradeable
    modifier onlyAfterEpoch() {
        CoreVaultStorage storage $ = _getCoreVaultStorage();
        if ($._epochSeconds != 0) {
            if (block.timestamp < $._lastRebalanceTimestamp + $._epochSeconds) {
                revert ErrEpochGuard();
            }
        }
        _;
    }

    /**
     * @notice Initialize the CoreVault contract with configuration parameters
     * @dev Sets up the vault with Magma protocol address and epoch timing configuration
     * @param _magma The address of the Magma protocol contract
     * @param _epochSeconds The duration of each epoch in seconds (0 disables epoch guard)
     * @param maxValidatorPerBatch_ The maximum number of validators that can be added in a single batch
     */
    function initialize(address _magma, uint256 _epochSeconds, uint64 maxValidatorPerBatch_) external initializer {
        __ReentrancyGuard_init();
        __Pausable_init();
        __VaultBase_init(_magma);
        CoreVaultStorage storage $ = _getCoreVaultStorage();
        $._epochSeconds = _epochSeconds;
        $._finishedLastRebalance = true;
        $._maxValidatorPerBatch = maxValidatorPerBatch_;
    }

    // Accept native funds returned from precompile withdrawals
    receive() external payable {}

    function _getCoreVaultStorage() private pure returns (CoreVaultStorage storage $) {
        assembly {
            $.slot := _CoreVaultStorageLocation
        }
    }

    function epochSeconds() external view returns (uint256) {
        return _getCoreVaultStorage()._epochSeconds;
    }

    function lastRebalanceTimestamp() external view returns (uint256) {
        return _getCoreVaultStorage()._lastRebalanceTimestamp;
    }

    function finishedLastRebalance() external view returns (bool) {
        return _getCoreVaultStorage()._finishedLastRebalance;
    }

    /**
     * @dev Override to resolve interface conflict with OpenZeppelin's PausableUpgradeable
     */
    function paused() public view override(ICoreVault, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    /**
     * @notice Pause all vault operations
     * @dev Emergency function to halt deposits, withdrawals, and delegations. Only callable by admin
     */
    function pause() external onlyAdmin {
        _pause();
    }

    /**
     * @notice Resume all vault operations
     * @dev Removes emergency pause from deposits, withdrawals, and delegations. Only callable by admin
     */
    function unpause() external onlyAdmin {
        _unpause();
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
        _registerValidator(_valId);
        _redelegateInitiate();
    }

    /**
     * @notice Add multiple validators and initiate rebalancing phase 1 (undelegation)
     * @dev Batch add validators with gas limit protection, then trigger rebalancing
     * @param validators Array of validator IDs to add (limited by _maxValidatorPerBatch)
     */
    function addValidators(uint64[] memory validators) external onlyAdmin onlyAfterEpoch {
        CoreVaultStorage storage $ = _getCoreVaultStorage();
        if (validators.length > $._maxValidatorPerBatch) revert ErrMaxValidators($._maxValidatorPerBatch);

        for (uint256 i = 0; i < validators.length; ++i) {
            _registerValidator(validators[i]);
        }
        _redelegateInitiate();
    }

    /**
     * @notice Phase 1: Initiate manual rebalancing by undelegating excess from over-target validators
     * @dev Starts the two-phase rebalancing process. Must be followed by redelegateToValidators()
     *      to complete the redistribution. Prevents concurrent rebalances.
     */
    function adminRebalanceInitiate() external onlyAdmin onlyAfterEpoch {
        CoreVaultStorage storage $ = _getCoreVaultStorage();
        if (!$._finishedLastRebalance) revert ErrRebalanceInProgress();
        $._finishedLastRebalance = false;
        _redelegateInitiate();
        $._lastRebalanceTimestamp = block.timestamp;
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
        _initiateValidatorRemoval(_valId);
    }

    /**
     * @notice Step 2: Remove validator from validators array this function forces all stake to be in an active state
     * @dev Remove validator from validators array
     * @param _valId The validator ID to remove
     */
    function executeValidatorUndelegation(uint64 _valId) external onlyAdmin {
        _executeValidatorUndelegation(_valId);
    }

    /**
     * @dev Complete the withdrawal process for a removed validator
     * This should be called after the WITHDRAWAL_DELAY period has passed
     * @param _valId The validator ID that was removed
     */
    function completeValidatorRemovalWithdrawal(uint64 _valId) external onlyAdmin {
        uint256 _withdrawalAmount = _completeValidatorRemovalWithdrawal(_valId);
        // Distribute the recovered funds to remaining validators
        if (_withdrawalAmount > 0) {
            _distributeAmountEquallyToValidators(_withdrawalAmount);
        }
    }

    // --------------------------------------------------------------------------------------------------------------
    // Delegation functions
    // --------------------------------------------------------------------------------------------------------------

    /**
     * @notice Delegate native MON to validators equally
     * @dev Distributes the sent MON equally among all registered validators.
     *      Only callable by Magma protocol or gVault contract.
     */
    function delegate() external payable whenNotPaused {
        if (msg.sender != address(magma()) && msg.sender != magma().gVault()) {
            revert ErrNotMagma();
        }
        _distributeAmountEquallyToValidators(msg.value);
    }

    /**
     * @notice Initiate undelegation of specified amount for a user
     * @dev Creates withdrawal requests by undelegating from validators with highest stake first.
     *      Enforces minimum withdrawal amount and prevents multiple concurrent withdrawals per user.
     * @param _amount The amount of ETH to undelegate
     * @param _user The user address requesting the withdrawal
     */
    function undelegate(uint256 _amount, address _user) external onlyMagma whenNotPaused {
        if (_amount < minUserWithdrawAmount()) {
            revert ErrBelowMinWithdraw(minUserWithdrawAmount());
        }
        if (validators.length == 0) revert ErrNoValidators();

        // only one withdrawal per user
        if (userWithdrawalRequests(_user).length > 0) revert ErrExistingWithdrawalInProgress();

        // Get validators sorted by stake (highest first) and total stake in one go
        (ValidatorAmount[] memory _sortedValidators, uint256 _totalActiveStake) =
            _getSortedValidatorsByActiveStakeDescendingWithTotal();

        uint256 _remainingAmount = _amount;
        uint256 _onetwentiethThreshold = _totalActiveStake / 20; // 1/20th of total active stake across all validators

        for (uint256 _i = 0; _i < _sortedValidators.length && _remainingAmount > 0; ++_i) {
            uint64 _valId = _sortedValidators[_i].valId;
            uint256 _availableStake = _sortedValidators[_i].amount; // Use stake from sorted array

            if (_availableStake == 0) continue;

            // Check if request exceeds 1/20th of total active stake to prevent large withdrawals from single validator
            uint256 _maxAllowedFromValidator =
                _remainingAmount > _onetwentiethThreshold ? _onetwentiethThreshold : _remainingAmount;

            // Calculate amount to withdraw from this validator (min of needed, allowed, and available)
            uint256 _amountFromValidator = _remainingAmount;
            if (_amountFromValidator > _maxAllowedFromValidator) {
                _amountFromValidator = _maxAllowedFromValidator; // Respect the 5% limit per validator
            }
            if (_amountFromValidator > _availableStake) {
                _amountFromValidator = _availableStake; // Can't withdraw more than what's staked
            }

            if (_amountFromValidator > 0) {
                uint8 _wid = _allocateWIDandUndelegate(_valId, _amountFromValidator);

                // Store withdrawal request information
                _storeWithdrawalRequest(_user, _amountFromValidator, _valId, _wid);

                // Track pending; do not lower local delegated until completion
                setPendingUndelegateByValidator(_valId, pendingUndelegateByValidator(_valId) + _amountFromValidator);
                _remainingAmount -= _amountFromValidator;
            }
        }

        setTotalPendingUndelegations(totalPendingUndelegations() + _amount);
        _trackCachedUndelegation(_amount);

        // If we couldn't fulfill the full amount, revert
        if (_remainingAmount > 0) {
            revert ErrInsufficientDelegated(_amount, _amount - _remainingAmount);
        }
    }

    /**
     * @notice Complete withdrawal for a specific user's undelegation requests
     * @dev Processes all withdrawal requests for the user and returns total amount distributed
     * @param _user The user whose withdrawal requests to complete
     * @return _totalWithdrawn The actual amount successfully withdrawn and sent to the user
     * @return _totalWithdrawnAfterFee The amount withdrawn after applying withdrawal fees
     */
    function completeUserWithdrawal(address _user)
        external
        nonReentrant
        onlyMagma
        returns (uint256 _totalWithdrawn, uint256 _totalWithdrawnAfterFee)
    {
        return _completeUserWithdrawal(_user);
    }

    /**
     * @notice Get all registered validator IDs
     * @dev Returns array of validator IDs currently registered in the vault
     * @return Array of validator IDs
     */
    function getValidators() external view returns (uint64[] memory) {
        return validators;
    }

    /**
     * @notice Get the total number of registered validators
     * @dev Returns the count of validators currently registered in the vault
     * @return The number of registered validators
     */
    function getValidatorCount() external view returns (uint256) {
        return validators.length;
    }

    /**
     * @notice Get total amount delegated across all validators
     * @dev Calculates and returns the sum of all delegated amounts including pending stakes
     * @return Total delegated amount in wei
     */
    function getTotalDelegated() external view returns (uint256) {
        uint256 _total = 0;
        for (uint256 _i = 0; _i < validators.length; ++_i) {
            _total += _getTotalStakedToValidator(validators[_i]);
        }
        return _total;
    }

    /**
     * @notice Get total amount delegated to a specific validator
     * @dev Returns the total stake (active + pending) for the specified validator
     * @param _valId The validator ID to query
     * @return Total delegated amount to the validator in wei
     */
    function delegatedAmount(uint64 _valId) external view returns (uint256) {
        return _getTotalStakedToValidator(_valId);
    }

    /**
     * @notice Claim staking rewards from all validators and redistribute them
     * @dev Claims rewards from all validators, deducts protocol fees, and redistributes
     *      remaining rewards equally among validators for compound staking.
     */
    function claimAndCompoundRewards() external {
        _claimAndCompoundRewards();
    }
    //--------------------------------------------------------------------------------------------------------------
    // Internal functions
    //--------------------------------------------------------------------------------------------------------------

    /**
     * @notice Internal function to claim and compound staking rewards
     * @dev Claims rewards from all validators, calculates fees, and redistributes remaining rewards
     */
    function _claimAndCompoundRewards() internal {
        uint256 _startingBalance = address(this).balance;
        for (uint256 _i = 0; _i < validators.length; ++_i) {
            uint256 _before = address(this).balance;
            _claim(validators[_i]);
            emit RewardsClaimed(validators[_i], address(this).balance - _before);
        }
        uint256 _endingBalance = address(this).balance;
        uint256 _rewards = _endingBalance - _startingBalance;

        uint256 _fee = _calculateRewardsFeeAndSend(_rewards);

        uint256 _remaining = _rewards - _fee;
        _distributeAmountEquallyToValidators(_remaining);
    }

    /**
     * @dev Override VaultBase._distributeClaimedRewardsFromRemoval to use internal distribution
     * @param _amount The amount of rewards to distribute
     */
    function _distributeClaimedRewardsFromRemoval(uint256 _amount) internal override {
        // Use internal distribution instead of external delegate call
        _distributeAmountEquallyToValidators(_amount);
    }

    /**
     * @notice Internal function to initiate rebalancing by undelegating excess stakes
     * @dev Calculates target delegation per validator and undelegates excess from over-target validators
     */
    function _redelegateInitiate() internal {
        if (validators.length == 0) return;

        uint256 _totalDelegated = _getTotalStakedToAllValidators(); // contains pending redelegations
        if (_totalDelegated == 0) return;

        uint256 _targetPerValidator = _totalDelegated / validators.length;
        uint256 _totalToUndelegate = 0;
        for (uint256 _i = 0; _i < validators.length; ++_i) {
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
                    _checkFreeAdminWid(_v);
                    _allocateAdminWidAndUndelegate(_v, _toUndelegate);
                    // Track pending excess; keep local delegated until completion
                    setPendingRedelegateByValidator(_v, _toUndelegate);
                    _totalToUndelegate += _toUndelegate;
                }
            }
        }
        setTotalPendingRedelegation(totalPendingRedelegation() + _totalToUndelegate);
        _trackCachedUndelegation(_totalToUndelegate);
        emit RebalanceInitiated();
    }

    /**
     * @notice Internal function to complete rebalancing by redistributing undelegated funds
     * @dev Completes pending withdrawals and redistributes funds to under-target validators
     */
    function _redelegateRedistribute() internal {
        // Step 1: Complete all pending withdrawals
        uint256 _totalAmountToDistribute = _completeAllPendingRedelegationWithdrawals();

        if (_totalAmountToDistribute == 0) return;

        // Step 2: Get validators sorted by current stake (lowest first)
        ValidatorAmount[] memory _sortedValidators = _getSortedValidatorsByStake();

        // Step 3: Distribute stake to under-target validators in ascending order of stake
        _distributeStakeToValidatorsAscending(_sortedValidators, _totalAmountToDistribute);

        // Step 4: Update timestamp and mark rebalance as finished
        CoreVaultStorage storage $ = _getCoreVaultStorage();
        $._lastRebalanceTimestamp = block.timestamp;
        $._finishedLastRebalance = true;
    }

    /**
     * @notice Complete all pending withdrawals for admin withdrawal ID
     * @dev Internal helper function that completes withdrawals and returns total amount withdrawn
     * @return _totalWithdrawn The total amount withdrawn from all validators
     */
    function _completeAllPendingRedelegationWithdrawals() internal returns (uint256 _totalWithdrawn) {
        for (uint256 _i = 0; _i < validators.length; ++_i) {
            uint64 _valId = validators[_i];

            // Check bitmap first - if ADMIN_WID is not in use, skip expensive precompile call
            if (!_isWithdrawalIdInUse(_valId, ADMIN_WID)) {
                continue;
            }

            (bool _exists, uint256 _amount,,) = _getWithdrawalRequest(_valId, address(this), ADMIN_WID);
            if (_exists && _amount > 0) {
                // For admin withdrawals, we need to handle pending redelegation amounts
                _withdraw(_valId, ADMIN_WID);
                // Update pending redelegation tracking

                // Note: in the case where the withdrawal is slashed we use the cached amount to deduct from totalPendingRedelegation
                setTotalPendingRedelegation(totalPendingRedelegation() - pendingRedelegateByValidator(_valId));
                setPendingRedelegateByValidator(_valId, 0);

                // Mark withdrawal ID as completed
                _markWithdrawalCompleted(_valId, ADMIN_WID);
                _totalWithdrawn += _amount;
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

        for (uint256 _i = 0; _i < validators.length; ++_i) {
            uint64 _valId = validators[_i];
            DelInfo memory _coreVaultDelInfo = cachedDelegatorInfo(_valId);
            _sortedValidators[_i] = ValidatorAmount(
                _valId, _coreVaultDelInfo.stake + _coreVaultDelInfo.deltaStake + _coreVaultDelInfo.nextDeltaStake
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

        for (uint256 _i = 0; _i < validators.length; ++_i) {
            uint64 _valId = validators[_i];
            DelInfo memory _coreVaultDelInfo = cachedDelegatorInfo(_valId);
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
        for (uint256 _i = 0; _i < _sortedValidators.length; ++_i) {
            _currentTotalStake += _sortedValidators[_i].amount;
        }

        uint256 _newTotalStake = _currentTotalStake + _totalAmountToDistribute;
        uint256 _targetAmountPerValidator = _newTotalStake / validators.length;
        uint256 _remainingToDistribute = _totalAmountToDistribute;

        // Distribute to under-target validators, starting with lowest stake to achieve balance
        for (uint256 _i = 0; _i < _sortedValidators.length && _remainingToDistribute > 0; ++_i) {
            uint64 _valId = _sortedValidators[_i].valId;
            uint256 _currentAmount = _sortedValidators[_i].amount;

            // Only add stake to validators below the target amount
            if (_currentAmount < _targetAmountPerValidator) {
                uint256 _needed = _targetAmountPerValidator - _currentAmount;
                // Give this validator either what it needs or what we have left, whichever is smaller
                uint256 _toDelegate = _needed > _remainingToDistribute ? _remainingToDistribute : _needed;

                if (_toDelegate > 0) {
                    _delegate(_valId, _toDelegate);
                    _remainingToDistribute -= _toDelegate;
                }
            }
        }
        _trackCachedDelegation(_totalAmountToDistribute);
    }

    /**
     * @dev Distributes the specified amount equally among all validators
     * @param _amount The total amount to distribute
     */
    function _distributeAmountEquallyToValidators(uint256 _amount) internal {
        if (validators.length == 0) {
            revert ErrNoValidators();
        }
        if (_amount == 0) {
            revert ErrZeroAmount();
        }

        uint256 _amountPerValidator = _amount / validators.length;
        for (uint256 _i = 0; _i < validators.length; ++_i) {
            _delegate(validators[_i], _amountPerValidator);
        }

        _trackCachedDelegation(_amount);
    }

    /**
     * @dev Simple insertion sort for ValidatorAmount array (ascending by amount)
     */
    function _sort(ValidatorAmount[] memory _arr) internal pure {
        uint256 _length = _arr.length;
        for (uint256 _i = 1; _i < _length; ++_i) {
            ValidatorAmount memory key = _arr[_i];
            uint256 _j = _i;
            while (_j > 0 && _arr[_j - 1].amount > key.amount) {
                _arr[_j] = _arr[_j - 1];
                --_j;
            }
            _arr[_j] = key;
        }
    }

    /**
     * @dev Simple insertion sort for ValidatorAmount array (descending by amount)
     */
    function _sortDescending(ValidatorAmount[] memory _arr) internal pure {
        uint256 _length = _arr.length;
        for (uint256 _i = 1; _i < _length; ++_i) {
            ValidatorAmount memory key = _arr[_i];
            uint256 _j = _i;
            while (_j > 0 && _arr[_j - 1].amount < key.amount) {
                _arr[_j] = _arr[_j - 1];
                --_j;
            }
            _arr[_j] = key;
        }
    }

    /**
     * @dev Get all withdrawal requests for a user
     * @param _user The user address
     * @return Array of withdrawal request information
     */
    function getUserWithdrawalRequests(address _user) external view returns (WithdrawalRequestInfo[] memory) {
        return userWithdrawalRequests(_user);
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
        WithdrawalRequestInfo[] memory requests = userWithdrawalRequests(_user);
        if (_index >= requests.length) revert ErrInvalidAmount(_index);
        return requests[_index];
    }

    /**
     * @dev Get total number of withdrawal requests for a user
     * @param _user The user address
     * @return The total count of withdrawal requests for the user
     */
    function getUserWithdrawalRequestCount(address _user) external view returns (uint256) {
        return userWithdrawalRequests(_user).length;
    }

    /**
     * @notice Update the maximum number of validators that can be added in a single batch
     * @dev Admin function to adjust gas limit protection for batch validator operations
     * @param maxValidatorPerBatch New maximum batch size for validator additions
     */
    function setMaxValidatorPerBatch(uint64 maxValidatorPerBatch) external onlyAdmin {
        _getCoreVaultStorage()._maxValidatorPerBatch = maxValidatorPerBatch;
    }

    /**
     * @notice Internal function to authorize contract upgrades
     * @dev Only allows the Magma admin to authorize upgrades. Required by UUPSUpgradeable
     * @dev https://docs.openzeppelin.com/contracts/5.x/api/proxy#UUPSUpgradeable
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyAdmin {}
}
