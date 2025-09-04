// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WrappedMonad} from "../monad/WrappedMonad.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {MagmaRoleManagementModule} from "./MagmaRoleManagementModule.sol";
import {ErrZeroShares, ErrNativeTransferFailed, ErrNotAuthorized, ErrInsufficientShares, ErrRequestPending} from "./MagmaErrorsModule.sol";

// TODO: last -> run tests, what happens if you transfer while requestClaim and reentrnacy
// TODO: last -> organize by external view, public internal etc on code and put in doc
// TODO: last -> explain only one controller, more than one operator, if request id is 0, then only one controller. Explain differences between owner, controller and operator
abstract contract MagmaAsyncModule is MagmaRoleManagementModule {
    using Math for uint256;

    // TODO: last ->  add comments we are wrapping and depositing right before working with the precompile
    /**
     * @dev Return the total assets managed by the vault, including delegated native and held WMON
     */
    function totalAssets() public view override returns (uint256) {
        return
            _delegatedNativeAssets + IERC20(asset()).balanceOf(address(this));
    }

    function deposit(
        uint256 assets,
        address receiver
    ) public override whenNotPaused returns (uint256) {
        uint256 shares = super.deposit(assets, receiver);
        WrappedMonad(payable(address(asset()))).withdraw(assets);
        _delegatedNativeAssets += assets;
        ICoreVault(coreVault).delegate(assets);
        return shares;
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override whenNotPaused returns (uint256) {
        uint256 assets = previewMint(shares);
        uint256 minted = super.mint(shares, receiver);
        WrappedMonad(payable(address(asset()))).withdraw(assets);
        _delegatedNativeAssets += assets;
        ICoreVault(coreVault).delegate(assets);
        return minted;
    }

    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    ) external returns (uint256 requestId) {
        return _requestRedeem(shares, controller, owner, 0, false);
    }

    function requestRedeemFromGVault(
        uint256 shares,
        address controller,
        address owner,
        uint64 valId
    ) external returns (uint256 requestId) {
        return _requestRedeem(shares, controller, owner, valId, true);
    }

    /**
     * TODO: last -> update this comment for multiple requestIds, also say assets will not accumulate yield after this
     * @dev Since requestId is set as 0. The Vault MUST use purely the controller to discriminate the request state.
     * The Pending and Claimable state of multiple requests from the same controller would be aggregated.
     * @dev https://eips.ethereum.org/EIPS/eip-7540#request-ids
     * @dev https://eips.ethereum.org/EIPS/eip-7540#symmetry-and-non-inclusion-of-requestwithdraw-and-requestmint
     * @dev https://eips.ethereum.org/EIPS/eip-7540#methods
     */
    function _requestRedeem(
        uint256 shares,
        address controller,
        address owner,
        uint64 valId,
        bool isGVault
    ) private whenNotPaused returns (uint256 requestId) {
        if (shares == 0) revert ErrZeroShares();
        if (!(owner == msg.sender || isOperator[owner][msg.sender]))
            revert ErrNotAuthorized();
        if (shares > balanceOf(owner))
            revert ErrInsufficientShares(shares, balanceOf(owner));

        uint256 assets = convertToAssets(shares);
        pendingRedeemRequests[controller][requestIdCount] = RedeemRequests({
            shares: shares,
            assets: assets,
            claimableTime: block.timestamp + DEFAULT_DELAY
        });
        requestIdCount++;

        _transfer(owner, address(this), shares);

        _delegatedNativeAssets -= assets;
        isGVault
            ? _undelegateFromValidator(valId, assets)
            : _undelegate(assets);

        emit RedeemRequest(
            controller,
            owner,
            requestIdCount,
            msg.sender,
            shares
        );
        return requestIdCount;
    }

    function pendingRedeemRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 shares) {
        return pendingRedeemRequests[controller][requestId].shares;
    }

    function claimableRedeemRequest(
        uint256 requestId,
        address controller
    ) external view returns (uint256 shares) {
        RedeemRequests memory request = pendingRedeemRequests[controller][
            requestId
        ];
        // TODO: last -> check case here where request does not exist
        return request.claimableTime >= block.timestamp ? request.shares : 0;
    }

    // TODO: want WMON and not in claimRequest
    // TODO: reentranceGuard in withdrawals and this module
    function claimRequest(
        uint256 requestId,
        address controller,
        address receiver
    ) external whenNotPaused {
        // TODO: last ->, what happens wih receiver? should _claimRequest be authorized if it cannot be cancelled revert ErrNotAuthorized();
        RedeemRequests memory request = pendingRedeemRequests[controller][
            requestId
        ];
        // TODO: check case here where request does not exist
        if (request.claimableTime < block.timestamp) {
            revert ErrRequestPending();
        }
        // TODO: last -> set variable as _ check in this whole PR, also check if memory here or not, should not be needed
        uint256 assets = request.assets;
        uint256 shares = request.assets;

        delete pendingRedeemRequests[controller][requestId];
        _burn(address(this), shares);
        (bool sent, ) = payable(receiver).call{value: assets}("");
        if (!sent) {
            revert ErrNativeTransferFailed();
        }

        emit Withdraw(controller, receiver, address(this), assets, shares);
    }
}
