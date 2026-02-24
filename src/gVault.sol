// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IGVault} from "interfaces/IGVault.sol";
import {ICoreVault} from "interfaces/ICoreVault.sol";
import {BaseVault} from "src/BaseVault.sol";
import {PausableValId} from "src/PausableValId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    ErrNotWhitelisted,
    ErrInvalidBps,
    ErrZeroShares,
    ErrCapZero,
    ErrExceedsCap,
    ErrBelowMinWithdraw,
    ErrBelowMinDeposit,
    ErrPullPassesStake,
    ErrNotAuthorized,
    ErrValidatorAdded,
    ErrInsufficientShares,
    ErrInvalidStart,
    ErrInvalidStop,
    ErrBatchNotCompleted,
    ErrRebalanceInProgress,
    ErrNoAccounts
} from "src/MagmaErrorsModule.sol";

/* solhint-disable-next-line contract-name-capwords */
contract gVault is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable, IGVault, BaseVault, PausableValId {
    /// @custom:storage-location erc7201:storage.GVault
    struct GVaultStorage {
        /// @dev Default cap as percentage of total Magma assets in basis points (25 = 0.25%)
        uint256 _defaultCapBps;
        /// @dev Minimum amount users can deposit in a single transaction (prevents dust attacks)
        uint256 _minUserDepositAmount;
        mapping(uint64 => uint256) _lastRebalancedStartIndex;
        mapping(uint64 => uint16) _lastRebalancedBps;
        /// @dev Per-validator absolute deposit caps in wei. If 0, uses defaultCapBps percentage instead
        mapping(uint64 => uint256) _validatorCap;
        //gvault shares, unrelated to core vault shares, to handle loss/gain
        mapping(uint64 => uint256) _totalSharesForValidator;
        mapping(address => mapping(uint64 => uint256)) _sharesForUserByValidator;
        // principal units, magma shares recieved for gvaults deposit per validator per user
        // used to calculate the exchange rate for a user
        mapping(address => mapping(uint64 => uint256)) _magmaSharesForUserByValidator;
        /// @dev Helper list of accounts per validator id
        mapping(uint64 => address[]) _accountsByValidator;
        mapping(address => mapping(uint64 => bool)) _accountExistsForValId;
    }

    /// @dev Default max cap used when totalAssets is 0 to prevent ErrCapZero on a first delegation to gVault.
    uint256 private constant DEFAULT_MAX_CAP = 100_000 ether;

    /// @dev Minimum amount that can be delegated; amounts below this are sent to the fee receiver as dust.
    /// @dev From https://github.com/category-labs/monad/blob/main/category/execution/monad/staking/util/constants.hpp#L49-L52
    uint256 private constant MIN_DELEGATION_AMOUNT = 1e9;

    // keccak256(abi.encode(uint256(keccak256("storage.GVault")) - 1)) & ~bytes32(uint256(0xff))
    /* solhint-disable-next-line const-name-snakecase */
    bytes32 private constant _GVaultStorageLocation =
        0x232a700b4988b63345b0748030e1e6bc1b8a8284e6c533d0f558dab152a9c400;

    /// @dev https://forum.openzeppelin.com/t/is-disableinitializers-necessary/31070
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the gVault contract with configuration parameters
     * @dev Sets up the vault with Magma protocol address and epoch timing
     * @param _magma The address of the Magma protocol contract
     * @param _epochSeconds The duration of each epoch in seconds
     */
    function initialize(address _magma, uint256 _epochSeconds) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __BaseVault_init(_magma, _epochSeconds);
        __PausableValId_init();
        GVaultStorage storage $ = _getGVaultStorage();
        $._defaultCapBps = 25;
        $._minUserDepositAmount = 100 ether;
    }

    function _getGVaultStorage() private pure returns (GVaultStorage storage $) {
        assembly {
            $.slot := _GVaultStorageLocation
        }
    }

    /**
     * @notice Modifier to validate magma shares before operations
     * @dev Ensures the user has sufficient magma shares for the requested operation
     * @param _account The user account to check shares for
     * @param _valId The validator ID associated with the shares
     * @param _magmaShares The amount of magma shares to validate
     */
    modifier checkMagmaShares(address _account, uint64 _valId, uint256 _magmaShares) {
        _checkMagmaShares(_account, _valId, _magmaShares);
        _;
    }

    /**
     * @dev Internal function to validate magma shares
     * @param _account The user account to check shares for
     * @param _valId The validator ID associated with the shares
     * @param _magmaShares The amount of magma shares to validate
     */
    function _checkMagmaShares(address _account, uint64 _valId, uint256 _magmaShares) private view {
        GVaultStorage storage $ = _getGVaultStorage();
        if (_magmaShares == 0) revert ErrZeroShares();
        if (_magmaShares > $._magmaSharesForUserByValidator[_account][_valId]) {
            revert ErrInsufficientShares(_magmaShares, $._magmaSharesForUserByValidator[_account][_valId]);
        }
    }

    /**
     * @dev Checks if a rebalance is inactive
     * @param _valId The validator ID to check rebalance status for
     * @return True if the batch has been completed
     */
    function _isRebalanceInactive(uint64 _valId) private view returns (bool) {
        GVaultStorage storage $ = _getGVaultStorage();
        return $._lastRebalancedStartIndex[_valId] == 0;
    }

    function accountsByValidatorLength(uint64 _valId) external view returns (uint256) {
        if (validatorStatus(_valId) == ValidatorStatus.REMOVED) return 0;
        return _getGVaultStorage()._accountsByValidator[_valId].length;
    }

    function magmaSharesForUserByValidator(address _account, uint64 _valId) external view returns (uint256) {
        if (validatorStatus(_valId) == ValidatorStatus.REMOVED) return 0;
        return _getGVaultStorage()._magmaSharesForUserByValidator[_account][_valId];
    }

    function sharesForUserByValidator(address _account, uint64 _valId) external view returns (uint256) {
        if (validatorStatus(_valId) == ValidatorStatus.REMOVED) return 0;
        return _getGVaultStorage()._sharesForUserByValidator[_account][_valId];
    }

    function totalSharesForValidator(uint64 _valId) external view returns (uint256) {
        if (validatorStatus(_valId) == ValidatorStatus.REMOVED) return 0;
        return _getGVaultStorage()._totalSharesForValidator[_valId];
    }

    function defaultCapBps() external view returns (uint256) {
        return _getGVaultStorage()._defaultCapBps;
    }

    function lastRebalancedStartIndex(uint64 _valId) external view returns (uint256) {
        return _getGVaultStorage()._lastRebalancedStartIndex[_valId];
    }

    function lastRebalancedBps(uint64 _valId) external view returns (uint256) {
        return _getGVaultStorage()._lastRebalancedBps[_valId];
    }

    function minUserDepositAmount() external view returns (uint256) {
        return _getGVaultStorage()._minUserDepositAmount;
    }

    function validatorCap(uint64 _valId) external view returns (uint256) {
        if (validatorStatus(_valId) == ValidatorStatus.REMOVED) return 0;
        return _getGVaultStorage()._validatorCap[_valId];
    }

    /**
     * @notice Pause operations for a specific validator
     * @dev Prevents delegations, undelegations, and rewards operations for the specified validator
     * @param _valId The validator ID to pause
     */
    function pauseValId(uint64 _valId) external onlyOwner {
        if (!isWhitelisted(_valId)) revert ErrNotWhitelisted();
        _pauseValId(_valId);
    }

    /**
     * @notice Unpause operations for a specific validator
     * @dev Cannot unpause if a rebalance operation is still in progress for this validator
     * @param _valId The validator ID to unpause
     */
    function unpauseValId(uint64 _valId) external onlyOwner {
        if (!isWhitelisted(_valId)) revert ErrNotWhitelisted();
        if (!_isRebalanceInactive(_valId)) revert ErrRebalanceInProgress();
        _unpauseValId(_valId);
    }

    /**
     * @notice Add a new validator to the whitelist
     * @dev Registers a validator as eligible for delegation in the gVault
     * @dev Cannot re-add a validator that was removed
     * @param _valId The validator ID to add
     */
    function addValidator(uint64 _valId) external onlyOwner {
        if (validatorStatus(_valId) != ValidatorStatus.NONE) {
            revert ErrValidatorAdded();
        }
        _refreshCache();
        _registerValidator(_valId);
    }

    /**
     * @notice Initiate the removal process for a validator
     * @dev Starts the validator removal process by pausing and removing from active list
     * @param _valId The validator ID to remove
     */
    function initiateValidatorRemoval(uint64 _valId) external onlyOwner whenNotPausedValId(_valId) {
        _refreshCache();
        _initiateValidatorRemoval(_valId);
    }

    /**
     * @notice Step 2: Remove validator from validators array this function forces all stake to be in an active state
     * @dev Remove validator from validators array
     * @param _valId The validator ID to remove
     */
    function executeValidatorUndelegation(uint64 _valId) external onlyOwner whenNotPausedValId(_valId) {
        _refreshCache();
        _executeValidatorUndelegation(_valId);
    }

    /**
     * @dev Complete the withdrawal process for a removed validator
     * This should be called after the WITHDRAWAL_DELAY period has passed
     * @param _valId The validator ID that was removed
     */
    function completeValidatorRemovalWithdrawal(uint64 _valId) external onlyOwner whenNotPausedValId(_valId) {
        _refreshCache();
        uint256 _withdrawalAmount = _completeValidatorRemovalWithdrawal(_valId);

        // Send withdrawal amount to CoreVault
        if (_withdrawalAmount > 0) {
            address _coreVaultAddress = magma().coreVault();
            ICoreVault(_coreVaultAddress).delegate{value: _withdrawalAmount}();
        }
    }

    /**
     * @notice Set a specific deposit cap for a validator
     * @dev Updates the maximum amount that can be delegated to a specific validator.
     *      If set to 0, the validator will use the default cap (percentage of total assets).
     *      If non-zero, the validator uses this absolute cap amount.
     * @param _valId The validator ID to set cap for
     * @param _newCap The new cap amount (0 to use default percentage cap, non-zero for absolute cap)
     */
    function changeValidatorCap(uint64 _valId, uint256 _newCap) external onlyOwner whenNotPausedValId(_valId) {
        if (!isWhitelisted(_valId)) revert ErrNotWhitelisted();
        _getGVaultStorage()._validatorCap[_valId] = _newCap;
        emit CapChanged(_valId, _newCap);
    }

    /**
     * @notice Set the default deposit cap percentage
     * @dev Updates the default cap as a percentage of total Magma assets
     * @param _newBps The new cap percentage in basis points (e.g., 25 = 0.25%)
     */
    function setDefaultCapBps(uint256 _newBps) external onlyOwner {
        if (_newBps > BASE_BPS) revert ErrInvalidBps();
        _getGVaultStorage()._defaultCapBps = _newBps;
        emit DefaultCapUpdated(_newBps);
    }

    /**
     * @notice Set the minimum deposit amount for users
     * @dev Updates the minimum amount users can withdrdepositaw in a single transaction
     * @param _amount The minimum depsoit amount in wei
     */
    function setMinUserDepositAmount(uint256 _amount) external onlyOwner {
        _getGVaultStorage()._minUserDepositAmount = _amount;
        emit MinUserDepositAmountUpdated(_amount);
    }

    /**
     * @notice Calculate the maximum deposit cap for a validator
     * @dev Returns validator-specific cap (absolute amount) if set, otherwise calculates
     *      default cap as a percentage of total Magma assets using defaultCapBps
     * @param _valId The validator ID to check cap for
     * @return The maximum deposit cap amount
     */
    function _maxCapFor(uint64 _valId) private view returns (uint256) {
        GVaultStorage storage $ = _getGVaultStorage();

        uint256 _cap = $._validatorCap[_valId];
        if (_cap != 0) return _cap;

        uint256 _total = magma().totalAssets();
        if (_total == 0) {
            return DEFAULT_MAX_CAP;
        }
        return (_total * $._defaultCapBps) / BASE_BPS;
    }

    /**
     * @dev Calculates gVault shares for a given amount of assets
     * @dev Adds +1 to numerator and denominator following openzeppelin erc4626 implementation, helps with edge cases
     *  such as when denominator or numerator are 0
     */
    function _sharesForAssets(uint64 _valId, uint256 _assets, Math.Rounding r) private returns (uint256) {
        GVaultStorage storage $ = _getGVaultStorage();
        uint256 _totalStaked = _getTotalStakedToValidator(_valId);
        return Math.mulDiv(_assets, $._totalSharesForValidator[_valId] + 1, _totalStaked + 1, r);
    }

    function sharesForAssets(uint64 _valId, uint256 _assets, Math.Rounding _r) external returns (uint256) {
        if (validatorStatus(_valId) == ValidatorStatus.REMOVED) return 0;
        return _sharesForAssets(_valId, _assets, _r);
    }

    function magmaSharesToGvaultAssets(uint64 _valId, address _user, uint256 _magmaShares) external returns (uint256) {
        if (validatorStatus(_valId) == ValidatorStatus.REMOVED) return 0;
        return _magmaSharesToGvaultAssets(_valId, _user, _magmaShares);
    }

    /**
     * @dev Main functionality of magmaSharesToGvaultAssets is to be called from Magma requestRedeemGVault to get the assets
     * amount that will be undelegated from gVault. Given this assumption is better to revert under certain conditions:
     *  - When total shares, shares or magma shares are 0
     *  - When magma shares exceed user total magma shares
     * @param _valId The validator ID to calculate assets for
     * @param _user The user address to calculate assets for
     * @param _magmaShares The amount of Magma shares to convert to gVault assets
     */
    function _magmaSharesToGvaultAssets(uint64 _valId, address _user, uint256 _magmaShares)
        private
        checkMagmaShares(_user, _valId, _magmaShares)
        returns (uint256)
    {
        GVaultStorage storage $ = _getGVaultStorage();

        uint256 _totalStaked = _getTotalStakedToValidator(_valId);
        // Amount assets user can withdraw = total assets for validator * shares for user / total shares for validator
        uint256 _amountAssetsUserCanWithdrawFromGvault = Math.mulDiv(
            _totalStaked,
            $._sharesForUserByValidator[_user][_valId],
            $._totalSharesForValidator[_valId], // if user magma shares is 0 then total shares is 0, if magma shares
            // is more than 1 then total shares is more than 1, so _totalSharesForValidator will never be 0 here since
            // checkMagmaShares checks for magma shares not being 0
            Math.Rounding.Floor
        );

        // assets = amount user can withdraw * current withdrawal magma shares amount / total user received magma shares amount
        return Math.mulDiv(
            _amountAssetsUserCanWithdrawFromGvault,
            _magmaShares,
            $._magmaSharesForUserByValidator[_user][_valId], // this cannot be 0, checked at checkMagmaShares modifier
            Math.Rounding.Floor
        );
    }

    /**
     * @notice Delegate MON to a specific validator on behalf of a user
     * @dev Converts MON to shares, tracks user position, and delegates to validator.
     *      Enforces validator caps.
     * @param _user The user address receiving the shares
     * @param _valId The validator ID to delegate to
     * @param _magmaShares The amount of Magma shares the user received for this deposit
     */
    function delegate(address _user, uint64 _valId, uint256 _magmaShares)
        external
        payable
        onlyMagma
        whenNotPaused
        whenNotPausedValId(_valId)
    {
        GVaultStorage storage $ = _getGVaultStorage();

        if (!isWhitelisted(_valId)) revert ErrNotWhitelisted();
        if (msg.value < $._minUserDepositAmount) {
            revert ErrBelowMinDeposit();
        }

        // Check if rewards need to be claimed before delegating
        _checkRewardsClaimDelay();

        // Cap check
        uint256 _cap = _maxCapFor(_valId);
        if (_cap == 0) revert ErrCapZero();
        uint256 _newAmt = msg.value + _getTotalStakedToValidator(_valId);
        if (_newAmt > _cap) revert ErrExceedsCap();

        uint256 _newShares = _sharesForAssets(_valId, msg.value, Math.Rounding.Floor);

        if (_newShares == 0) revert ErrZeroShares();

        $._totalSharesForValidator[_valId] += _newShares;
        $._sharesForUserByValidator[_user][_valId] += _newShares;

        $._magmaSharesForUserByValidator[_user][_valId] += _magmaShares;

        if (!$._accountExistsForValId[_user][_valId]) {
            $._accountExistsForValId[_user][_valId] = true;
            $._accountsByValidator[_valId].push(_user);
        }

        // Execute delegation to validator
        _delegate(_valId, msg.value);
        _trackCachedDelegation(msg.value);
    }

    /**
     * @notice Initiate undelegation of a specific amount from a validator for a user
     * @dev Burns user shares, creates withdrawal request, and tracks pending undelegation.
     * @param _user The user address requesting withdrawal
     * @param _valId The validator ID to undelegate from
     * @param _amount The amount to undelegate
     * @param _magmaShares The amount of Magma shares to burn for this undelegation
     */
    function undelegate(address _user, uint64 _valId, uint256 _amount, uint256 _magmaShares)
        external
        onlyMagma
        whenNotPaused
        whenNotPausedValId(_valId)
        checkMagmaShares(_user, _valId, _magmaShares)
    {
        if (_amount < minUserWithdrawAmount()) {
            revert ErrBelowMinWithdraw(minUserWithdrawAmount());
        }
        if (!isWhitelisted(_valId)) revert ErrNotWhitelisted();

        // Check if rewards need to be claimed before undelegating
        _checkRewardsClaimDelay();

        GVaultStorage storage $ = _getGVaultStorage();

        uint256 _shares = _sharesForAssets(_valId, _amount, Math.Rounding.Floor);
        if (_shares > $._sharesForUserByValidator[_user][_valId]) {
            revert ErrInsufficientShares(_shares, $._sharesForUserByValidator[_user][_valId]);
        }
        // removing shares at the time of request, not the time of completion
        // if there is slashing or rewards during this time, user won't be affected (verify this based on precompile?)
        // this is perfectly acceptable, I don't see any reason to complicate the code based on this
        $._totalSharesForValidator[_valId] -= _shares;
        $._sharesForUserByValidator[_user][_valId] -= _shares;

        $._magmaSharesForUserByValidator[_user][_valId] -= _magmaShares;

        uint8 _wid = _allocateWidAndUndelegate(_valId, _amount);

        // Store withdrawal request information
        _storeWithdrawalRequest(_user, _amount, _valId, _wid);

        // Track pending; do not lower local delegated until completion
        setPendingUndelegateByValidator(_valId, pendingUndelegateByValidator(_valId) + _amount);
        setTotalPendingUndelegations(totalPendingUndelegations() + _amount);

        // Track undelegation for caching
        _trackCachedUndelegation(_amount);
    }

    /**
     * @notice Complete all pending withdrawal requests for a user
     * @dev Processes all user withdrawal requests and transfers funds after fees
     * @param _user The user address whose withdrawals to complete
     * @return _totalWithdrawn The total amount withdrawn before fees
     * @return _totalWithdrawnAfterFee The amount transferred to user after fees
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
     * @notice Inject MEV rewards into a specific validator's stake
     * @dev Only callable by the authorized MEV rewards injector address
     * @param _valId The validator ID to inject rewards into
     */
    function injectRewards(uint64 _valId) external payable whenNotPaused whenNotPausedValId(_valId) {
        if (msg.sender != magma().mevRewardsInjector()) revert ErrNotAuthorized();
        if (!isWhitelisted(_valId)) revert ErrNotWhitelisted();
        _delegate(_valId, msg.value);
        _trackCachedDelegation(msg.value);
        emit RewardsInjected(msg.value, _valId);
    }

    /**
     * @notice Initiate a rebalance operation to reduce stake by a percentage for a validator
     * @dev Calls _rebalanceUndelegateBps to unstake only in the first transaction. This prevents the unstake amount
     *      from being affected by a possible slash in the following blocks while we batch the rest of the rebalance
     *      transactions.
     * @dev Multiple rebalances can be performed at the same time for different validators. Only one rebalance at a
     *      time per validator.
     * @dev This will not work when there is only one user in a gVault per valId, however, it is easy to bypass,
     *      just need to stake from another wallet
     * @param _bps The basis points percentage to rebalance (e.g., 1000 = 10%)
     * @param _valId The validator ID to rebalance
     * @param _start The starting index in the accounts array for this batch
     * @param _stop The ending index in the accounts array for this batch
     */
    function adminInitiateRebalanceBpsValId(uint16 _bps, uint64 _valId, uint256 _start, uint256 _stop)
        external
        onlyOwner
        whenPausedValId(_valId)
    {
        if (_bps > BASE_BPS || _bps == 0) revert ErrInvalidBps();

        GVaultStorage storage $ = _getGVaultStorage();
        if (_start != $._lastRebalancedStartIndex[_valId]) {
            revert ErrInvalidStart($._lastRebalancedStartIndex[_valId], _start);
        }
        if (_start > _stop) revert ErrInvalidStop();
        address[] storage _accounts = $._accountsByValidator[_valId];
        if (_accounts.length == 0) revert ErrNoAccounts();
        uint256 _lastIndex = _accounts.length - 1;
        if (_stop > _lastIndex) {
            revert ErrInvalidStop();
        }

        if ($._lastRebalancedStartIndex[_valId] == 0) {
            _rebalanceUndelegateBps(_bps, _valId);
            $._lastRebalancedBps[_valId] = _bps;
        }

        if (_bps != $._lastRebalancedBps[_valId]) revert ErrInvalidBps();

        for (uint256 i = _start; i <= _stop; ++i) {
            address _account = _accounts[i];
            uint256 _currentMagmaShares = $._magmaSharesForUserByValidator[_account][_valId];
            if (_currentMagmaShares > 0) {
                uint256 _newMagmaShares =
                    Math.mulDiv(_currentMagmaShares, uint256(BASE_BPS - _bps), BASE_BPS, Math.Rounding.Floor);
                $._magmaSharesForUserByValidator[_account][_valId] = _newMagmaShares;
            }
        }

        // If stop == _lastIndex we can still set + 1 to invalidate calling adminInitiateRebalanceBpsValId again
        $._lastRebalancedStartIndex[_valId] = _stop + 1;

        emit AdminInitiatedRebalanceBatch(_bps, _valId, _start, _stop);
    }

    /**
     * @dev Undelegates a percentage of stake from a validator during rebalance
     * @dev It is fine to not use totalAssets here since we refreshCache before calling _getCachedTotalStakedToValidator.
     *      Also totalAssets does not expose data per valId.
     * @param _bps The basis points percentage to undelegate
     * @param _valId The validator ID to undelegate from
     */
    function _rebalanceUndelegateBps(uint16 _bps, uint64 _valId) private {
        _refreshCache();
        (uint256 _totalStake, uint256 _stake) = _getCachedTotalStakedToValidator(_valId);
        uint256 _pull = Math.mulDiv(_totalStake, _bps, BASE_BPS, Math.Rounding.Floor);

        if (_pull > _stake) revert ErrPullPassesStake();
        if (_pull > 0) {
            _checkFreeAdminWid(_valId);
            _allocateAdminWidAndUndelegate(_valId, _pull);
            setPendingRedelegateByValidator(_valId, _pull);
            setTotalPendingRedelegation(totalPendingRedelegation() + _pull);

            // Track undelegation for caching
            _trackCachedUndelegation(_pull);
        }

        emit AdminInitiatedRebalance(_bps, _valId);
    }

    /**
     * @notice Complete a rebalance operation and forward withdrawn funds to CoreVault
     * @param _valId The validator ID to complete rebalance for
     */
    function adminCompleteRebalance(uint64 _valId) external onlyOwner nonReentrant whenPausedValId(_valId) {
        GVaultStorage storage $ = _getGVaultStorage();
        if ($._accountsByValidator[_valId].length != $._lastRebalancedStartIndex[_valId]) {
            revert ErrBatchNotCompleted();
        }

        _refreshCache();
        $._lastRebalancedStartIndex[_valId] = 0;
        $._lastRebalancedBps[_valId] = 0;

        uint256 _beforeBal = address(this).balance;
        _withdraw(_valId, ADMIN_WID);
        _markWithdrawalCompleted(_valId, ADMIN_WID);
        // Note: in the case where the withdrawal is slashed we use the cached amount to deduct from totalPendingRedelegation
        setTotalPendingRedelegation(totalPendingRedelegation() - pendingRedelegateByValidator(_valId));
        setPendingRedelegateByValidator(_valId, 0);

        uint256 _delta = address(this).balance - _beforeBal;
        if (_delta > 0) {
            ICoreVault(magma().coreVault()).delegate{value: _delta}();
        }
        emit AdminCompletedRebalance(_delta, _valId);
    }

    /**
     * @notice Get total amount delegated to a specific validator
     * @dev Returns the total stake (active + pending) for the specified validator
     * @param _valId The validator ID to query
     * @return Total delegated amount to the validator in wei
     */
    function delegatedAmount(uint64 _valId) external returns (uint256) {
        return _getTotalStakedToValidator(_valId);
    }

    /**
     * @notice Claim and compound staking rewards for a specific validator
     * @dev Claims rewards from the validator, deducts fees, and re-delegates remaining rewards
     */
    function claimAndCompoundRewards() external nonReentrant {
        uint64[] memory _list = getValidators();
        bool _claimedAny = false;
        for (uint256 i = 0; i < _list.length; ++i) {
            uint64 _valId = _list[i];
            bool _isPausedVald = pausedValId(_valId);
            if (_isRebalanceInactive(_valId) && !_isPausedVald) {
                _claimAndCompoundRewards(_valId);
                _claimedAny = true;
            }
        }
        if (_claimedAny) {
            _updateLastRewardsClaimTimestamp();
        }
    }

    /**
     * @notice Function to claim and compound staking rewards
     * @dev Claims validator rewards, calculates fees, and re-delegates to the same validator
     * @param _valId The validator ID to claim rewards from
     */
    function _claimAndCompoundRewards(uint64 _valId) private {
        uint256 _startingBalance = address(this).balance;
        bool _success = _claim(_valId);
        uint256 _endingBalance = address(this).balance;
        uint256 _rewards = _endingBalance - _startingBalance;
        emit RewardsClaimed(_valId, _rewards);
        if (_rewards > 0 && _success) {
            uint256 _fee = _calculateRewardsFeeAndSend(_rewards);
            if (_fee < _rewards) {
                uint256 _remaining = _rewards - _fee;
                if (_remaining >= MIN_DELEGATION_AMOUNT) {
                    _delegate(_valId, _remaining);
                    _trackCachedDelegation(_remaining);
                } else {
                    // Dust below min delegation: send to fee receiver to avoid delegation revert
                    (bool _ok,) = magma().feeReceiver().call{value: _remaining}("");
                    if (!_ok) {
                        emit RewardsFeeTransferFailed(_remaining);
                    } else {
                        emit RewardsFeeTransferSuccess(_remaining, magma().feeReceiver());
                    }
                }
            }
        }
    }

    /**
     * @notice Internal function to authorize contract upgrades
     * @dev Only allows the Magma admin to authorize upgrades. Required by UUPSUpgradeable
     * @dev https://docs.openzeppelin.com/contracts/5.x/api/proxy#UUPSUpgradeable
     */
    /* solhint-disable-next-line no-empty-blocks */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
