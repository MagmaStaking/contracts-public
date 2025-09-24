// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {MagmaDelegationModule} from "./MagmaDelegationModule.sol";
import {IMagma} from "../interfaces/IMagma.sol";
import {IGVault} from "../interfaces/IGVault.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {DelInfo} from "./MagmaDelegationModule.sol";
import {BitMapLib} from "./utils/BitMapLib.sol";
import {VaultBase} from "./VaultBase.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    ErrNotWhitelisted,
    ErrInvalidBps,
    ErrZeroAddress,
    ErrCapZero,
    ErrExceedsCap,
    ErrBelowMinWithdraw,
    ErrInsufficientDelegated,
    ErrRebalanceInProgress,
    ErrNotAdmin
} from "./MagmaErrorsModule.sol";

contract gVault is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable, IGVault, VaultBase {
    using BitMapLib for BitMapLib.WithdrawalBitMap;

    /// @dev EIP-4626 style share tracking: tracks user's share ownership per validator
    mapping(address => mapping(uint64 => uint256)) public delegatedSharesOf; // user => valId => shares
    /// @dev Total shares issued for each validator (used for share-to-asset conversion)
    mapping(uint64 => uint256) public totalSharesByValidator; // valId => total shares issued for this validator

    /// @dev Timestamp of the last admin rebalance operation
    uint256 public lastRebalanceTimestamp;
    /// @dev Duration in seconds between allowed operations (currently unused but kept for consistency)
    uint256 public epochSeconds;
    /// @dev Flag indicating if the last admin rebalance has completed both phases
    bool public finishedLastRebalance;


    /// @dev Per-validator absolute deposit caps in wei. If 0, uses defaultCapBps percentage instead
    mapping(uint64 => uint256) public validatorCap;
    /// @dev Default cap as percentage of total Magma assets in basis points (25 = 0.25%)
    uint256 public defaultCapBps; // 0.25%

    // =========================
    // Liquity-style multiplier tracking for admin rebalances
    // =========================
    /// @dev High-precision (1e27) cumulative retention multiplier for gVault
    /// Tracks the fraction of assets remaining after admin rebalances
    /// P = P_prev * (1 - rebalance_bps/10000) for each rebalance
    uint256 public gvaultMultiplierP; // cumulative retention multiplier P for gVault
    
    /// @dev Global scale factor (1e27) that increases during rescaling to maintain precision
    /// The ratio P/S determines user entitlements: entitlement = principal_units * P / S
    uint256 public gvaultScaleS; // global scale S; rescaled with P to keep ratio stable

    /// @dev User's scaled principal contribution per validator
    /// Formula: units += ceil(deposit_amount * S / P_at_deposit_time)
    /// Withdrawal entitlement = units * current_P / current_S
    mapping(address => mapping(uint64 => uint256)) internal scaledPrincipalUnits;

    /// @dev Threshold below which P is rescaled to prevent precision loss (1e20)
    uint256 internal constant MULTIPLIER_FLOOR = 1e20; // if P < this, rescale
    /// @dev Rescaling factor applied to both P and S to maintain their ratio (1e9)
    uint256 internal constant MULTIPLIER_RESCALE_K = 1e9; // multiply P and S by K

    event GVaultMultiplierUpdated(uint256 oldP, uint256 newP, uint16 bps);
    event GVaultRescaled(uint256 factorK, uint256 newP, uint256 newS);

    /**
     * @notice Initialize the gVault contract with configuration parameters
     * @dev Sets up the vault with Magma protocol address, epoch timing, and multiplier system
     * @param _magma The address of the Magma protocol contract
     * @param _epochSeconds The duration of each epoch in seconds
     */
    function initialize(address _magma, uint256 _epochSeconds) external initializer {
        __ReentrancyGuard_init();
        __VaultBase_init(_magma);
        magma = IMagma(_magma);
        epochSeconds = _epochSeconds;
        finishedLastRebalance = true; // Initialize to true so rebalancing can start
        // initialize multiplier system for proxies (declarations don't run)
        defaultCapBps = 25;
        gvaultMultiplierP = 1e27;
        gvaultScaleS = 1e27;
    }

    /**
     * @notice Accept native MON funds returned from delegation operations
     * @dev Allows the contract to receive MON from validator delegation completions
     */
    receive() external payable {}

    /**
     * @notice Add a new validator to the whitelist
     * @dev Registers a validator as eligible for delegation in the gVault
     * @param _valId The validator ID to add
     */
    function addValidator(uint64 _valId) external onlyAdmin {
        _registerValidator(_valId);
    }

    /**
     * @notice Initiate the removal process for a validator
     * @dev Starts the validator removal process by pausing and removing from active list
     * @param _valId The validator ID to remove
     */
    function initiateValidatorRemoval(uint64 _valId) external onlyAdmin {
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

        // Send withdrawal amount to CoreVault
        if (_withdrawalAmount > 0) {
            address coreVaultAddress = magma.coreVault();
            ICoreVault(coreVaultAddress).delegate{value: _withdrawalAmount}();
        }
    }

    /**
     * @notice Get all registered validator IDs
     * @dev Returns array of validator IDs currently registered in the gVault
     * @return Array of validator IDs
     */
    function getvalidators() external view returns (uint64[] memory) {
        return validators;
    }

    /**
     * @notice Set a specific deposit cap for a validator
     * @dev Updates the maximum amount that can be delegated to a specific validator.
     *      If set to 0, the validator will use the default cap (percentage of total assets).
     *      If non-zero, the validator uses this absolute cap amount.
     * @param _valId The validator ID to set cap for
     * @param _newCap The new cap amount (0 to use default percentage cap, non-zero for absolute cap)
     */
    function changeValidatorCap(uint64 _valId, uint256 _newCap) external onlyAdmin {
        if (!isWhitelisted[_valId]) revert ErrNotWhitelisted();
        validatorCap[_valId] = _newCap;
        emit CapChanged(_valId, _newCap);
    }

    /**
     * @notice Set the default deposit cap percentage
     * @dev Updates the default cap as a percentage of total Magma assets
     * @param _newBps The new cap percentage in basis points (e.g., 25 = 0.25%)
     */
    function setDefaultCapBps(uint256 _newBps) external onlyAdmin {
        if (_newBps > BASE_BPS) revert ErrInvalidBps();
        defaultCapBps = _newBps;
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
        uint256 cap = validatorCap[_valId];
        if (cap != 0) return cap;

        uint256 total = magma.totalAssets();
        return (total * defaultCapBps) / BASE_BPS;
    }

    /**
     * @notice Get the amount of assets corresponding to user's shares for a validator
     * @param _user The user address
     * @param _valId The validator ID
     * @return _assets The amount of assets the user's shares represent
     */
    function delegatedAmountOf(address _user, uint64 _valId) external view returns (uint256 _assets) {
        return _convertToAssets(_valId, delegatedSharesOf[_user][_valId]);
    }

    /**
     * @notice Delegate MON to a specific validator on behalf of a user
     * @dev Converts MON to shares, tracks user position, and delegates to validator.
     *      Enforces validator caps and updates multiplier-based tracking.
     * @param _user The user address receiving the shares
     * @param _valId The validator ID to delegate to
     */
    function delegate(address _user, uint64 _valId) external payable onlyMagma {
        if (!isWhitelisted[_valId]) revert ErrNotWhitelisted();
        if (_user == address(0)) revert ErrZeroAddress();
        // Cap check
        uint256 _cap = _maxCapFor(_valId);
        if (_cap == 0) revert ErrCapZero();
        uint256 newAmt = _getTotalStakedWithPendingToValidator(_valId) + msg.value;
        if (newAmt > _cap) revert ErrExceedsCap();

        // Convert assets to shares based on current exchange rate
        uint256 _sharesToMint = _convertToShares(_valId, msg.value);

        // Execute delegation to validator
        _delegate(_valId, msg.value);

        _trackCachedDelegation(msg.value);

        // Update multiplier-based scaled principal units for the user
        // This tracks the user's "principal" contribution for withdrawal entitlement calculations
        if (msg.value > 0) {
            // Calculate units = ceil(deposit_amount * S / P) to track user's contribution
            // Using ceiling to prevent precision erosion in user's favor
            uint256 _addUnits = Math.mulDiv(msg.value, gvaultScaleS, gvaultMultiplierP, Math.Rounding.Ceil);
            scaledPrincipalUnits[_user][_valId] += _addUnits;
        }

        // Update user's share position
        delegatedSharesOf[_user][_valId] += _sharesToMint;
        totalSharesByValidator[_valId] += _sharesToMint;

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
    function undelegate(address _user, uint64 _valId, uint256 _amount) external onlyMagma {
        if (_amount < minUserWithdrawAmount) {
            revert ErrBelowMinWithdraw(minUserWithdrawAmount);
        }
        //undelegate just adds to the queue
        if (!isWhitelisted[_valId]) revert ErrNotWhitelisted();
        if (_user == address(0)) revert ErrZeroAddress();

        // Convert amount to shares to determine how many shares to burn
        uint256 _sharesToBurn = _convertToShares(_valId, _amount);

        // Check if user has sufficient shares
        if (delegatedSharesOf[_user][_valId] < _sharesToBurn) {
            uint256 userAssets = _convertToAssets(_valId, delegatedSharesOf[_user][_valId]);
            revert ErrInsufficientDelegated(_amount, userAssets);
        }

        // Burn shares from user
        delegatedSharesOf[_user][_valId] -= _sharesToBurn;
        totalSharesByValidator[_valId] -= _sharesToBurn;

        if (_amount > 0) {
            // Reduce scaled principal units proportionally to withdrawal amount
            // Calculate units to remove = ceil(withdrawal_amount * S / P)
            uint256 _currentUnits = scaledPrincipalUnits[_user][_valId];
            uint256 _removeUnits = Math.mulDiv(_amount, gvaultScaleS, gvaultMultiplierP, Math.Rounding.Ceil);
            // Prevent underflow: if removing more units than available, set to 0
            scaledPrincipalUnits[_user][_valId] = _removeUnits >= _currentUnits ? 0 : (_currentUnits - _removeUnits);

            uint8 _wid = _allocateWIDandUndelegate(_valId, _amount);

            // Store withdrawal request information
            _storeWithdrawalRequest(_user, _amount, _valId, _wid);

            // Track pending; do not lower local delegated until completion
            pendingUndelegateByValidator[_valId] += _amount;
            totalPendingUndelegations += _amount;

            // Track undelegation for caching
            _trackCachedUndelegation(_amount);
        }
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
        returns (uint256 _totalWithdrawn, uint256 _totalWithdrawnAfterFee)
    {
        return _completeUserWithdrawal(_user);
    }

    /**
     * @notice Initiate admin rebalance by undelegating a percentage from all validators
     * @dev Undelegates specified basis points from all validators to provide liquidity to CoreVault.
     *      Updates the gVault multiplier system to track user entitlements properly.
     *      Similar functionality exists in Lido v3 for liquidity management.
     * @param _bps The basis points to undelegate (e.g., 1000 = 10%)
     */
    function adminInitiateRebalanceBps(uint16 _bps) external onlyAdmin {
        if (!finishedLastRebalance) revert ErrRebalanceInProgress();

        if (_bps > BASE_BPS) revert ErrInvalidBps();
        
        // Handle edge case of 100% rebalance (complete liquidation)
        if (_bps == BASE_BPS) {
            // Special handling for 100% outflow: prevent P from hitting zero which would break math
            // Scale up S massively so existing user units become worthless (entitlement ≈ 0)
            uint256 K_FULL = 1e9; // large-but-safe scale bump
            gvaultScaleS = gvaultScaleS * K_FULL;
            gvaultMultiplierP = 1e27; // reset P to nominal 1.0 in 1e27 scale
            emit GVaultRescaled(K_FULL, gvaultMultiplierP, gvaultScaleS);
        } else {
            // Update cumulative multiplier P to reflect what fraction stays in gVault
            // P_new = P_old * (1 - bps/10000) tracks cumulative retention
            uint256 _oldP = gvaultMultiplierP;
            uint256 _factor1e27 = uint256(BASE_BPS - _bps) * 1e23; // Convert (1 - bps/10000) to 1e27 scale
            gvaultMultiplierP = Math.mulDiv(gvaultMultiplierP, _factor1e27, 1e27, Math.Rounding.Ceil); // round up to prevent erosion
            emit GVaultMultiplierUpdated(_oldP, gvaultMultiplierP, _bps);

            // Prevent precision loss: if P gets too small, rescale both P and S by same factor
            // This maintains the ratio P/S while bringing P back to a safe range
            if (gvaultMultiplierP < MULTIPLIER_FLOOR) {
                gvaultMultiplierP *= MULTIPLIER_RESCALE_K;
                gvaultScaleS *= MULTIPLIER_RESCALE_K;
                emit GVaultRescaled(MULTIPLIER_RESCALE_K, gvaultMultiplierP, gvaultScaleS);
            }
        }
        uint64[] memory _list = validators;
        uint256 n = _list.length;
        finishedLastRebalance = false; // Mark rebalance as in progress
        for (uint256 i = 0; i < n; ++i) {
            uint64 v = _list[i];
            // Decode vault-level delegation from precompile
            uint256 amt = _getDelegatorStake(v, address(this));
            uint256 pull = (amt * _bps) / BASE_BPS;
            if (pull > 0) {
                _checkFreeAdminWid(v);
                _allocateAdminWidAndUndelegate(v, pull);
                pendingRedelegateByValidator[v] = pull;
                totalPendingRedelegation += pull;

                // Track undelegation for caching
                _trackCachedUndelegation(pull);
            }
        }
        emit AdminInitiatedRebalance(_bps);
        lastRebalanceTimestamp = block.timestamp;
    }

    /**
     * @notice Complete admin rebalance by withdrawing matured undelegations
     * @dev Completes all pending admin withdrawals and forwards funds to CoreVault
     *      through Magma protocol. Marks the rebalance process as finished.
     */
    function adminCompleteRebalance() public onlyAdmin nonReentrant {
        uint64[] memory _list = validators;
        uint256 _beforeBal = address(this).balance;
        uint256 _n = _list.length;
        // Process each validator's pending admin withdrawal
        for (uint256 i = 0; i < _n; ++i) {
            uint64 _valId = _list[i];

            (bool exists, uint256 amt,,) = _getWithdrawalRequest(_valId, address(this), ADMIN_WID);
            if (!exists || amt == 0) continue; // Skip if no pending withdrawal
            
            _withdraw(_valId, ADMIN_WID);
            _markWithdrawalCompleted(_valId, ADMIN_WID);
            emit AdminCompletedRebalanceWithdrawal(_valId, amt);
            // Note: in the case where the withdrawal is slashed we use the cached amount to deduct from totalPendingRedelegation
            totalPendingRedelegation -= pendingRedelegateByValidator[_valId];
            pendingRedelegateByValidator[_valId] = 0;
        }
        uint256 _delta = address(this).balance - _beforeBal;
        if (_delta > 0) {
            ICoreVault(magma.coreVault()).delegate{value: _delta}();
        }
        finishedLastRebalance = true; // Mark rebalance as completed
        emit AdminCompletedRebalance(_delta);
    }

    /**
     * @notice Claim and compound staking rewards for a specific validator
     * @dev Claims rewards from the validator, deducts fees, and re-delegates remaining rewards
     * @param _valId The validator ID to claim rewards from
     */
    function claimAndCompoundRewards(uint64 _valId) external {
        _claimAndCompoundRewards(_valId);
    }

    /**
     * @notice Internal function to claim and compound staking rewards
     * @dev Claims validator rewards, calculates fees, and re-delegates to the same validator
     * @param _valId The validator ID to claim rewards from
     */
    function _claimAndCompoundRewards(uint64 _valId) internal {
        uint256 _startingBalance = address(this).balance;

        uint256 _before = address(this).balance;
        _claim(_valId);
        emit RewardsClaimed(_valId, address(this).balance - _before);
        uint256 _endingBalance = address(this).balance;
        uint256 _rewards = _endingBalance - _startingBalance;

        uint256 _fee = _calculateRewardsFeeAndSend(_rewards);

        uint256 _remaining = _rewards - _fee;
        _delegate(_valId, _remaining);
    }

    /**
     * @dev Convert assets to shares for a specific validator (EIP-4626 style)
     * @param _valId The validator ID
     * @param _assets The amount of assets to convert
     * @return _shares The equivalent number of shares
     */
    function _convertToShares(uint64 _valId, uint256 _assets) internal view returns (uint256 _shares) {
        uint256 _totalAssets = _getTotalStakedWithPendingToValidator(_valId);
        uint256 _totalShares = totalSharesByValidator[_valId];

        // Handle initial deposit case: no existing shares or assets
        if (_totalShares == 0 || _totalAssets == 0) {
            // Initial deposit: 1:1 ratio (1 asset = 1 share)
            return _assets;
        }

        // Calculate shares proportionally: shares = assets * total_shares / total_assets
        // Round down to favor the vault (EIP-4626 requirement for convertToShares)
        return (_assets * _totalShares) / _totalAssets;
    }

    /**
     * @notice Calculate maximum withdrawable amount for a user from gVault only
     * @dev Returns user's entitlement based on multiplier system: units * P / S
     *      This limits withdrawals based on actual contributions vs. rewards earned.
     * @param _user The user address
     * @param _valId The validator ID
     * @return Maximum withdrawable amount from gVault tracking
     */
    function maxWithdrawableFromGVault(address _user, uint64 _valId) public view returns (uint256) {
        // entitlement = units * P / S
        uint256 _units = scaledPrincipalUnits[_user][_valId];
        return Math.mulDiv(_units, gvaultMultiplierP, gvaultScaleS);
    }

    /**
     * @dev Convert shares to assets for a specific validator (EIP-4626 style)
     * @param _valId The validator ID
     * @param _shares The number of shares to convert
     * @return _assets The equivalent amount of assets
     */
    function _convertToAssets(uint64 _valId, uint256 _shares) internal view returns (uint256 _assets) {
        uint256 _totalAssets = _getTotalStakedWithPendingToValidator(_valId);
        uint256 _totalShares = totalSharesByValidator[_valId];

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
     */
    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != magma.admin()) revert ErrNotAdmin();
    }

    /// @dev Reserved storage slots for future contract upgrades. Prevents storage collisions.
    uint256[50] private __gap;
}
