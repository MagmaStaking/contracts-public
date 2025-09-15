// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

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

contract gVault is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable, IGVault, VaultBase {
    using BitMapLib for BitMapLib.WithdrawalBitMap;
    // Track user positions: shares delegated per validator id (EIP-4626 style)

    mapping(address => mapping(uint64 => uint256)) public delegatedSharesOf; // user => valId => shares
    mapping(uint64 => uint256) public totalSharesByValidator; // valId => total shares issued for this validator

    uint256 public minQueueDelaySeconds;
    uint256 public lastRebalanceTimestamp;
    uint256 public epochSeconds;
    bool public finishedLastRebalance = true;

    // pause withdrawals for a validator an epoch before removing
    mapping(uint64 => uint256) public pausedWithdrawalsForValidator;

    // Per-validator deposit caps; if zero, use defaultCapPercent of Magma.totalAssets()
    mapping(uint64 => uint256) public validatorCap;
    // Default cap percent in basis points (1% = 100 bps)
    uint256 public defaultCapBps = 25; // 0.25%

    function initialize(address _magma, uint256 _minQueueDelaySeconds, uint256 _epochSeconds) external initializer {
        __ReentrancyGuard_init();
        __VaultBase_init(_magma);
        magma = IMagma(_magma);
        minQueueDelaySeconds = _minQueueDelaySeconds;
        epochSeconds = _epochSeconds;
    }

    // Accept native funds returned from delegation completion
    receive() external payable {}

    function pauseWithdrawalsForValidator(uint64 valId) external onlyAdmin {
        pausedWithdrawalsForValidator[valId] = block.timestamp;
    }

    function resumeWithdrawalsForValidator(uint64 valId) external onlyAdmin {
        pausedWithdrawalsForValidator[valId] = 0;
    }

    // Admin: manage whitelist
    function addValidator(uint64 valId) external onlyAdmin {
        _registerValidator(valId);
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
    function changeValidatorCap(uint64 valId, uint256 newCap) external onlyAdmin {
        if (!isWhitelisted[valId]) revert ErrNotWhitelisted();
        validatorCap[valId] = newCap;
        emit CapChanged(valId, newCap);
    }

    // Admin: update default cap percent (bps)
    function setDefaultCapBps(uint256 newBps) external onlyAdmin {
        if (newBps > 10_000) revert ErrInvalidBps();
        defaultCapBps = newBps;
        emit DefaultCapUpdated(newBps);
    }

    function _maxCapFor(uint64 valId) internal view returns (uint256) {
        uint256 cap = validatorCap[valId];
        if (cap != 0) return cap;

        uint256 total = magma.totalAssets();
        return (total * defaultCapBps) / 10_000;
    }

    /**
     * @notice Get the amount of assets corresponding to user's shares for a validator
     * @param user The user address
     * @param valId The validator ID
     * @return assets The amount of assets the user's shares represent
     */
    function delegatedAmountOf(address user, uint64 valId) external view returns (uint256 assets) {
        return _convertToAssets(valId, delegatedSharesOf[user][valId]);
    }

    function delegate(address user, uint64 valId) external payable onlyMagma {
        if (!isWhitelisted[valId]) revert ErrNotWhitelisted();
        if (user == address(0)) revert ErrZeroAddress();
        // Cap check
        uint256 cap = _maxCapFor(valId);
        if (cap == 0) revert ErrCapZero();
        uint256 newAmt = _getTotalStakedToValidator(valId) + msg.value;
        if (newAmt > cap) revert ErrExceedsCap();

        // Convert assets to shares based on current exchange rate
        uint256 sharesToMint = _convertToShares(valId, msg.value);

        // Execute delegation to validator
        _delegate(valId, msg.value);

        // Update user's share position
        delegatedSharesOf[user][valId] += sharesToMint;
        totalSharesByValidator[valId] += sharesToMint;

        emit PositionUpdated(user, valId, msg.value, true);
    }

    function undelegate(address user, uint64 _valId, uint256 amount) external onlyMagma {
        if (amount < minUserWithdrawAmount) {
            revert ErrBelowMinWithdraw(minUserWithdrawAmount);
        }
        //undelegate just adds to the queue
        if (!isWhitelisted[_valId]) revert ErrNotWhitelisted();
        if (user == address(0)) revert ErrZeroAddress();

        // Convert amount to shares to determine how many shares to burn
        uint256 sharesToBurn = _convertToShares(_valId, amount);

        // Check if user has sufficient shares
        if (delegatedSharesOf[user][_valId] < sharesToBurn) {
            uint256 userAssets = _convertToAssets(_valId, delegatedSharesOf[user][_valId]);
            revert ErrInsufficientDelegated(amount, userAssets);
        }

        // Burn shares from user
        delegatedSharesOf[user][_valId] -= sharesToBurn;
        totalSharesByValidator[_valId] -= sharesToBurn;

        if (amount > 0) {
            uint8 _wid = _allocateWIDandUndelegate(_valId, amount);

            // Store withdrawal request information
            _storeWithdrawalRequest(user, amount, _valId, _wid);

            // Track pending; do not lower local delegated until completion
            pendingUndelegateByValidator[_valId] += amount;
            totalPendingUndelegations += amount;
        }
    }

    function completeUserWithdrawal(address _user) external nonReentrant returns (uint256 _totalWithdrawn) {
        return _completeUserWithdrawal(_user);
    }

    // Admin: initiate undelegation across all validators by basis points
    // This function is used when liquidity for CoreVault is depleted. Similar functionality exists in Lido v3.
    function adminInitiateRebalanceBps(uint16 bps) external onlyAdmin {
        if (!finishedLastRebalance) revert ErrRebalanceInProgress();
        if (epochSeconds != 0) {
            if (block.timestamp < lastRebalanceTimestamp + epochSeconds) {
                revert ErrEpochGuard();
            }
        }
        if (bps > 10_000) revert ErrInvalidBps();
        uint64[] memory list = validators;
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            uint64 v = list[i];
            // Decode vault-level delegation from precompile
            uint256 amt = _getDelegatorStake(v, address(this));
            uint256 pull = (amt * bps) / 10_000;
            if (pull > 0) {
                uint8 wid = ADMIN_WID;
                _undelegate(v, pull, wid);
            }
        }
        emit AdminInitiatedRebalance(bps);
        lastRebalanceTimestamp = block.timestamp;
    }

    // Admin: complete matured rebalancewithdrawals and forward to Magma
    function adminCompleteRebalance() public onlyAdmin nonReentrant {
        uint64[] memory list = validators;
        uint256 beforeBal = address(this).balance;
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            uint64 valId = list[i];

            (bool exists, uint256 amt,,) = _getWithdrawalRequest(valId, address(this), ADMIN_WID);
            if (!exists || amt == 0) continue;
            if (_tryWithdraw(valId, ADMIN_WID)) {
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

    /**
     * @dev Convert assets to shares for a specific validator (EIP-4626 style)
     * @param valId The validator ID
     * @param assets The amount of assets to convert
     * @return shares The equivalent number of shares
     */
    function _convertToShares(uint64 valId, uint256 assets) internal view returns (uint256 shares) {
        uint256 totalAssets = _getTotalStakedWithPendingToValidator(valId);
        uint256 totalShares = totalSharesByValidator[valId];

        if (totalShares == 0 || totalAssets == 0) {
            // Initial deposit: 1:1 ratio
            return assets;
        }

        // Round down to favor the vault (EIP-4626 requirement)
        return (assets * totalShares) / totalAssets;
    }

    /**
     * @dev Convert shares to assets for a specific validator (EIP-4626 style)
     * @param valId The validator ID
     * @param shares The number of shares to convert
     * @return assets The equivalent amount of assets
     */
    function _convertToAssets(uint64 valId, uint256 shares) internal view returns (uint256 assets) {
        uint256 totalAssets = _getTotalStakedWithPendingToValidator(valId);
        uint256 totalShares = totalSharesByValidator[valId];

        if (totalShares == 0) {
            return 0;
        }

        // Round down to favor the vault
        return (shares * totalAssets) / totalShares;
    }

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != magma.admin()) revert ErrNotAdmin();
    }

    uint256[50] private __gap;
}
