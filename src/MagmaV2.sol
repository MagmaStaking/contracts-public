// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {WrappedMonad} from "../monad/WrappedMonad.sol";
import {
    ErrRequestPending,
    ErrZeroShares,
    ErrNotAuthorized,
    ErrInsufficientShares,
    ErrRequestInexistent,
    ErrNativeTransferFailed,
    ErrTokenTransferFailed,
    ErrZeroAddress,
    ErrInvalidBps
} from "./MagmaErrorsModule.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IGVault} from "../interfaces/IGVault.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IMagma} from "../interfaces/IMagma.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Implementation of ERC-7540 as defined in https://eips.ethereum.org/EIPS/eip-7540.
/// @custom:oz-upgrades-from Magma
contract MagmaV2 is
    IMagma,
    Initializable,
    UUPSUpgradeable,
    ERC4626Upgradeable,
    ERC165Upgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    Ownable2StepUpgradeable
{
    /// @custom:storage-location erc7201:storage.Magma
    struct MagmaStorage {
        /// @notice The address that receives the fees.
        address _feeReceiver;
        /// Vault contract references (to be set by admin)
        address _coreVault;
        address _gVault;
        uint256 _requestIdCount;
        // Time in seconds a user needs to wait between requestRedeem and redeem to be able to withdraw his stake
        uint256 _redeemDelay;
        /// @notice The fee for rewards.
        /// @dev The fee is expressed as a bps percentage of the reward amount.
        uint256 _rewardsFee;
        /// @notice The fee for withdrawals.
        /// @dev The fee is expressed as a bps percentage of the withdrawal amount.
        uint256 _withdrawalFee;
        /// @notice The address authorized to inject MEV rewards.
        address _mevRewardsInjector;
        /// @notice Tracks whether an owner has an active redemption request.
        /// @dev Used to enforce one active request per owner at a time.
        mapping(address owner => bool) _ownerRequested;
        /// @notice Maps each owner to their active redemption request ID.
        /// @dev Returns 0 when an owner has no active request (requestIdCount starts at 1 to avoid ambiguity).
        mapping(address owner => uint256 requestId) _ownerRequestId;
        /// Mapping from controller to their pending withdrawal requests
        mapping(address controller => mapping(uint256 requestId => RedeemRequests)) _pendingRedeemRequests;
        /// Mapping for operator approvals (ERC-7540)
        mapping(address controller => mapping(address operator => bool)) _isOperator;
    }

    struct InitializeParams {
        IERC20 asset;
        string name;
        string symbol;
        uint256 rewardsFee;
        uint256 withdrawalFee;
        address feeReceiver;
        uint256 redeemDelay;
        address mevRewardsInjector;
    }

    // ERC-7540 Asynchronous redemption Vault Interface ID
    bytes4 private constant INTERFACE_ID_ERC7540 = 0x620ee8e4;

    uint256 public constant BASE_BPS = 10_000;

    // keccak256(abi.encode(uint256(keccak256("storage.Magma")) - 1)) & ~bytes32(uint256(0xff))
    /* solhint-disable-next-line const-name-snakecase */
    bytes32 private constant _MagmaStorageLocation = 0xe12a3c9ed0954edf986cec381af8403b24a0b0b94ceba99e0d4e9dd1e2aec500;

    /// @dev https://forum.openzeppelin.com/t/is-disableinitializers-necessary/31070
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize requestIdCount to 1 to distinguish between "no active request" (default value 0 in
     *  _ownerRequestId) and actual request IDs
     */
    /// @custom:oz-upgrades-validate-as-initializer
    function initialize(address _owner, address _gVault) external reinitializer(2) {
        if (_gVault == address(0)) revert ErrZeroAddress();

        __ERC20_init(name(), name());
        __ERC4626_init(IERC20(asset()));
        __ReentrancyGuard_init();
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ERC165_init();

        MagmaStorage storage $ = _getMagmaStorage();
        $._gVault = _gVault;
        emit VaultsSet($._coreVault, _gVault);
    }

    /**
     * @dev Allow contract to receive native MON (needed for unwrapping)
     */
    receive() external payable {}

    function _getMagmaStorage() private pure returns (MagmaStorage storage $) {
        assembly {
            $.slot := _MagmaStorageLocation
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Internal function to authorize contract upgrades
     * @dev Only allows the Magma admin to authorize upgrades. Required by UUPSUpgradeable
     * @dev https://docs.openzeppelin.com/contracts/5.x/api/proxy#UUPSUpgradeable
     */
    /* solhint-disable-next-line no-empty-blocks */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function supportsInterface(bytes4 interfaceId) public view override(ERC165Upgradeable) returns (bool) {
        return interfaceId == INTERFACE_ID_ERC7540 || super.supportsInterface(interfaceId);
    }

    function coreVault() public view returns (address) {
        return _getMagmaStorage()._coreVault;
    }

    function feeReceiver() public view returns (address) {
        return _getMagmaStorage()._feeReceiver;
    }

    function gVault() public view returns (address) {
        return _getMagmaStorage()._gVault;
    }

    function rewardsFee() public view returns (uint256) {
        return _getMagmaStorage()._rewardsFee;
    }

    function withdrawalFee() public view returns (uint256) {
        return _getMagmaStorage()._withdrawalFee;
    }

    function mevRewardsInjector() public view returns (address) {
        return _getMagmaStorage()._mevRewardsInjector;
    }

    function owner() public view override(OwnableUpgradeable, IMagma) returns (address) {
        return super.owner();
    }

    function totalAssets() public view override(ERC4626Upgradeable, IMagma) returns (uint256) {
        MagmaStorage storage $ = _getMagmaStorage();
        return ICoreVault($._coreVault).totalAssets() + IGVault($._gVault).totalAssets();
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
        override(ERC4626Upgradeable, IMagma)
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        _refreshCacheCheck();
        uint256 assets = previewMint(shares);
        uint256 minted = super.mint(shares, receiver);
        WrappedMonad(payable(address(asset()))).withdraw(assets);
        ICoreVault(_getMagmaStorage()._coreVault).delegate{value: assets}();
        emit DepositWithReferral(_msgSender(), receiver, assets, shares, 0);
        return minted;
    }

    function _deposit(uint256 assets, address receiver) private returns (uint256) {
        uint256 shares = super.deposit(assets, receiver);
        if (shares == 0) revert ErrZeroShares();
        WrappedMonad(payable(address(asset()))).withdraw(assets);
        return shares;
    }

    function _depositMON(address receiver, uint256 referralId) private returns (uint256 shares) {
        _refreshCacheCheck();
        uint256 assets = msg.value;
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);

        shares = previewDeposit(assets);
        if (shares == 0) revert ErrZeroShares();

        _mint(receiver, shares);
        emit Deposit(_msgSender(), receiver, assets, shares);
        emit DepositWithReferral(_msgSender(), receiver, assets, shares, referralId);
    }

    /// @dev Withdraws WMON to MON so it can stake it
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626Upgradeable, IMagma)
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        _refreshCacheCheck();
        uint256 shares = _deposit(assets, receiver);
        ICoreVault(_getMagmaStorage()._coreVault).delegate{value: assets}();
        emit DepositWithReferral(_msgSender(), receiver, assets, shares, 0);
        return shares;
    }

    /// @notice Allows to set a referralId which will be used to reward points to the referrer (in case it qualifies)
    function depositWMONGVault(uint256 assets, address receiver, uint64 valId, uint256 referralId)
        external
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        _refreshCacheCheck();
        uint256 shares = _deposit(assets, receiver);
        IGVault(_getMagmaStorage()._gVault).delegate{value: assets}(receiver, valId, shares);
        emit DepositWithReferral(_msgSender(), receiver, assets, shares, referralId);
        return shares;
    }

    /// @notice Allows to set a referralId which will be used to reward points to the referrer (in case it qualifies)
    function depositMONGVault(address receiver, uint64 valId, uint256 referralId)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        shares = _depositMON(receiver, referralId);
        IGVault(_getMagmaStorage()._gVault).delegate{value: msg.value}(receiver, valId, shares);
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
        ICoreVault(_getMagmaStorage()._coreVault).delegate{value: assets}();
        emit DepositWithReferral(_msgSender(), receiver, assets, shares, referralId);
        return shares;
    }

    /// @notice Allows to set a referralId which will be used to reward points to the referrer (in case it qualifies)
    function depositMON(address receiver, uint256 referralId)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        shares = _depositMON(receiver, referralId);
        ICoreVault(_getMagmaStorage()._coreVault).delegate{value: msg.value}();
    }

    function requestRedeem(uint256 shares, address controller, address _owner)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        _refreshCacheCheck();
        uint256 assets = convertToAssets(shares);
        return _requestRedeem(shares, assets, controller, _owner, 0, false);
    }

    function requestRedeemGVault(uint256 shares, address controller, address _owner, uint64 valId)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        _refreshCacheCheck();
        uint256 assets = IGVault(_getMagmaStorage()._gVault).magmaSharesToGvaultAssets(valId, _owner, shares);
        return _requestRedeem(shares, assets, controller, _owner, valId, true);
    }

    /**
     * @param controller The designated controller will be responsible for claiming the assets of the owner after the
     * request is available.
     * @param _owner Owner of the shares.
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
        address _owner,
        uint64 valId,
        bool isGVault
    ) private returns (uint256) {
        MagmaStorage storage $ = _getMagmaStorage();

        if (controller == address(0)) revert ErrZeroAddress();
        if ($._ownerRequested[_owner]) revert ErrRequestPending();
        if (shares == 0) revert ErrZeroShares();
        if (!(_owner == _msgSender() || $._isOperator[_owner][_msgSender()])) revert ErrNotAuthorized();
        if (shares > balanceOf(_owner)) revert ErrInsufficientShares(shares, balanceOf(_owner));

        uint256 requestId = $._requestIdCount;
        $._pendingRedeemRequests[controller][requestId] = RedeemRequests({
            owner: _owner,
            shares: shares,
            assets: assets,
            claimableTime: block.timestamp + $._redeemDelay,
            isGVault: isGVault
        });
        $._ownerRequestId[_owner] = requestId;
        unchecked {
            $._requestIdCount = requestId + 1;
        }
        $._ownerRequested[_owner] = true;

        _burn(_owner, shares);

        isGVault
            ? IGVault($._gVault).undelegate(_owner, valId, assets, shares)
            : ICoreVault($._coreVault).undelegate(assets, _owner);

        emit RedeemRequest(controller, _owner, requestId, _msgSender(), shares);
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

    function ownerRequestId(address _owner) external view returns (uint256) {
        return _getMagmaStorage()._ownerRequestId[_owner];
    }

    function redeem(uint256 requestId, address controller, address receiver)
        public
        override(ERC4626Upgradeable, IMagma)
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        _refreshCacheCheck();
        return _redeem(requestId, controller, receiver, true);
    }

    function redeemMON(uint256 requestId, address controller, address receiver)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        _refreshCacheCheck();
        return _redeem(requestId, controller, receiver, false);
    }

    /**
     * @param controller was designated by owner in _requestRedeem to manage the claim of the shares
     * @param receiveWMON States if the request should be fulfilled in WMON or MON
     * @dev Compares asset values at request time and claim time, using the lower value to protect against slashing.
     * This prevents exploitation of price differences during the two-step redemption process. For example, if
     * slashing occurs between request and claim, the user receives the lower post-slashing amount rather than
     * the higher pre-slashing amount.
     * @dev Admin can redeem for any request to bypass the controller check since withdrawals ids are limited and can be used up
     */
    function _redeem(uint256 requestId, address controller, address receiver, bool receiveWMON)
        private
        returns (uint256)
    {
        MagmaStorage storage $ = _getMagmaStorage();
        RedeemRequests memory request = $._pendingRedeemRequests[controller][requestId];
        if (request.claimableTime > block.timestamp) revert ErrRequestPending();
        if (request.claimableTime == 0) revert ErrRequestInexistent();

        if (!(controller == _msgSender() || $._isOperator[controller][_msgSender()] || request.owner == _msgSender()
                    || $._isOperator[request.owner][_msgSender()] || _msgSender() == owner())) {
            revert ErrNotAuthorized();
        }

        address _owner = $._pendingRedeemRequests[controller][requestId].owner;
        delete $._pendingRedeemRequests[controller][requestId];
        delete $._ownerRequestId[_owner];
        $._ownerRequested[_owner] = false;

        (uint256 totalWithdrawn, uint256 totalWithdrawnAfterFee) = request.isGVault
            ? IGVault($._gVault).completeUserWithdrawal(_owner)
            : ICoreVault($._coreVault).completeUserWithdrawal(_owner);

        uint256 withdrawnShares = _getWithdrawnShares(totalWithdrawn, receiver, request);
        if (receiveWMON) {
            WrappedMonad(payable(address(asset()))).deposit{value: totalWithdrawnAfterFee}();
            bool success = WrappedMonad(payable(address(asset()))).transfer(receiver, totalWithdrawnAfterFee);
            if (!success) {
                revert ErrTokenTransferFailed();
            }
        } else {
            (bool sent,) = payable(receiver).call{value: totalWithdrawnAfterFee}("");
            if (!sent) {
                revert ErrNativeTransferFailed();
            }
        }

        emit Withdraw(_msgSender(), receiver, _owner, totalWithdrawnAfterFee, withdrawnShares);

        return totalWithdrawnAfterFee;
    }

    function _getWithdrawnShares(uint256 totalWithdrawn, address receiver, RedeemRequests memory request)
        private
        returns (uint256)
    {
        if (totalWithdrawn < request.assets) {
            /**
             * If withdraw amount gets slashed losses are socialized. Shares minted represent an increase in the supply.
             * Therefore, losess are socialized between all the participants
             */
            uint256 withdrawnShares = Math.mulDiv(
                totalWithdrawn,
                totalSupply() + request.shares + 10 ** _decimalsOffset(),
                totalAssets() + totalWithdrawn + 1,
                Math.Rounding.Ceil
            );
            if (withdrawnShares < request.shares) {
                _mint(receiver, request.shares - withdrawnShares);
                return withdrawnShares;
            }
        }
        return request.shares;
    }

    function setRewardsFee(uint256 _rewardsFee) external onlyOwner {
        if (_rewardsFee > BASE_BPS) revert ErrInvalidBps();
        _getMagmaStorage()._rewardsFee = _rewardsFee;
        emit RewardsFeeUpdated(_rewardsFee);
    }

    function setWithdrawalFee(uint256 _withdrawalFee) external onlyOwner {
        if (_withdrawalFee > BASE_BPS) revert ErrInvalidBps();
        _getMagmaStorage()._withdrawalFee = _withdrawalFee;
        emit WithdrawalFeeUpdated(_withdrawalFee);
    }

    function setFeeReceiver(address _feeReceiver) external onlyOwner {
        if (_feeReceiver == address(0)) revert ErrZeroAddress();
        _getMagmaStorage()._feeReceiver = _feeReceiver;
        emit FeeReceiverUpdated(_feeReceiver);
    }

    function setRedeemDelay(uint256 _redeemDelay) external onlyOwner {
        _getMagmaStorage()._redeemDelay = _redeemDelay;
        emit RedeemDelayUpdated(_redeemDelay);
    }

    function setMevRewardsInjector(address _mevRewardsInjector) external onlyOwner {
        if (_mevRewardsInjector == address(0)) revert ErrZeroAddress();
        address _oldInjector = _getMagmaStorage()._mevRewardsInjector;
        _getMagmaStorage()._mevRewardsInjector = _mevRewardsInjector;
        emit MevRewardsInjectorUpdated(_oldInjector, _mevRewardsInjector);
    }

    /**
     * @notice Force refresh the cache for the CoreVault and gVault
     */
    function refreshCache() external nonReentrant {
        MagmaStorage storage $ = _getMagmaStorage();
        ICoreVault($._coreVault).refreshCache();
        IGVault($._gVault).refreshCache();
    }

    /**
     * @notice Check if the cache for the CoreVault and gVault needs to be refreshed and refresh if needed
     */
    function _refreshCacheCheck() internal {
        MagmaStorage storage $ = _getMagmaStorage();
        ICoreVault($._coreVault).refreshCacheCheck();
        IGVault($._gVault).refreshCacheCheck();
    }

    /// @dev previewWithdraw MUST revert for all callers and inputs: https://eips.ethereum.org/EIPS/eip-7540#request-flows
    function previewWithdraw(
        uint256 /*assets*/
    )
        public
        view
        override
        returns (uint256)
    {
        /* solhint-disable-next-line */
        revert();
    }

    /// @dev previewRedeem MUST revert for all callers and inputs: https://eips.ethereum.org/EIPS/eip-7540#request-flows
    function previewRedeem(
        uint256 /*shares*/
    )
        public
        view
        override
        returns (uint256)
    {
        /* solhint-disable-next-line */
        revert();
    }

    /**
     * @dev The redeem and withdraw methods do not transfer shares to the Vault, this happens in a two step process via
     * _requestRedeem and claimRequest.
     */
    function withdraw(
        uint256,
        /*assets*/
        address,
        /*receiver*/
        address /*controller*/
    )
        public
        override
        returns (uint256)
    {
        /* solhint-disable-next-line */
        revert();
    }
}
