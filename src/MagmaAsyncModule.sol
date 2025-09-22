// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WrappedMonad} from "../monad/WrappedMonad.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {MagmaRoleManagementModule} from "./MagmaRoleManagementModule.sol";
import "./MagmaErrorsModule.sol";

/// @dev Implementation of ERC-7540 as defined in https://eips.ethereum.org/EIPS/eip-7540.
abstract contract MagmaAsyncModule is MagmaRoleManagementModule {
    function totalAssets() public view virtual override returns (uint256) {
        return coreVault.totalAssets() + gVault.totalAssets();
    }

    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[_msgSender()][operator] = approved;
        emit OperatorSet(_msgSender(), operator, approved);
        return true;
    }

    /// @dev Withdraws WMON to MON so it can stake it
    function mint(uint256 shares, address receiver)
        public
        virtual
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        uint256 assets = previewMint(shares);
        uint256 minted = super.mint(shares, receiver);
        WrappedMonad(payable(address(asset()))).withdraw(assets);
        coreVault.delegate{value: assets}();
        emit DepositWithReferral(_msgSender(), receiver, assets, shares, 0);
        return minted;
    }

    function _deposit(uint256 assets, address receiver) private returns (uint256) {
        uint256 shares = super.deposit(assets, receiver);
        WrappedMonad(payable(address(asset()))).withdraw(assets);
        return shares;
    }

    /// @dev Withdraws WMON to MON so it can stake it
    function deposit(uint256 assets, address receiver)
        public
        virtual
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        uint256 shares = _deposit(assets, receiver);
        coreVault.delegate{value: assets}();
        emit DepositWithReferral(_msgSender(), receiver, assets, shares, 0);
        return shares;
    }

    function depositGVault(uint256 assets, address receiver, uint64 valId, uint256 referralId)
        external
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        uint256 shares = _deposit(assets, receiver);
        gVault.delegate{value: assets}(receiver, valId);
        emit DepositWithReferral(_msgSender(), receiver, assets, shares, referralId);
        return shares;
    }

    /// @notice Allows to set a referralId which will be used to reward points to the referrer (in case it qualifies)
    function depositWMON(uint256 assets, address receiver, uint256 referralId)
        public
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        uint256 shares = _deposit(assets, receiver);
        coreVault.delegate{value: assets}();
        emit DepositWithReferral(_msgSender(), receiver, assets, shares, referralId);
        return shares;
    }

    /// @notice Allows to set a referralId which will be used to reward points to the referrer (in case it qualifies)
    function depositMON(address receiver, uint256 referralId)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        uint256 assets = msg.value;
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);

        uint256 shares = previewDeposit(assets);

        _mint(receiver, shares);
        emit Deposit(_msgSender(), receiver, assets, shares);

        coreVault.delegate{value: assets}();
        emit DepositWithReferral(_msgSender(), receiver, assets, shares, referralId);

        return shares;
    }

    function requestRedeem(uint256 shares, address controller, address owner)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        uint256 assets = convertToAssets(shares);
        return _requestRedeem(shares, assets, controller, owner, 0, false);
    }

    // TODO: _convertToAssets from gVault in this case, but if you rebalance you will have less assets, check both exchange rates and give him the most assets
    // TODO: what happens in this case if you redeem part of shares from corevault, then you redeem from gvault, will you get all your assets
    function requestRedeemGVault(uint256 shares, address controller, address owner, uint64 valId)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        uint256 assets = convertToAssets(shares);
        if (assets > gVault.maxWithdrawableFromGVault(owner, valId)) {
            revert NotEnoughAssetsGVault();
        }
        return _requestRedeem(shares, assets, controller, owner, valId, true);
    }

    /**
     * @param controller The designated controller will be responsible for claiming the assets of the owner after the
     * request is available.
     * @param owner Owner of the shares.
     * @dev An operator is just an account that can manage Requests on behalf of another account, either an owner or a
     * controller.
     * @dev Since we are using requestIds, a controller can do multiple requests and multiple claims without being
     * locked by former requests or claims. However, only one request per owner is allowed.
     * https://eips.ethereum.org/EIPS/eip-7540#request-ids.
     * @dev Requests are not yield bearing; no yield will accrue after the request is made.
     * @dev https://eips.ethereum.org/EIPS/eip-7540#symmetry-and-non-inclusion-of-requestwithdraw-and-requestmint
     * @dev https://eips.ethereum.org/EIPS/eip-7540#methods
     */
    function _requestRedeem(
        uint256 shares,
        uint256 assets,
        address controller,
        address owner,
        uint64 valId,
        bool isGVault
    ) private returns (uint256) {
        if (controller == address(0)) revert ErrZeroAddress();
        if (_ownerRequested[owner]) revert ErrRequestPending();
        if (shares == 0) revert ErrZeroShares();
        if (!(owner == _msgSender() || isOperator[owner][_msgSender()])) revert ErrNotAuthorized();
        if (shares > balanceOf(owner)) revert ErrInsufficientShares(shares, balanceOf(owner));

        uint256 requestId = _requestIdCount;
        pendingRedeemRequests[controller][requestId] = RedeemRequests({
            owner: owner,
            shares: shares,
            assets: assets,
            claimableTime: block.timestamp + DEFAULT_DELAY,
            isGVault: isGVault
        });
        _requestIdCount++;
        _ownerRequested[owner] = true;

        _burn(owner, shares);

        isGVault ? gVault.undelegate(owner, valId, assets) : coreVault.undelegate(assets, owner);

        emit RedeemRequest(controller, owner, requestId, _msgSender(), shares);
        return requestId;
    }

    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares) {
        return pendingRedeemRequests[controller][requestId].shares;
    }

    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares) {
        RedeemRequests memory request = pendingRedeemRequests[controller][requestId];
        return request.claimableTime <= block.timestamp ? request.shares : 0;
    }

    function redeem(uint256 requestId, address controller, address receiver)
        public
        virtual
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        return _redeem(requestId, controller, receiver, true);
    }

    function redeemMON(uint256 requestId, address controller, address receiver)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        return _redeem(requestId, controller, receiver, false);
    }

    /**
     * @param controller was designated by owner in _requestRedeem to manage the claim of the shares
     * @param receiveWMON States if the request should be fulfilled in WMON or MON
     * @dev Compares asset values at request time and claim time, using the lower value to protect against slashing.
     * This prevents exploitation of price differences during the two-step redemption process. For example, if
     * slashing occurs between request and claim, the user receives the lower post-slashing amount rather than
     * the higher pre-slashing amount.
     */
    function _redeem(uint256 requestId, address controller, address receiver, bool receiveWMON)
        private
        returns (uint256)
    {
        if (!(controller == _msgSender() || isOperator[controller][_msgSender()])) revert ErrNotAuthorized();
        RedeemRequests memory request = pendingRedeemRequests[controller][requestId];
        if (request.claimableTime > block.timestamp) revert ErrRequestPending();
        if (request.claimableTime == 0) revert RequestInexistent();

        address owner = pendingRedeemRequests[controller][requestId].owner;
        delete pendingRedeemRequests[controller][requestId];
        _ownerRequested[owner] = false;

        (uint256 totalWithdrawn, uint256 totalWithdrawnAfterFee) =
            request.isGVault ? gVault.completeUserWithdrawal(owner) : coreVault.completeUserWithdrawal(owner);

        uint256 shares =
            totalWithdrawn < request.assets ? convertToShares(request.assets - totalWithdrawn) : request.shares;
        if (totalWithdrawn < request.assets) {
            /**
             * If withdraw amount gets slashed losses are socialized. Shares minted represent an increase in the supply.
             * Therefore, losess are socialized between all the participants
             */
            _mint(receiver, shares);
        }

        if (receiveWMON) {
            WrappedMonad(payable(address(asset()))).deposit{value: totalWithdrawnAfterFee}();
            WrappedMonad(payable(address(asset()))).transfer(receiver, totalWithdrawnAfterFee);
        } else {
            (bool sent,) = payable(receiver).call{value: totalWithdrawnAfterFee}("");
            if (!sent) {
                revert ErrNativeTransferFailed();
            }
        }

        emit Withdraw(controller, receiver, address(this), totalWithdrawnAfterFee, shares);

        return totalWithdrawnAfterFee;
    }

    /// @dev previewWithdraw MUST revert for all callers and inputs: https://eips.ethereum.org/EIPS/eip-7540#request-flows
    function previewWithdraw(uint256 /*assets*/ ) public view override returns (uint256) {
        revert();
    }

    /// @dev previewRedeem MUST revert for all callers and inputs: https://eips.ethereum.org/EIPS/eip-7540#request-flows
    function previewRedeem(uint256 /*shares*/ ) public view override returns (uint256) {
        revert();
    }

    /**
     * @dev The redeem and withdraw methods do not transfer shares to the Vault, this happens in a two step process via
     * _requestRedeem and claimRequest.
     */
    function withdraw(uint256, /*assets*/ address, /*receiver*/ address /*controller*/ )
        public
        override
        returns (uint256)
    {
        revert();
    }
}
