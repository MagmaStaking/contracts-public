// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MagmaBase} from "./MagmaBase.sol";
import {MagmaRoleManagementModule} from "./MagmaRoleManagementModule.sol";
import {
    ErrZeroNativeAsset,
    ErrCoreVaultNotSet,
    ErrGVaultNotSet,
    ErrDelegateFailed,
    ErrGVDelegateFailed
} from "./MagmaErrorsModule.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IGVault} from "../interfaces/IGVault.sol";

// TODO: fr -> what is this for?
abstract contract MagmaNativeDepositModule is MagmaRoleManagementModule {
    using Math for uint256;

    function depositMon() external payable whenNotPaused returns (uint256 shares) {
        shares = _processNativeDeposit();
        _delegateToCoreVault(msg.value);
        emit Deposit(msg.sender, msg.sender, msg.value, shares);
    }

    // TODO: referralId?
    function depositMon(bytes32 referralId) external payable whenNotPaused returns (uint256 shares) {
        shares = _processNativeDeposit();
        _delegateToCoreVault(msg.value);
        if (referralId != bytes32(0)) {
            emit Referral(msg.sender, msg.sender, msg.value, shares, referralId);
        }
    }

    // TODO: should be gVault and depositMonToVault
    function depositMonToVault(uint64 valId) external payable whenNotPaused returns (uint256 shares) {
        if (address(gVault) == address(0)) revert ErrGVaultNotSet();
        shares = _processNativeDeposit();
        _delegateToGVault(valId, msg.value);
        emit Deposit(msg.sender, msg.sender, msg.value, shares);
    }

    /**
     * @dev Processes native asset deposit: validates amount, calculates shares, mints tokens
     * @return shares The number of shares minted for the deposit
     */
    function _processNativeDeposit() private returns (uint256 shares) {
        if (msg.value == 0) revert ErrZeroNativeAsset();
        uint256 assets = msg.value;
        uint256 supply = totalSupply();
        uint256 totalAssetsBefore = totalAssets();
        shares = (supply == 0) ? assets : assets.mulDiv(supply, totalAssetsBefore, Math.Rounding.Floor);
        _mint(msg.sender, shares);
        _delegatedNativeAssets += assets;
    }

    /**
     * @dev Delegates assets to the core vault
     * @param assets Amount of assets to delegate
     */
    function _delegateToCoreVault(uint256 assets) private {
        coreVault.delegate{value: assets}();
    }

    /**
     * @dev Delegates assets to a specific validator through gVault
     * @param valId Validator ID to delegate to
     * @param assets Amount of assets to delegate
     */
    function _delegateToGVault(uint64 valId, uint256 assets) private {
        gVault.delegate{value: assets}(msg.sender, valId);
    }
}
