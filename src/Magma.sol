// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {WrappedMonad} from "../monad/WrappedMonad.sol";
import {
    ErrNotEnoughAssetsGVault,
    ErrZeroAddress,
    ErrRequestPending,
    ErrZeroShares,
    ErrNotAuthorized,
    ErrInsufficientShares,
    ErrRequestInexistent,
    ErrNativeTransferFailed,
    ErrNotAdmin,
    ErrZeroAddress
} from "./MagmaErrorsModule.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IGVault} from "../interfaces/IGVault.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @dev Implementation of ERC-7540 as defined in https://eips.ethereum.org/EIPS/eip-7540.
contract Magma is
    Initializable,
    ERC4626Upgradeable,
    ERC165Upgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // TODO: everything in this struct should be underscore
    struct MagmaStorage {
        uint256 _requestIdCount;
        mapping(address owner => bool) _ownerRequested;
        // Mapping from controller to their pending withdrawal requests
        mapping(address controller => mapping(uint256 requestId => RedeemRequests)) _pendingRedeemRequests;
        // Mapping for operator approvals (ERC-7540)
        mapping(address controller => mapping(address operator => bool)) _isOperator;
        // Time in seconds a user needs to wait between requestRedeem and redeem to be able to withdraw his stake
        uint256 _redeemDelay;
        /// @notice The fee for rewards.
        /// @dev The fee is expressed as a bps percentage of the reward amount.
        uint256 _rewardsFee;
        /// @notice The fee for withdrawals.
        /// @dev The fee is expressed as a bps percentage of the withdrawal amount.
        uint256 _withdrawalFee;
        /// @notice The address that receives the fees.
        address _feeReceiver;
        // Admin for Magma, CoreVault validator management, etc
        address _admin;
    }

    // keccak256(abi.encode(uint256(keccak256("storage.Magma")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _MagmaStorageLocation = 0xe12a3c9ed0954edf986cec381af8403b24a0b0b94ceba99e0d4e9dd1e2aec500;

    /// @notice Struct to track pending redeem requests
    /// @dev Claimable state may transition automatically after a timestamp has passed.
    /// @dev https://eips.ethereum.org/EIPS/eip-7540#no-event-for-claimable-state
    /// @dev https://eips.ethereum.org/EIPS/eip-7540#request-lifecycle
    struct RedeemRequests {
        address owner; // Owner of the shares
        uint256 shares; // Amount of shares to redeem
        uint256 assets; // Amount of assets to withdraw
        uint256 claimableTime; // When assets become claimable
        bool isGVault; // If redeemRequest is for gVault or not
    }

    // Vault contract references (to be set by admin)
    ICoreVault public coreVault;
    IGVault public gVault;

    /// @dev Emitted upon a successful deposit, will be sent on every deposit to facilitate on the indexer side
    event DepositWithReferral(
        address indexed sender, address indexed owner, uint256 assets, uint256 shares, uint256 indexed referralId
    );

    // Events for ERC-7540 compatibility and admin
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    event Referral(
        address indexed sender, address indexed receiver, uint256 assets, uint256 shares, bytes32 indexed referralId
    );

    // TODO: does this go after events or not
    // ERC-7540 Asynchronous redemption Vault Interface ID
    bytes4 private constant INTERFACE_ID_ERC7540 = 0x620ee8e4;

    function _getMagmaStorage() private pure returns (MagmaStorage storage $) {
        assembly {
            $.slot := _MagmaStorageLocation
        }
    }

    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address admin_,
        address coreVault_,
        address gVault_,
        uint256 rewardsFee_,
        uint256 withdrawalFee_,
        address feeReceiver_,
        uint256 redeemDelay_
    ) external initializer {
        __MagmaBase_init(asset_, name_, symbol_, admin_, rewardsFee_, withdrawalFee_, feeReceiver_, redeemDelay_);

        coreVault = ICoreVault(coreVault_);
        gVault = IGVault(gVault_);
    }

    /* solhint-disable-next-line func-name-mixedcase */
    function __MagmaBase_init(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address admin_,
        uint256 rewardsFee_,
        uint256 withdrawalFee_,
        address feeReceiver_,
        uint256 redeemDelay_
    ) internal onlyInitializing {
        MagmaStorage storage $ = _getMagmaStorage();

        __ReentrancyGuard_init();
        __Pausable_init();
        __ERC20_init(name_, symbol_);
        __ERC4626_init(IERC20(address(asset_)));
        __ERC165_init();
        $._admin = admin_;
        $._rewardsFee = rewardsFee_;
        $._withdrawalFee = withdrawalFee_;
        $._feeReceiver = feeReceiver_;
        $._redeemDelay = redeemDelay_;
    }

    /**
     * @dev Allow contract to receive native MON (needed for unwrapping)
     */
    receive() external payable {}

    function pause() external onlyAdmin {
        _pause();
    }

    function unpause() external onlyAdmin {
        _unpause();
    }

    // TODO: see if we need UUPSUpgradeable and this and change onlyAdmin i other spots
    // function _authorizeUpgrade(address) internal view override onlyAdmin {}

    modifier onlyAdmin() {
        if (msg.sender != _getMagmaStorage()._admin) revert ErrNotAdmin();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            ERC-165 SUPPORT
    //////////////////////////////////////////////////////////////*/
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165Upgradeable) returns (bool) {
        return interfaceId == INTERFACE_ID_ERC7540 || super.supportsInterface(interfaceId);
    }

    function admin() public view returns (address) {
        return _getMagmaStorage()._admin;
    }

    function feeReceiver() public view returns (address) {
        return _getMagmaStorage()._feeReceiver;
    }

    function rewardsFee() public view returns (uint256) {
        return _getMagmaStorage()._rewardsFee;
    }

    function withdrawalFee() public view returns (uint256) {
        return _getMagmaStorage()._withdrawalFee;
    }

    function totalAssets() public view virtual override returns (uint256) {
        return coreVault.totalAssets() + gVault.totalAssets();
    }

    function isOperator(address controller, address operator) external view returns (bool) {
        return _getMagmaStorage()._isOperator[controller][operator];
    }

    function setOperator(address operator, bool approved) external returns (bool) {
        _getMagmaStorage()._isOperator[_msgSender()][operator] = approved;
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
        _refreshCacheCheck();
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
        _refreshCacheCheck();
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
        _refreshCacheCheck();
        uint256 shares = _deposit(assets, receiver);
        gVault.delegate{value: assets}(receiver, valId);
        emit DepositWithReferral(_msgSender(), receiver, assets, shares, referralId);
        return shares;
    }

    /// @notice Allows to set a referralId which will be used to reward points to the referrer (in case it qualifies)
    function depositWMON(uint256 assets, address receiver, uint256 referralId)
        external
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        _refreshCacheCheck();
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
        _refreshCacheCheck();
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
        _refreshCacheCheck();
        uint256 assets = convertToAssets(shares);
        return _requestRedeem(shares, assets, controller, owner, 0, false);
    }

    function requestRedeemGVault(uint256 shares, address controller, address owner, uint64 valId)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        _refreshCacheCheck();
        uint256 assets = convertToAssets(shares);
        if (assets > gVault.maxWithdrawableFromGVault(owner, valId)) {
            revert ErrNotEnoughAssetsGVault();
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
        MagmaStorage storage $ = _getMagmaStorage();

        if (controller == address(0)) revert ErrZeroAddress();
        if ($._ownerRequested[owner]) revert ErrRequestPending();
        if (shares == 0) revert ErrZeroShares();
        if (!(owner == _msgSender() || $._isOperator[owner][_msgSender()])) revert ErrNotAuthorized();
        if (shares > balanceOf(owner)) revert ErrInsufficientShares(shares, balanceOf(owner));

        uint256 requestId = $._requestIdCount;
        $._pendingRedeemRequests[controller][requestId] = RedeemRequests({
            owner: owner,
            shares: shares,
            assets: assets,
            claimableTime: block.timestamp + $._redeemDelay,
            isGVault: isGVault
        });
        unchecked {
            $._requestIdCount = requestId + 1;
        }
        $._ownerRequested[owner] = true;

        _burn(owner, shares);

        isGVault ? gVault.undelegate(owner, valId, assets) : coreVault.undelegate(assets, owner);

        emit RedeemRequest(controller, owner, requestId, _msgSender(), shares);
        return requestId;
    }

    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares) {
        return _getMagmaStorage()._pendingRedeemRequests[controller][requestId].shares;
    }

    function pendingRedeemRequestData(uint256 requestId, address controller)
        external
        view
        returns (RedeemRequests memory data)
    {
        return _getMagmaStorage()._pendingRedeemRequests[controller][requestId];
    }

    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares) {
        RedeemRequests memory request = _getMagmaStorage()._pendingRedeemRequests[controller][requestId];
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
    //  TODO: or admin, put in the comments @ dev if smart contract not EOA
    function _redeem(uint256 requestId, address controller, address receiver, bool receiveWMON)
        private
        returns (uint256)
    {
        MagmaStorage storage $ = _getMagmaStorage();

        if (!(controller == _msgSender() || $._isOperator[controller][_msgSender()])) revert ErrNotAuthorized();
        RedeemRequests memory request = $._pendingRedeemRequests[controller][requestId];
        if (request.claimableTime > block.timestamp) revert ErrRequestPending();
        if (request.claimableTime == 0) revert ErrRequestInexistent();

        address owner = $._pendingRedeemRequests[controller][requestId].owner;
        delete $._pendingRedeemRequests[controller][requestId];
        $._ownerRequested[owner] = false;

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

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ErrZeroAddress();
        _getMagmaStorage()._admin = newAdmin;
    }

    function setVaults(address _coreVault, address _gVault) external onlyAdmin {
        if (_coreVault == address(0)) revert ErrZeroAddress();
        coreVault = ICoreVault(_coreVault);
        gVault = IGVault(_gVault);
    }

    function setRewardsFee(uint256 _rewardsFee) external onlyAdmin {
        _getMagmaStorage()._rewardsFee = _rewardsFee;
    }

    function setWithdrawalFee(uint256 _withdrawalFee) external onlyAdmin {
        _getMagmaStorage()._withdrawalFee = _withdrawalFee;
    }

    function setFeeReceiver(address _feeReceiver) external onlyAdmin {
        _getMagmaStorage()._feeReceiver = _feeReceiver;
    }

    function setRedeemDelay(uint256 _redeemDelay) external onlyAdmin {
        _getMagmaStorage()._redeemDelay = _redeemDelay;
    }

    /**
     * @notice Force refresh the cache for the CoreVault and gVault
     */
    function refreshCache() external {
        coreVault.refreshCache();
        gVault.refreshCache();
    }

    /**
     * @notice Check if the cache for the CoreVault and gVault needs to be refreshed and refresh if needed
     */
    function _refreshCacheCheck() internal {
        coreVault.refreshCacheCheck();
        gVault.refreshCacheCheck();
    }

    /// @dev previewWithdraw MUST revert for all callers and inputs: https://eips.ethereum.org/EIPS/eip-7540#request-flows
    function previewWithdraw(uint256 /*assets*/ ) public view override returns (uint256) {
        /* solhint-disable-next-line gas-custom-errors */
        revert();
    }

    /// @dev previewRedeem MUST revert for all callers and inputs: https://eips.ethereum.org/EIPS/eip-7540#request-flows
    function previewRedeem(uint256 /*shares*/ ) public view override returns (uint256) {
        /* solhint-disable-next-line gas-custom-errors */
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
        /* solhint-disable-next-line gas-custom-errors */
        revert();
    }
}
