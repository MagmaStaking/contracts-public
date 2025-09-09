// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WrappedMonad} from "../monad/WrappedMonad.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {MagmaRoleManagementModule} from "./MagmaRoleManagementModule.sol";
import {
    ErrGVaultNotSet,
    ErrZeroShares,
    ErrNativeTransferFailed,
    ErrNotAuthorized,
    ErrInsufficientShares,
    ErrRequestPending
} from "./MagmaErrorsModule.sol";

/// @dev Implementation of ERC-7540 as defined in https://eips.ethereum.org/EIPS/eip-7540.
abstract contract MagmaAsyncModule is MagmaRoleManagementModule {
    using Math for uint256;

    /**
     * @dev Return the total assets managed by the vault, including delegated native and held WMON
     */
    // TODO: fr -> this would be changed by corevault, also test
    function totalAssets() public view virtual override returns (uint256) {
        return _delegatedNativeAssets + IERC20(asset()).balanceOf(address(this));
    }

    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    /// @dev Withdraws WMON to MON so it can stake it
    function mint(uint256 shares, address receiver) public virtual override whenNotPaused returns (uint256) {
        uint256 assets = previewMint(shares);
        uint256 minted = super.mint(shares, receiver);
        WrappedMonad(payable(address(asset()))).withdraw(assets);
        _delegatedNativeAssets += assets;
        coreVault.delegate{value: assets};
        emit DepositWithReferral(msg.sender, receiver, assets, shares, 0);
        return minted;
    }

    function _deposit(uint256 assets, address receiver) private whenNotPaused returns (uint256) {
        uint256 shares = super.deposit(assets, receiver);
        WrappedMonad(payable(address(asset()))).withdraw(assets);
        _delegatedNativeAssets += assets;
        return shares;
    }

    /// @dev Withdraws WMON to MON so it can stake it
    function deposit(uint256 assets, address receiver) public virtual override whenNotPaused returns (uint256) {
        uint256 shares = _deposit(assets, receiver);
        coreVault.delegate{value: assets};
        emit DepositWithReferral(msg.sender, receiver, assets, shares, 0);
        return shares;
    }

    // TODO: (lossess will be socialized) check deposit and withdrawal of gVault, what if gVault was 100% vanished, standard calculation does not work, what if the vault you deposit is already with a lower assets to shares ratio
    function depositToGVault(uint256 assets, address receiver, uint64 valId, uint256 referralId)
        external
        whenNotPaused
        returns (uint256)
    {
        uint256 shares = _deposit(assets, receiver);
        gVault.delegate{value: assets}(receiver, valId);
        emit DepositWithReferral(msg.sender, receiver, assets, shares, referralId);
        return shares;
    }

    /// @notice Allows to set a referralId which will be used to reward points to the referrer (in case it qualifies)
    function depositWMON(uint256 assets, address receiver, uint256 referralId) public whenNotPaused returns (uint256) {
        uint256 shares = _deposit(assets, receiver);
        coreVault.delegate{value: assets};
        emit DepositWithReferral(msg.sender, receiver, assets, shares, referralId);
        return shares;
    }

    /// @notice Allows to set a referralId which will be used to reward points to the referrer (in case it qualifies)
    function depositMON(address receiver, uint256 referralId) external payable whenNotPaused returns (uint256) {
        WrappedMonad(payable(address(asset()))).deposit{value: msg.value}();
        return depositWMON(msg.value, receiver, referralId);
    }

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId) {
        return _requestRedeem(shares, controller, owner, 0, false);
    }

    function requestRedeemFromGVault(uint256 shares, address controller, address owner, uint64 valId)
        external
        returns (uint256 requestId)
    {
        return _requestRedeem(shares, controller, owner, valId, true);
    }

    /**
     * @param controller The designated controller will be responsible for claiming the assets of the owner after the
     * request is available.
     * @param owner Owner of the shares.
     * @dev An operator is just an account that can manage Requests on behalf of another account, either an owner or a
     * controller.
     * @dev Since we are using requestIds, an owner can do multiple requests and multiple claims without being locked by
     * former requests or claims: https://eips.ethereum.org/EIPS/eip-7540#request-ids.
     * @dev Requests are not yield bearing; no yield will accrue after the request is made.
     * @dev https://eips.ethereum.org/EIPS/eip-7540#symmetry-and-non-inclusion-of-requestwithdraw-and-requestmint
     * @dev https://eips.ethereum.org/EIPS/eip-7540#methods
     */
    function _requestRedeem(uint256 shares, address controller, address owner, uint64 valId, bool isGVault)
        private
        whenNotPaused
        returns (uint256 requestId)
    {
        if (shares == 0) revert ErrZeroShares();
        if (!(owner == msg.sender || isOperator[owner][msg.sender])) {
            revert ErrNotAuthorized();
        }
        if (shares > balanceOf(owner)) {
            revert ErrInsufficientShares(shares, balanceOf(owner));
        }

        uint256 assets = convertToAssets(shares);
        pendingRedeemRequests[controller][_requestIdCount] =
            RedeemRequests({shares: shares, assets: assets, claimableTime: block.timestamp + DEFAULT_DELAY});
        _requestIdCount++;

        _transfer(owner, address(this), shares);

        _delegatedNativeAssets -= assets;
        isGVault ? _undelegateFromValidator(valId, assets) : _undelegate(assets);

        emit RedeemRequest(controller, owner, _requestIdCount, msg.sender, shares);
        return _requestIdCount;
    }

    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares) {
        return pendingRedeemRequests[controller][requestId].shares;
    }

    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares) {
        RedeemRequests memory request = pendingRedeemRequests[controller][requestId];
        return request.claimableTime >= block.timestamp ? request.shares : 0;
    }

    /**
     * @param controller was designated by owner in _requestRedeem to manage the claim of the shares
     * @param receiveWMON States if the request should be fulfilled in WMON or MON
     * @dev Compares asset values at request time and claim time, using the lower value to protect against slashing.
     * This prevents exploitation of price differences during the two-step redemption process. For example, if
     * slashing occurs between request and claim, the user receives the lower post-slashing amount rather than
     * the higher pre-slashing amount.
     */
    // TODO: see if we can change name of claimRequest to redeem after fixing inheritance chain, make two functions redeem and redeemMON
    function claimRequest(uint256 requestId, address controller, address receiver, bool receiveWMON)
        external
        whenNotPaused
    {
        if (!(controller == msg.sender || isOperator[controller][msg.sender])) {
            revert ErrNotAuthorized();
        }
        RedeemRequests memory request = pendingRedeemRequests[controller][requestId];
        if (request.claimableTime < block.timestamp) {
            revert ErrRequestPending();
        }
        uint256 shares = request.assets;
        uint256 assetsAtRequest = request.assets;
        uint256 assetsAtClaim = convertToAssets(shares);
        uint256 assets = Math.min(assetsAtRequest, assetsAtClaim);

        delete pendingRedeemRequests[controller][requestId];
        _burn(address(this), shares);

        if (receiveWMON) {
            WrappedMonad(payable(address(asset()))).deposit{value: assets}();
            WrappedMonad(payable(address(asset()))).transfer(receiver, assets);
        } else {
            (bool sent,) = payable(receiver).call{value: assets}("");
            if (!sent) {
                revert ErrNativeTransferFailed();
            }
        }

        emit Withdraw(controller, receiver, address(this), assets, shares);
    }
}
