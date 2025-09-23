// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {MagmaDelegationModule} from "./MagmaDelegationModule.sol";
import "./MagmaErrorsModule.sol";
import {IMagma} from "../interfaces/IMagma.sol";
import {IGVault} from "../interfaces/IGVault.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {DelInfo} from "./MagmaDelegationModule.sol";
import {BitMapLib} from "./utils/BitMapLib.sol";
import {VaultBase} from "./VaultBase.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract gVault is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable, IGVault, VaultBase {
    using BitMapLib for BitMapLib.WithdrawalBitMap;

    // Track user positions: shares delegated per validator id (EIP-4626 style)
    mapping(address => mapping(uint64 => uint256)) public delegatedSharesOf; // user => valId => shares
    mapping(uint64 => uint256) public totalSharesByValidator; // valId => total shares issued for this validator

    uint256 public lastRebalanceTimestamp;
    uint256 public epochSeconds;
    bool public finishedLastRebalance;

    // pause withdrawals for a validator an epoch before removing
    mapping(uint64 => uint256) public pausedWithdrawalsForValidator;

    // Per-validator deposit caps; if zero, use defaultCapPercent of Magma.totalAssets()
    mapping(uint64 => uint256) public validatorCap;
    // Default cap percent in basis points (1% = 100 bps)
    uint256 public defaultCapBps; // 0.25%

    // =========================
    // Liquity-style multiplier tracking for admin rebalances
    // =========================
    // Use high-precision 1e27 scaling to avoid collapse to zero and preserve precision.
    uint256 public gvaultMultiplierP; // cumulative retention multiplier P for gVault
    uint256 public gvaultScaleS; // global scale S; rescaled with P to keep ratio stable

    // User scaled principal units per validator: units = sum(assets_at_update * S / P_at_update)
    mapping(address => mapping(uint64 => uint256)) internal scaledPrincipalUnits;

    // Rescale thresholds to avoid P getting too small (tunable)
    uint256 internal constant MULTIPLIER_FLOOR = 1e20; // if P < this, rescale
    uint256 internal constant MULTIPLIER_RESCALE_K = 1e9; // multiply P and S by K

    event GVaultMultiplierUpdated(uint256 oldP, uint256 newP, uint16 bps);
    event GVaultRescaled(uint256 factorK, uint256 newP, uint256 newS);

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

    // Accept native funds returned from delegation completion
    receive() external payable {}

    function pauseWithdrawalsForValidator(uint64 _valId) external onlyAdmin {
        pausedWithdrawalsForValidator[_valId] = block.timestamp;
    }

    function resumeWithdrawalsForValidator(uint64 _valId) external onlyAdmin {
        pausedWithdrawalsForValidator[_valId] = 0;
    }

    // Admin: manage whitelist
    function addValidator(uint64 _valId) external onlyAdmin {
        _registerValidator(_valId);
    }

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

    function getvalidators() external view returns (uint64[] memory) {
        return validators;
    }

    // Admin: set per-validator explicit cap (can increase or decrease)
    function changeValidatorCap(uint64 _valId, uint256 _newCap) external onlyAdmin {
        if (!isWhitelisted[_valId]) revert ErrNotWhitelisted();
        validatorCap[_valId] = _newCap;
        emit CapChanged(_valId, _newCap);
    }

    // Admin: update default cap percent (bps)
    function setDefaultCapBps(uint256 _newBps) external onlyAdmin {
        if (_newBps > BASE_BPS) revert ErrInvalidBps();
        defaultCapBps = _newBps;
        emit DefaultCapUpdated(_newBps);
    }

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

        // Update multiplier-based scaled principal units for the user
        if (msg.value > 0) {
            // units += ceil(assets * S / P) using mulDiv to avoid overflow
            uint256 _addUnits = Math.mulDiv(msg.value, gvaultScaleS, gvaultMultiplierP, Math.Rounding.Ceil);
            scaledPrincipalUnits[_user][_valId] += _addUnits;
        }

        // Update user's share position
        delegatedSharesOf[_user][_valId] += _sharesToMint;
        totalSharesByValidator[_valId] += _sharesToMint;

        emit PositionUpdated(_user, _valId, msg.value, true);
    }

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
            // Reduce scaled principal units by ceil(amount * S / P), bounded to current units
            uint256 _currentUnits = scaledPrincipalUnits[_user][_valId];
            uint256 _removeUnits = Math.mulDiv(_amount, gvaultScaleS, gvaultMultiplierP, Math.Rounding.Ceil);
            scaledPrincipalUnits[_user][_valId] = _removeUnits >= _currentUnits ? 0 : (_currentUnits - _removeUnits);

            uint8 _wid = _allocateWIDandUndelegate(_valId, _amount);

            // Store withdrawal request information
            _storeWithdrawalRequest(_user, _amount, _valId, _wid);

            // Track pending; do not lower local delegated until completion
            pendingUndelegateByValidator[_valId] += _amount;
            totalPendingUndelegations += _amount;
        }
    }

    function completeUserWithdrawal(address _user)
        external
        nonReentrant
        returns (uint256 _totalWithdrawn, uint256 _totalWithdrawnAfterFee)
    {
        return _completeUserWithdrawal(_user);
    }

    // Admin: initiate undelegation across all validators by basis points
    // This function is used when liquidity for CoreVault is depleted. Similar functionality exists in Lido v3.
    function adminInitiateRebalanceBps(uint16 _bps) external onlyAdmin {
        if (!finishedLastRebalance) revert ErrRebalanceInProgress();

        if (_bps > BASE_BPS) revert ErrInvalidBps();
        // Handle 100% outflow without letting P hit zero
        if (_bps == BASE_BPS) {
            // Bump the global scale so previous units' entitlement -> ~0, keep P finite for future math
            uint256 K_FULL = 1e9; // large-but-safe scale bump
            gvaultScaleS = gvaultScaleS * K_FULL;
            gvaultMultiplierP = 1e27; // reset P to nominal 1.0 in 1e27 scale
            emit GVaultRescaled(K_FULL, gvaultMultiplierP, gvaultScaleS);
        } else {
            // Update cumulative gVault multiplier P to reflect retained fraction after moving bps to CoreVault
            uint256 _oldP = gvaultMultiplierP;
            uint256 _factor1e27 = uint256(BASE_BPS - _bps) * 1e23; // 1e27 * (1 - bps/10000)
            gvaultMultiplierP = Math.mulDiv(gvaultMultiplierP, _factor1e27, 1e27, Math.Rounding.Ceil); // round up to prevent erosion
            emit GVaultMultiplierUpdated(_oldP, gvaultMultiplierP, _bps);

            // Rescale if P drops near zero to preserve precision; ratio P/S remains unchanged
            if (gvaultMultiplierP < MULTIPLIER_FLOOR) {
                gvaultMultiplierP *= MULTIPLIER_RESCALE_K;
                gvaultScaleS *= MULTIPLIER_RESCALE_K;
                emit GVaultRescaled(MULTIPLIER_RESCALE_K, gvaultMultiplierP, gvaultScaleS);
            }
        }
        uint64[] memory _list = validators;
        uint256 n = _list.length;
        finishedLastRebalance = false; // Mark rebalance as in progress
        for (uint256 i = 0; i < n; i++) {
            uint64 v = _list[i];
            // Decode vault-level delegation from precompile
            uint256 amt = _getDelegatorStake(v, address(this));
            uint256 pull = (amt * _bps) / BASE_BPS;
            if (pull > 0) {
                _checkFreeAdminWid(v);
                _allocateADMIN_WIDandUndelegate(v, pull);
                pendingRedelegateByValidator[v] = pull;
                totalPendingRedelegation += pull;
            }
        }
        emit AdminInitiatedRebalance(_bps);
        lastRebalanceTimestamp = block.timestamp;
    }

    // Admin: complete matured rebalancewithdrawals and forward to Magma
    function adminCompleteRebalance() public onlyAdmin nonReentrant {
        uint64[] memory _list = validators;
        uint256 _beforeBal = address(this).balance;
        uint256 _n = _list.length;
        for (uint256 i = 0; i < _n; i++) {
            uint64 _valId = _list[i];

            (bool exists, uint256 amt,,) = _getWithdrawalRequest(_valId, address(this), ADMIN_WID);
            if (!exists || amt == 0) continue;
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

    function claimAndCompoundRewards(uint64 _valId) external {
        _claimAndCompoundRewards(_valId);
    }

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

        if (_totalShares == 0 || _totalAssets == 0) {
            // Initial deposit: 1:1 ratio
            return _assets;
        }

        // Round down to favor the vault (EIP-4626 requirement)
        return (_assets * _totalShares) / _totalAssets;
    }

    // =========================
    // Views for entitlement limiting from gVault only
    // =========================
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

        if (_totalShares == 0) {
            return 0;
        }

        // Round down to favor the vault
        return (_shares * _totalAssets) / _totalShares;
    }

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != magma.admin()) revert ErrNotAdmin();
    }

    uint256[50] private __gap;
}
