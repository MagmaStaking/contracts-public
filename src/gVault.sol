// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IGVault} from "../interfaces/IGVault.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {BaseVault} from "./BaseVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DelInfo} from "./MagmaDelegationModule.sol";
import {
    ErrNotWhitelisted,
    ErrInvalidBps,
    ErrZeroAddress,
    ErrZeroShares,
    ErrCapZero,
    ErrExceedsCap,
    ErrBelowMinWithdraw,
    ErrInsufficientDelegated,
    ErrPullPassesStake,
    ErrRebalanceInProgress,
    ErrRebalanceNotInProgress,
    ErrNotAuthorized,
    ErrValidatorAdded,
    ErrZeroAmount
} from "./MagmaErrorsModule.sol";

/* solhint-disable-next-line contract-name-capwords */
contract gVault is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable, IGVault, BaseVault {
    /// @custom:storage-location erc7201:storage.GVault
    struct GVaultStorage {
        /// @dev Default cap as percentage of total Magma assets in basis points (25 = 0.25%)
        uint256 _defaultCapBps;
        /// @dev Per-validator current scale index
        mapping(uint64 => uint256) _currentScaleByValidator;
        /// @dev Per-validator multiplier P value per scale
        mapping(uint64 => mapping(uint256 => uint256)) _scaleToMultiplierPByValidator;
        /// @dev EIP-4626 style share tracking: tracks user's share ownership per validator
        mapping(address => mapping(uint64 => uint256)) _delegatedSharesOf;
        /// @dev Total shares issued for each validator (used for share-to-asset conversion)
        mapping(uint64 => uint256) _totalSharesByValidator;
        /// @dev Per-validator absolute deposit caps in wei. If 0, uses defaultCapBps percentage instead
        mapping(uint64 => uint256) _validatorCap;
        // =========================
        // Liquity-style multiplier tracking for admin rebalances
        // =========================
        /// @dev User's initial deposit amount per validator (Liquity: initialValue)
        /// Updated on each deposit/withdrawal to reflect the user's current "principal"
        mapping(address => mapping(uint64 => uint256)) _scaledPrincipalUnits;
        /// @dev User's snapshot of P and scale at time of last operation
        mapping(address => mapping(uint64 => Snapshot)) _userSnapshots;
        /// @dev Sum of users' principal units per validator; used to scale P on rewards
        mapping(uint64 => uint256) _totalScaledPrincipalUnits;
    }

    /// @dev Default max cap used when totalAssets is 0 to prevent ErrCapZero on a first delegation to gVault.
    uint256 internal constant DEFAULT_MAX_CAP = 100_000 ether;
    /// @dev Threshold below which P is rescaled to prevent precision loss (1e20)
    uint256 internal constant MULTIPLIER_FLOOR = 1e20; // if P < this, rescale
    /// @dev Rescaling factor applied to both P and S to maintain their ratio (1e9)
    uint256 internal constant MULTIPLIER_RESCALE_K = 1e9; // multiply P and S by K
    /// @dev Global scale factor (1e27) base value - constant with exponent approach
    uint256 internal constant GVAULT_BASE_SCALE_S = 1e27;

    /// @dev Snapshot of P and scale at the time of user's last deposit/withdrawal
    struct Snapshot {
        uint256 P;
        uint256 scale;
    }

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
     * @dev Sets up the vault with Magma protocol address, epoch timing, and multiplier system
     * @param _magma The address of the Magma protocol contract
     * @param _epochSeconds The duration of each epoch in seconds
     */
    function initialize(address _magma, uint256 _epochSeconds) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __BaseVault_init(_magma, _epochSeconds);
        // initialize multiplier system for proxies (declarations don't run)
        GVaultStorage storage $ = _getGVaultStorage();
        $._defaultCapBps = 25;
    }

    function _getGVaultStorage() private pure returns (GVaultStorage storage $) {
        assembly {
            $.slot := _GVaultStorageLocation
        }
    }

    modifier whenValNotRemoved(uint64 valId) {
        if (validatorStatus(valId) != ValidatorStatus.REMOVED) {
            _;
        }
    }

    function defaultCapBps() external view returns (uint256) {
        return _getGVaultStorage()._defaultCapBps;
    }

    function currentScale(uint64 _valId) external view returns (uint256) {
        return _getGVaultStorage()._currentScaleByValidator[_valId];
    }

    function currentMultiplierP(uint64 _valId) external view returns (uint256) {
        GVaultStorage storage $ = _getGVaultStorage();
        uint256 s = $._currentScaleByValidator[_valId];
        return $._scaleToMultiplierPByValidator[_valId][s];
    }

    function multiplierPAtScale(uint64 _valId, uint256 _scale) external view returns (uint256) {
        return _getGVaultStorage()._scaleToMultiplierPByValidator[_valId][_scale];
    }

    function userSnapshot(address _user, uint64 _valId) external view returns (uint256 P, uint256 scale) {
        Snapshot memory snap = _getGVaultStorage()._userSnapshots[_user][_valId];
        return (snap.P, snap.scale);
    }

    function delegatedSharesOf(address user, uint64 valId)
        external
        view
        whenValNotRemoved(valId)
        returns (uint256 shares)
    {
        return _getGVaultStorage()._delegatedSharesOf[user][valId];
    }

    function totalSharesByValidator(uint64 valId) external view whenValNotRemoved(valId) returns (uint256 totalShares) {
        return _getGVaultStorage()._totalSharesByValidator[valId];
    }

    function validatorCap(uint64 valId) external view returns (uint256) {
        return _getGVaultStorage()._validatorCap[valId];
    }

    function scaledPrincipalUnits(address user, uint64 valId) external view returns (uint256) {
        return _getGVaultStorage()._scaledPrincipalUnits[user][valId];
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
        // initialize per-validator multiplier tracking
        GVaultStorage storage $ = _getGVaultStorage();
        $._currentScaleByValidator[_valId] = 0;
        $._scaleToMultiplierPByValidator[_valId][0] = 1e27;
    }

    /**
     * @notice Initiate the removal process for a validator
     * @dev Starts the validator removal process by pausing and removing from active list
     * @param _valId The validator ID to remove
     */
    function initiateValidatorRemoval(uint64 _valId) external onlyOwner {
        _refreshCache();
        _initiateValidatorRemoval(_valId);
    }

    /**
     * @notice Step 2: Remove validator from validators array this function forces all stake to be in an active state
     * @dev Remove validator from validators array
     * @param _valId The validator ID to remove
     */
    function executeValidatorUndelegation(uint64 _valId) external onlyOwner {
        _refreshCache();
        _executeValidatorUndelegation(_valId);
    }

    /**
     * @dev Complete the withdrawal process for a removed validator
     * This should be called after the WITHDRAWAL_DELAY period has passed
     * @param _valId The validator ID that was removed
     */
    function completeValidatorRemovalWithdrawal(uint64 _valId) external onlyOwner {
        _refreshCache();
        uint256 _withdrawalAmount = _completeValidatorRemovalWithdrawal(_valId);

        // Send withdrawal amount to CoreVault
        if (_withdrawalAmount > 0) {
            address coreVaultAddress = magma().coreVault();
            ICoreVault(coreVaultAddress).delegate{value: _withdrawalAmount}();
        }
    }

    /**
     * @notice Get all registered validator IDs
     * @dev Returns array of validator IDs currently registered in the gVault
     * @return Array of validator IDs
     */
    function getValidators() public view override returns (uint64[] memory) {
        return super.getValidators();
    }

    /**
     * @notice Set a specific deposit cap for a validator
     * @dev Updates the maximum amount that can be delegated to a specific validator.
     *      If set to 0, the validator will use the default cap (percentage of total assets).
     *      If non-zero, the validator uses this absolute cap amount.
     * @param _valId The validator ID to set cap for
     * @param _newCap The new cap amount (0 to use default percentage cap, non-zero for absolute cap)
     */
    function changeValidatorCap(uint64 _valId, uint256 _newCap) external onlyOwner {
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
     * @notice Calculate the maximum deposit cap for a validator
     * @dev Returns validator-specific cap (absolute amount) if set, otherwise calculates
     *      default cap as a percentage of total Magma assets using defaultCapBps
     * @param _valId The validator ID to check cap for
     * @return The maximum deposit cap amount
     */
    function _maxCapFor(uint64 _valId) internal view returns (uint256) {
        GVaultStorage storage $ = _getGVaultStorage();

        uint256 cap = $._validatorCap[_valId];
        if (cap != 0) return cap;

        uint256 total = magma().totalAssets();
        if (total == 0) {
            return DEFAULT_MAX_CAP;
        }
        return (total * $._defaultCapBps) / BASE_BPS;
    }

    /**
     * @notice Get the amount of assets corresponding to user's shares for a validator
     * @param _user The user address
     * @param _valId The validator ID
     * @return _assets The amount of assets the user's shares represent
     */
    function delegatedAmountOf(address _user, uint64 _valId) external returns (uint256 _assets) {
        return _convertToAssets(_valId, _getGVaultStorage()._delegatedSharesOf[_user][_valId]);
    }

    /**
     * @notice Delegate MON to a specific validator on behalf of a user
     * @dev Converts MON to shares, tracks user position, and delegates to validator.
     *      Enforces validator caps and updates multiplier-based tracking.
     * @param _user The user address receiving the shares
     * @param _valId The validator ID to delegate to
     */
    function delegate(address _user, uint64 _valId) external payable onlyMagma whenNotPaused {
        if (!isWhitelisted(_valId)) revert ErrNotWhitelisted();
        if (_user == address(0)) revert ErrZeroAddress();

        // Check if rewards need to be claimed before delegating
        _checkRewardsClaimDelay();

        // Cap check
        uint256 _cap = _maxCapFor(_valId);
        if (_cap == 0) revert ErrCapZero();
        uint256 newAmt = msg.value + _getTotalStakedToValidator(_valId);
        if (newAmt > _cap) revert ErrExceedsCap();

        // Convert assets to shares based on current exchange rate
        uint256 _sharesToMint = _convertToShares(_valId, msg.value, Math.Rounding.Floor);
        if (_sharesToMint == 0) {
            revert ErrZeroShares();
        }

        // Execute delegation to validator
        _delegate(_valId, msg.value);
        _trackCachedDelegation(msg.value);

        // Update multiplier-based principal tracking
        // We get the compounded deposit first, add the new deposit, then update snapshot
        GVaultStorage storage $ = _getGVaultStorage();
        if (msg.value > 0) {
            // Get user's current compounded deposit and add new deposit
            uint256 _compoundedDeposit = _getCompoundedUserDeposit(_user, _valId);
            uint256 _newDeposit = _compoundedDeposit + msg.value;

            // Update deposit and snapshot
            _updateUserDepositAndSnapshot(_user, _valId, _newDeposit);
        }

        // Update user's share position
        $._delegatedSharesOf[_user][_valId] += _sharesToMint;
        $._totalSharesByValidator[_valId] += _sharesToMint;

        emit PositionUpdated(_user, _valId, msg.value, true);
    }

    /**
     * @notice Initiate undelegation of a specific amount from a validator for a user
     * @dev Burns user shares, creates withdrawal request, and tracks pending undelegation.
     *      Updates multiplier-based principal tracking.
     * @param _user The user address requesting withdrawal
     * @param _valId The validator ID to undelegate from
     * @param _amount The amount to undelegate
     */
    function undelegate(address _user, uint64 _valId, uint256 _amount) external onlyMagma whenNotPaused {
        if (_amount < minUserWithdrawAmount()) {
            revert ErrBelowMinWithdraw(minUserWithdrawAmount());
        }
        if (_amount == 0) revert ErrZeroAmount();
        //undelegate just adds to the queue
        if (!isWhitelisted(_valId)) revert ErrNotWhitelisted();
        if (_user == address(0)) revert ErrZeroAddress();

        // Check if rewards need to be claimed before undelegating
        _checkRewardsClaimDelay();

        // Convert amount to shares to determine how many shares to burn
        uint256 _sharesToBurn = _convertToShares(_valId, _amount, Math.Rounding.Ceil);

        // Check if user has sufficient shares
        GVaultStorage storage $ = _getGVaultStorage();
        if ($._delegatedSharesOf[_user][_valId] < _sharesToBurn) {
            uint256 userAssets = _convertToAssets(_valId, $._delegatedSharesOf[_user][_valId]);
            revert ErrInsufficientDelegated(_amount, userAssets);
        }

        // Burn shares from user
        $._delegatedSharesOf[_user][_valId] -= _sharesToBurn;
        $._totalSharesByValidator[_valId] -= _sharesToBurn;

        // Update deposit tracking: get compounded deposit, subtract withdrawal
        uint256 _compoundedDeposit = _getCompoundedUserDeposit(_user, _valId);

        // Prevent underflow: if withdrawing more than compounded, set to 0
        uint256 _remainingDeposit = _amount >= _compoundedDeposit ? 0 : (_compoundedDeposit - _amount);

        // Update deposit and snapshot
        _updateUserDepositAndSnapshot(_user, _valId, _remainingDeposit);

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

    function injectRewards(uint64 _valId) public payable whenNotPaused {
        if (msg.sender != magma().mevRewardsInjector()) revert ErrNotAuthorized();
        if (msg.value == 0) revert ErrZeroAmount();
        if (!isWhitelisted(_valId)) revert ErrNotWhitelisted();
        _delegate(_valId, msg.value);
        _trackCachedDelegation(msg.value);
        emit RewardsInjected(msg.value, _valId);
    }

    // Admin: initiate undelegation across all validators by basis points
    // This function is used when liquidity for CoreVault is depleted. Similar functionality exists in Lido v3.
    /**
     * @notice Initiate admin rebalance by undelegating a percentage from all validators
     * @dev Undelegates specified basis points from all validators to provide liquidity to CoreVault.
     *      Updates the gVault multiplier system to track user entitlements properly.
     *      Similar functionality exists in Lido v3 for liquidity management.
     * @param _bps The basis points to undelegate (e.g., 1000 = 10%)
     */
    function adminInitiateRebalanceBps(uint16 _bps) external onlyOwner {
        if (!finishedLastRebalance()) revert ErrRebalanceInProgress();
        _refreshCache();
        GVaultStorage storage $ = _getGVaultStorage();

        if (_bps > BASE_BPS) revert ErrInvalidBps();
        uint64[] memory _list = getValidators();
        uint256 n = _list.length;
        setFinishedLastRebalance(false); // Mark rebalance as in progress
        for (uint256 i = 0; i < n; ++i) {
            uint64 v = _list[i];
            // Handle edge case of 100% rebalance (complete liquidation)
            if (_bps == BASE_BPS) {
                // Special handling for 100% outflow: prevent P from hitting zero which would break math
                // Move to 2 new scales, effectively making existing user units worthless (entitlement ≈ 0)
                uint256 _currentScale = $._currentScaleByValidator[v];
                $._currentScaleByValidator[v] = _currentScale + 2;
                $._scaleToMultiplierPByValidator[v][_currentScale + 2] = 1e27; // reset P to nominal 1.0 in 1e27 scale at new scale
                emit GVaultRescaled(MULTIPLIER_RESCALE_K, 1e27, GVAULT_BASE_SCALE_S);
            } else {
                // Update cumulative multiplier P at current scale to reflect what fraction stays in gVault
                // P_new = P_old * (1 - bps/10000) tracks cumulative retention
                (uint256 _currentScale, uint256 oldP) = _getCurrentScaleAndP(v);
                uint256 factor1e27 = uint256(BASE_BPS - _bps) * 1e23; // Convert (1 - bps/10000) to 1e27 scale
                uint256 newP = Math.mulDiv(oldP, factor1e27, 1e27, Math.Rounding.Ceil); // round up to prevent erosion
                $._scaleToMultiplierPByValidator[v][_currentScale] = newP;
                emit GVaultMultiplierUpdated(oldP, newP, _bps);

                // Prevent precision loss: if P gets too small, rescale to new scale
                // This maintains user entitlements while bringing P back to a safe range
                if (newP < MULTIPLIER_FLOOR) {
                    $._currentScaleByValidator[v] = _currentScale + 1;
                    $._scaleToMultiplierPByValidator[v][_currentScale + 1] = newP * MULTIPLIER_RESCALE_K;
                    emit GVaultRescaled(MULTIPLIER_RESCALE_K, newP * MULTIPLIER_RESCALE_K, GVAULT_BASE_SCALE_S);
                }
            }
            // Decode vault-level delegation from precompile
            DelInfo memory _delInfo = cachedDelegatorInfo(v);
            uint256 _totalStake = _delInfo.stake + _delInfo.deltaStake + _delInfo.nextDeltaStake;
            uint256 pull = (_totalStake * _bps) / BASE_BPS;
            if (pull > _delInfo.stake) revert ErrPullPassesStake();
            if (pull > 0) {
                _checkFreeAdminWid(v);
                _allocateAdminWidAndUndelegate(v, pull);
                setPendingRedelegateByValidator(v, pull);
                setTotalPendingRedelegation(totalPendingRedelegation() + pull);

                // Track undelegation for caching
                _trackCachedUndelegation(pull);
            }
        }
        emit AdminInitiatedRebalance(_bps);
    }

    /**
     * @notice Complete admin rebalance by withdrawing matured undelegations
     * @dev Completes all pending admin withdrawals and forwards funds to CoreVault
     *      through Magma protocol. Marks the rebalance process as finished.
     */
    function adminCompleteRebalance() public onlyOwner nonReentrant {
        if (finishedLastRebalance()) revert ErrRebalanceNotInProgress();
        _refreshCache();
        uint64[] memory _list = getValidators();
        uint256 _beforeBal = address(this).balance;
        uint256 _n = _list.length;
        // Process each validator's pending admin withdrawal
        for (uint256 i = 0; i < _n; ++i) {
            uint64 _valId = _list[i];

            (, uint256 amt,,) = _getWithdrawalRequest(_valId, address(this), ADMIN_WID);
            if (amt == 0) continue; // Skip if no pending withdrawal

            _withdraw(_valId, ADMIN_WID);
            _markWithdrawalCompleted(_valId, ADMIN_WID);
            // This event amount could be wrong since it is not based on delta
            emit AdminCompletedRebalanceWithdrawal(_valId, amt);
            // Note: in the case where the withdrawal is slashed we use the cached amount to deduct from totalPendingRedelegation
            setTotalPendingRedelegation(totalPendingRedelegation() - pendingRedelegateByValidator(_valId));
            setPendingRedelegateByValidator(_valId, 0);
        }
        uint256 _delta = address(this).balance - _beforeBal;
        if (_delta > 0) {
            ICoreVault(magma().coreVault()).delegate{value: _delta}();
        }
        setFinishedLastRebalance(true); // Mark rebalance as completed
        emit AdminCompletedRebalance(_delta);
    }

    /**
     * @notice Claim and compound staking rewards for a specific validator
     * @dev Claims rewards from the validator, deducts fees, and re-delegates remaining rewards
     */
    function claimAndCompoundRewards() external nonReentrant {
        uint64[] memory _list = getValidators();
        for (uint256 i = 0; i < _list.length; ++i) {
            uint64 _valId = _list[i];
            _claimAndCompoundRewards(_valId);
        }
        _updateLastRewardsClaimTimestamp();
    }

    /**
     * @notice Internal function to claim and compound staking rewards
     * @dev Claims validator rewards, calculates fees, and re-delegates to the same validator
     * @param _valId The validator ID to claim rewards from
     */
    function _claimAndCompoundRewards(uint64 _valId) internal {
        uint256 _startingBalance = address(this).balance;
        bool success = _claim(_valId);
        uint256 _endingBalance = address(this).balance;
        uint256 _rewards = _endingBalance - _startingBalance;
        emit RewardsClaimed(_valId, _rewards);
        if (_rewards > 0 && success) {
            uint256 _fee = _calculateRewardsFeeAndSend(_rewards);
            if (_fee < _rewards) {
                uint256 _remaining = _rewards - _fee;
                // Scale P up for this validator based on net rewards and current total principal units
                GVaultStorage storage $ = _getGVaultStorage();
                uint256 totalScaled = $._totalScaledPrincipalUnits[_valId];
                if (totalScaled > 0) {
                    (uint256 s, uint256 oldP) = _getCurrentScaleAndP(_valId);
                    uint256 newP = Math.mulDiv(oldP, totalScaled + _remaining, totalScaled, Math.Rounding.Floor);
                    $._scaleToMultiplierPByValidator[_valId][s] = newP;
                }
                _delegate(_valId, _remaining);
                _trackCachedDelegation(_remaining);
            }
        }
    }

    /**
     * @dev Convert assets to shares for a specific validator (EIP-4626 style)
     * @param _valId The validator ID
     * @param _assets The amount of assets to convert
     * @return _shares The equivalent number of shares
     */
    function _convertToShares(uint64 _valId, uint256 _assets, Math.Rounding rounding)
        internal
        returns (uint256 _shares)
    {
        uint256 _totalAssets = _getTotalStakedToValidator(_valId);
        uint256 _totalShares = _getGVaultStorage()._totalSharesByValidator[_valId];

        // Handle initial deposit case: no existing shares or assets
        if (_totalShares == 0 || _totalAssets == 0) {
            // Initial deposit: 1:1 ratio (1 asset = 1 share)
            return _assets;
        }

        // Calculate shares proportionally: shares = assets * total_shares / total_assets
        // Round down to favor the vault (EIP-4626 requirement for convertToShares)
        return Math.mulDiv(_assets, _totalShares, _totalAssets, rounding);
    }

    /**
     * @dev Get current per-validator P at current scale
     * @return Current scale and current P value for the validator
     */
    function _getCurrentScaleAndP(uint64 _valId) internal view returns (uint256, uint256) {
        GVaultStorage storage $ = _getGVaultStorage();
        uint256 _scale = $._currentScaleByValidator[_valId];
        uint256 _P = $._scaleToMultiplierPByValidator[_valId][_scale];
        return (_scale, _P);
    }

    /**
     * @dev Calculate user's compounded entitlement considering scale changes
     * @param _initialDeposit User's initial deposit amount from their snapshot
     * @param _snapshotP P value at user's snapshot
     * @param _snapshotScale Scale index at user's snapshot
     * @return User's current entitlement
     *
     * - scaleDiff = 0: compoundedDeposit = initialDeposit * P / snapshot_P
     * - scaleDiff = 1: compoundedDeposit = initialDeposit * P / snapshot_P / SCALE_FACTOR
     * - scaleDiff >= 2: compoundedDeposit = 0 (position is negligible)
     */
    function _getCompoundedEntitlement(
        uint256 _initialDeposit,
        uint256 _snapshotP,
        uint256 _snapshotScale,
        uint64 _valId
    ) internal view returns (uint256) {
        if (_initialDeposit == 0) return 0;

        GVaultStorage storage $ = _getGVaultStorage();
        uint256 _currentScale = $._currentScaleByValidator[_valId];
        uint256 _currentP = $._scaleToMultiplierPByValidator[_valId][_currentScale];

        uint256 _scaleDiff = _currentScale - _snapshotScale;

        /* Compute the compounded stake. If a scale change in P was made during the stake's lifetime,
        * account for it. If more than one scale change was made, then the stake has decreased by a factor of
        * at least 1e-9 -- so return 0.
        */
        if (_scaleDiff == 0) {
            return Math.mulDiv(_initialDeposit, _currentP, _snapshotP);
        } else if (_scaleDiff == 1) {
            return Math.mulDiv(_initialDeposit, _currentP, _snapshotP * MULTIPLIER_RESCALE_K);
        } else {
            // if scaleDiff >= 2
            return 0;
        }
    }

    /**
     * @dev Get user's compounded deposit amount for a validator
     * @param _user The user address
     * @param _valId The validator ID
     * @return Compounded deposit amount
     */
    function _getCompoundedUserDeposit(address _user, uint64 _valId) internal view returns (uint256) {
        GVaultStorage storage $ = _getGVaultStorage();
        uint256 initialDeposit = $._scaledPrincipalUnits[_user][_valId];
        Snapshot memory snap = $._userSnapshots[_user][_valId];
        return _getCompoundedEntitlement(initialDeposit, snap.P, snap.scale, _valId);
    }

    /**
     * @dev Update user's deposit and snapshot to current P and scale
     * @param _user The user address
     * @param _valId The validator ID
     * @param _newDeposit The new deposit amount
     */
    function _updateUserDepositAndSnapshot(address _user, uint64 _valId, uint256 _newDeposit) internal {
        GVaultStorage storage $ = _getGVaultStorage();
        (uint256 _currentScale, uint256 _currentP) = _getCurrentScaleAndP(_valId);
        // Read previous initial principal units before update
        uint256 _oldInitial = $._scaledPrincipalUnits[_user][_valId];

        $._scaledPrincipalUnits[_user][_valId] = _newDeposit;
        $._userSnapshots[_user][_valId] = Snapshot({P: _currentP, scale: _currentScale});

        // Adjust total principal units by delta between new and old initial units
        if (_newDeposit >= _oldInitial) {
            $._totalScaledPrincipalUnits[_valId] += (_newDeposit - _oldInitial);
        } else {
            $._totalScaledPrincipalUnits[_valId] -= (_oldInitial - _newDeposit);
        }
    }

    /**
     * @notice Calculate maximum withdrawable amount for a user from gVault only
     * @dev Returns user's entitlement based on multiplier system
     * @param _user The user address
     * @param _valId The validator ID
     * @return maxWithdrawable Maximum withdrawable amount from gVault tracking
     */
    function maxWithdrawableFromGVault(address _user, uint64 _valId)
        public
        view
        whenValNotRemoved(_valId)
        returns (uint256 maxWithdrawable)
    {
        return _getCompoundedUserDeposit(_user, _valId);
    }

    /**
     * @dev Convert shares to assets for a specific validator (EIP-4626 style)
     * @param _valId The validator ID
     * @param _shares The number of shares to convert
     * @return _assets The equivalent amount of assets
     */
    function _convertToAssets(uint64 _valId, uint256 _shares) internal returns (uint256 _assets) {
        uint256 _totalAssets = _getTotalStakedToValidator(_valId);
        uint256 _totalShares = _getGVaultStorage()._totalSharesByValidator[_valId];

        // Handle edge case: no shares exist (shouldn't happen in normal operation)
        if (_totalShares == 0) {
            return 0;
        }

        // Calculate assets proportionally: assets = shares * total_assets / total_shares
        // Round down to favor the vault (conservative approach for redemptions)
        return (_shares * _totalAssets) / _totalShares;
    }

    /**
     * @notice Internal function to authorize contract upgrades
     * @dev Only allows the Magma admin to authorize upgrades. Required by UUPSUpgradeable
     * @dev https://docs.openzeppelin.com/contracts/5.x/api/proxy#UUPSUpgradeable
     */
    /* solhint-disable-next-line no-empty-blocks */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
