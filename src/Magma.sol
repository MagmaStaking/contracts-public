// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title Magma - ERC4626 Async Vault
 * @dev Implementation of ERC-4626 with asynchronous withdrawal/redeem functionality
 * Compatible with ERC-7540 standard for asynchronous tokenized vaults
 *
 * Features:
 * - Synchronous deposit/mint operations
 * - Asynchronous withdraw/redeem operations with time delays
 * - Linear release mechanism for pending withdrawals
 * - ERC-7540 compatible interface
 */
contract Magma is ERC4626, ERC165 {
    using Math for uint256;

    // ERC-7540 Interface ID
    bytes4 private constant INTERFACE_ID_ERC7540 = 0x2f0a18c5;

    // Default delay for async operations (1 day)
    uint256 public constant DEFAULT_DELAY = 1 days;

    // Admin for Magma, CoreVault validator management, etc
    address public admin;

    // Pause state for deposits and withdrawals
    bool public paused;
    // Tracks total native MON delegated via CoreVault (in asset units, 1:1 with WMON)
    uint256 private _delegatedNativeAssets;

    // Struct to track pending withdrawal requests
    struct WithdrawalRequest {
        uint256 shares; // Amount of shares to redeem
        uint256 assets; // Amount of assets to withdraw
        uint256 timestamp; // When the request was made
        uint256 claimableTime; // When assets become claimable
        bool isRedeem; // True if redeem request, false if withdraw request
    }

    // Mapping from controller to their pending withdrawal requests
    mapping(address => WithdrawalRequest) public pendingWithdrawals;

    // Mapping for operator approvals (ERC-7540)
    mapping(address => mapping(address => bool)) public isOperator;

    // Events for ERC-7540 compatibility
    event WithdrawRequest(
        address indexed controller,
        address indexed owner,
        uint256 indexed requestId,
        address sender,
        uint256 assets
    );

    event RedeemRequest(
        address indexed controller,
        address indexed owner,
        uint256 indexed requestId,
        address sender,
        uint256 shares
    );

    event OperatorSet(
        address indexed controller,
        address indexed operator,
        bool approved
    );

    event Paused(address indexed admin);
    event Unpaused(address indexed admin);
    event Referral(
        address indexed sender,
        address indexed receiver,
        uint256 assets,
        uint256 shares,
        bytes32 indexed referralId
    );

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_
    ) ERC4626(asset_) ERC20(name_, symbol_) {
        admin = msg.sender;
    }

    /**
     * @dev Allow contract to receive native ETH/MON (needed for unwrapping)
     */
    receive() external payable {
        // Accept native ETH/MON from WrappedMonad unwrapping
    }

    /*//////////////////////////////////////////////////////////////
                            ERC-165 SUPPORT
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == INTERFACE_ID_ERC7540 ||
            super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////
                        OPERATOR FUNCTIONALITY
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Set operator approval for ERC-7540 compatibility
     */
    function setOperator(
        address operator,
        bool approved
    ) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    /**
     * @dev Modifier to check if contract is not paused
     */
    modifier whenNotPaused() {
        require(!paused, "Magma: paused");
        _;
    }

    /**
     * @dev Change admin (only current admin can call)
     */
    function setAdmin(address newAdmin) external {
        require(msg.sender == admin, "Magma: not admin");
        require(newAdmin != address(0), "Magma: zero address");
        admin = newAdmin;
    }

    /**
     * @dev Pause all deposits and withdrawals (only admin can call)
     */
    function pause() external {
        require(msg.sender == admin, "Magma: not admin");
        require(!paused, "Magma: already paused");
        paused = true;
        emit Paused(admin);
    }

    /**
     * @dev Unpause all deposits and withdrawals (only admin can call)
     */
    function unpause() external {
        require(msg.sender == admin, "Magma: not admin");
        require(paused, "Magma: not paused");
        paused = false;
        emit Unpaused(admin);
    }

    /*//////////////////////////////////////////////////////////////
                        DELEGATION FUNCTIONALITY
    //////////////////////////////////////////////////////////////*/

    // Vault contract references (to be set by admin)
    address public coreVault;
    address public gVault;

    /**
     * @dev Set vault contract addresses (only admin can call)
     */
    function setVaults(address _coreVault, address _gVault) external {
        require(msg.sender == admin, "Magma: not admin");
        require(_coreVault != address(0), "Magma: core vault required");
        coreVault = _coreVault;
        gVault = _gVault;
    }

    /**
     * @dev Delegate through CoreVault (distributes equally among whitelisted validators)
     */
    function delegate(uint256 amount) external {
        (bool success, ) = coreVault.call(
            abi.encodeWithSignature("delegate(uint256)", amount)
        );
        require(success, "Magma: core vault delegation failed");
    }

    /**
     * @dev Delegate through gVault (specify validator)
     */
    function delegateToValidator(address validator, uint256 amount) external {
        require(gVault != address(0), "Magma: g vault not set");
        (bool success, ) = gVault.call(
            abi.encodeWithSignature(
                "delegate(address,uint256)",
                validator,
                amount
            )
        );
        require(success, "Magma: g vault delegation failed");
    }

    /**
     * @dev Undelegate through CoreVault (undelegates equally from all validators)
     */
    function undelegate(uint256 amount) external {
        (bool success, ) = coreVault.call(
            abi.encodeWithSignature("undelegate(uint256)", amount)
        );
        require(success, "Magma: core vault undelegation failed");
    }

    /**
     * @dev Undelegate from specific validator through gVault
     */
    function undelegateFromValidator(
        address validator,
        uint256 amount
    ) external {
        require(gVault != address(0), "Magma: g vault not set");
        (bool success, ) = gVault.call(
            abi.encodeWithSignature(
                "undelegate(address,uint256)",
                validator,
                amount
            )
        );
        require(success, "Magma: g vault undelegation failed");
    }

    /**
     * @dev Complete undelegation through CoreVault
     */
    function completeUndelegation(uint256 unbondingIndex) external {
        (bool success, ) = coreVault.call(
            abi.encodeWithSignature(
                "completeUndelegation(uint256)",
                unbondingIndex
            )
        );
        require(success, "Magma: core vault completion failed");
    }

    function _undelegate(uint256 assets) internal {
        (bool ok1, ) = coreVault.call(
            abi.encodeWithSignature("undelegate(uint256)", assets)
        );
        require(ok1, "Magma: core vault undelegate failed");
    }

    function _completeUndelegationAndWrap(uint256 assets) internal {
        (bool ok2, ) = coreVault.call(
            abi.encodeWithSignature("completeUndelegation(uint256)", 0)
        );
        require(ok2, "Magma: core vault complete failed");
        (bool successWrap, ) = address(asset()).call{value: assets}(
            abi.encodeWithSignature("deposit()")
        );
        require(successWrap, "Magma: wrap after undelegation failed");
    }

    /**
     * @dev Complete undelegation through gVault
     */
    function completeUndelegationFromValidator(
        uint256 unbondingIndex
    ) external {
        require(gVault != address(0), "Magma: g vault not set");
        (bool success, ) = gVault.call(
            abi.encodeWithSignature(
                "completeUndelegation(uint256)",
                unbondingIndex
            )
        );
        require(success, "Magma: g vault completion failed");
    }

    /*//////////////////////////////////////////////////////////////
                        NATIVE ASSET FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Return the total assets managed by the vault, including delegated native and held WMON
     */
    function totalAssets() public view virtual override returns (uint256) {
        return
            _delegatedNativeAssets + IERC20(asset()).balanceOf(address(this));
    }

    /**
     * @dev Deposit native MON/ETH and receive gMON shares minted to msg.sender
     * @return shares Amount of gMON shares minted
     *
     * Requirements:
     * - msg.value > 0
     * - Underlying asset must be WrappedMonad or similar with deposit() function
     */
    function depositMon()
        external
        payable
        whenNotPaused
        returns (uint256 shares)
    {
        require(msg.value > 0, "Magma: zero native asset");
        uint256 assets = msg.value;
        uint256 supply = totalSupply();
        uint256 totalAssetsBefore = totalAssets();
        shares = (supply == 0)
            ? assets
            : assets.mulDiv(supply, totalAssetsBefore, Math.Rounding.Floor);
        _mint(msg.sender, shares);
        // Delegate native path (coreVault required)
        _delegatedNativeAssets += assets;
        (bool success, ) = coreVault.call(
            abi.encodeWithSignature("delegate(uint256)", assets)
        );
        require(success, "Magma: core vault delegate failed");
        emit Deposit(msg.sender, msg.sender, assets, shares);
    }

    /**
     * @dev Deposit native MON/ETH with optional referral and receive gMON shares minted to msg.sender
     * @param referralId Optional referral identifier (pass non-zero to emit Referral)
     */
    function depositMon(
        bytes32 referralId
    ) external payable whenNotPaused returns (uint256 shares) {
        require(msg.value > 0, "Magma: zero native asset");
        // If coreVault set, delegate native; else fallback to wrapping path
        uint256 assets = msg.value;
        uint256 supply = totalSupply();
        uint256 totalAssetsBefore = totalAssets();
        shares = (supply == 0)
            ? assets
            : assets.mulDiv(supply, totalAssetsBefore, Math.Rounding.Floor);
        _mint(msg.sender, shares);
        _delegatedNativeAssets += assets;
        (bool success2, ) = coreVault.call(
            abi.encodeWithSignature("delegate(uint256)", assets)
        );
        require(success2, "Magma: core vault delegate failed");
        if (referralId != bytes32(0)) {
            emit Referral(msg.sender, msg.sender, assets, shares, referralId);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    ASYNC WITHDRAWAL REQUEST FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Request withdrawal of assets (ERC-7540 compatible)
     * @param assets Amount of assets to withdraw
     * @param controller Address that will control the request
     * @param owner Address that owns the shares
     * @return requestId Always returns 0 (simplified implementation)
     */

    function requestWithdraw(
        uint256 assets,
        address controller,
        address owner
    ) external whenNotPaused returns (uint256 requestId) {
        require(assets > 0, "Magma: zero assets");
        require(
            owner == msg.sender || isOperator[owner][msg.sender],
            "Magma: not authorized"
        );

        // Convert assets to shares at current rate
        uint256 shares = previewWithdraw(assets);
        require(shares <= balanceOf(owner), "Magma: insufficient shares");

        // Clear any existing pending request
        delete pendingWithdrawals[controller];

        // Create new withdrawal request
        pendingWithdrawals[controller] = WithdrawalRequest({
            shares: shares,
            assets: assets,
            timestamp: block.timestamp,
            claimableTime: block.timestamp + DEFAULT_DELAY,
            isRedeem: false
        });

        // Lock shares by transferring to this contract
        _transfer(owner, address(this), shares);

        // Start undelegation now to respect the async delay before claim
        require(
            _delegatedNativeAssets >= assets,
            "Magma: insufficient delegated"
        );
        _delegatedNativeAssets -= assets;
        _undelegate(assets);

        emit WithdrawRequest(controller, owner, 0, msg.sender, assets);
        return 0;
    }

    /**
     * @dev Request redemption of shares (ERC-7540 compatible)
     * @param shares Amount of shares to redeem
     * @param controller Address that will control the request
     * @param owner Address that owns the shares
     * @return requestId Always returns 0 (simplified implementation)
     */
    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    ) external whenNotPaused returns (uint256 requestId) {
        require(shares > 0, "Magma: zero shares");
        require(
            owner == msg.sender || isOperator[owner][msg.sender],
            "Magma: not authorized"
        );
        require(shares <= balanceOf(owner), "Magma: insufficient shares");

        // Clear any existing pending request
        delete pendingWithdrawals[controller];

        // Convert shares to assets at current rate
        uint256 assets = previewRedeem(shares);

        // Create new redemption request
        pendingWithdrawals[controller] = WithdrawalRequest({
            shares: shares,
            assets: assets,
            timestamp: block.timestamp,
            claimableTime: block.timestamp + DEFAULT_DELAY,
            isRedeem: true
        });

        // Lock shares by transferring to this contract
        _transfer(owner, address(this), shares);

        // Start undelegation now to respect the async delay before claim
        require(
            _delegatedNativeAssets >= assets,
            "Magma: insufficient delegated"
        );
        _delegatedNativeAssets -= assets;
        _undelegate(assets);

        emit RedeemRequest(controller, owner, 0, msg.sender, shares);
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS (ERC-7540)
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Get pending withdrawal request amount
     */
    function pendingWithdrawRequest(
        address controller
    ) external view returns (uint256) {
        WithdrawalRequest memory request = pendingWithdrawals[controller];
        if (request.shares == 0 || request.isRedeem) return 0;
        return request.assets;
    }

    /**
     * @dev Get pending redeem request amount
     */
    function pendingRedeemRequest(
        address controller
    ) external view returns (uint256) {
        WithdrawalRequest memory request = pendingWithdrawals[controller];
        if (request.shares == 0 || !request.isRedeem) return 0;
        return request.shares;
    }

    /**
     * @dev Get claimable withdrawal request amount (with linear vesting)
     */
    function claimableWithdrawRequest(
        address controller
    ) external view returns (uint256) {
        WithdrawalRequest memory request = pendingWithdrawals[controller];
        if (request.shares == 0 || request.isRedeem) return 0;

        return
            _getClaimableAmount(
                request.assets,
                request.timestamp,
                request.claimableTime
            );
    }

    /**
     * @dev Get claimable redeem request amount (with linear vesting)
     */
    function claimableRedeemRequest(
        address controller
    ) external view returns (uint256) {
        WithdrawalRequest memory request = pendingWithdrawals[controller];
        if (request.shares == 0 || !request.isRedeem) return 0;

        uint256 claimableAssets = _getClaimableAmount(
            request.assets,
            request.timestamp,
            request.claimableTime
        );
        // Convert claimable assets back to shares
        if (claimableAssets == 0) return 0;
        return
            claimableAssets.mulDiv(
                request.shares,
                request.assets,
                Math.Rounding.Floor
            );
    }

    /**
     * @dev Calculate claimable amount with linear vesting
     */
    function _getClaimableAmount(
        uint256 totalAmount,
        uint256 requestTime,
        uint256 claimableTime
    ) internal view returns (uint256) {
        if (block.timestamp >= claimableTime) {
            return totalAmount;
        }

        if (block.timestamp <= requestTime) {
            return 0;
        }

        // Linear vesting between requestTime and claimableTime
        uint256 elapsed = block.timestamp - requestTime;
        uint256 duration = claimableTime - requestTime;

        return totalAmount.mulDiv(elapsed, duration, Math.Rounding.Floor);
    }

    /*//////////////////////////////////////////////////////////////
                    OVERRIDE ERC4626 WITHDRAW/REDEEM
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Override withdraw to handle async claims
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address controller
    ) public virtual override whenNotPaused returns (uint256) {
        require(
            controller == msg.sender || isOperator[controller][msg.sender],
            "Magma: not authorized"
        );

        WithdrawalRequest storage request = pendingWithdrawals[controller];
        require(
            request.shares > 0 && !request.isRedeem,
            "Magma: no pending withdraw request"
        );

        uint256 claimableAssets = _getClaimableAmount(
            request.assets,
            request.timestamp,
            request.claimableTime
        );
        require(
            assets <= claimableAssets,
            "Magma: insufficient claimable assets"
        );

        // Calculate proportional shares to burn
        uint256 sharesToBurn = assets.mulDiv(
            request.shares,
            request.assets,
            Math.Rounding.Ceil
        );

        // Update the request
        request.assets -= assets;
        request.shares -= sharesToBurn;

        // If fully claimed, delete the request
        if (request.assets == 0) {
            delete pendingWithdrawals[controller];
        }

        // Burn shares, then complete undelegation and wrap
        _burn(address(this), sharesToBurn);
        _completeUndelegationAndWrap(assets);
        IERC20(asset()).transfer(receiver, assets);

        emit Withdraw(controller, receiver, controller, assets, sharesToBurn);
        return sharesToBurn;
    }

    /**
     * @dev Override redeem to handle async claims
     */
    function redeem(
        uint256 shares,
        address receiver,
        address controller
    ) public virtual override whenNotPaused returns (uint256) {
        require(
            controller == msg.sender || isOperator[controller][msg.sender],
            "Magma: not authorized"
        );

        WithdrawalRequest storage request = pendingWithdrawals[controller];
        require(
            request.shares > 0 && request.isRedeem,
            "Magma: no pending redeem request"
        );

        uint256 claimableAssets = _getClaimableAmount(
            request.assets,
            request.timestamp,
            request.claimableTime
        );
        uint256 claimableShares = claimableAssets.mulDiv(
            request.shares,
            request.assets,
            Math.Rounding.Floor
        );

        require(
            shares <= claimableShares,
            "Magma: insufficient claimable shares"
        );

        // Calculate proportional assets
        uint256 assets = shares.mulDiv(
            request.assets,
            request.shares,
            Math.Rounding.Floor
        );

        // Update the request
        request.assets -= assets;
        request.shares -= shares;

        // If fully claimed, delete the request
        if (request.shares == 0) {
            delete pendingWithdrawals[controller];
        }

        // Burn shares then complete undelegation and wrap
        _burn(address(this), shares);
        _completeUndelegationAndWrap(assets);
        IERC20(asset()).transfer(receiver, assets);

        emit Withdraw(controller, receiver, controller, assets, shares);
        return assets;
    }

    /**
     * @dev Redeem gMON shares for native MON/ETH
     * @param shares Amount of gMON shares to redeem
     * @param receiver Address that will receive the native MON/ETH
     * @param owner Address that owns the gMON shares
     * @return assets Amount of native MON/ETH received
     *
     * Requirements:
     * - shares > 0
     * - owner must have sufficient gMON shares
     * - Underlying asset must be WrappedMonad with withdraw() function
     */
    function redeemMon(
        uint256 shares,
        address receiver,
        address owner
    ) external whenNotPaused returns (uint256 assets) {
        require(shares > 0, "Magma: zero shares");
        require(receiver != address(0), "Magma: zero address");
        require(
            owner == msg.sender || allowance(owner, msg.sender) >= shares,
            "Magma: insufficient allowance"
        );

        // Calculate assets to receive
        assets = previewRedeem(shares);
        require(assets > 0, "Magma: zero assets");

        // Burn shares from owner
        if (owner != msg.sender) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);

        // Get the underlying asset (WrappedMonad)
        address assetAddress = address(asset());

        // Unwrap the assets to native MON/ETH
        (bool success, ) = assetAddress.call(
            abi.encodeWithSignature("withdraw(uint256)", assets)
        );
        require(success, "Magma: native asset unwrap failed");

        // Transfer native MON/ETH to receiver
        (bool sent, ) = payable(receiver).call{value: assets}("");
        require(sent, "Magma: native transfer failed");

        // Emit the standard ERC4626 Withdraw event
        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return assets;
    }
    /*//////////////////////////////////////////////////////////////
                        OVERRIDE PREVIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Override to revert for async flows as per ERC-7540
     */
    function previewWithdraw(
        uint256 assets
    ) public view virtual override returns (uint256) {
        // Allow preview for request calculations, but could revert in full async implementation
        return super.previewWithdraw(assets);
    }

    /**
     * @dev Override to revert for async flows as per ERC-7540
     */
    function previewRedeem(
        uint256 shares
    ) public view virtual override returns (uint256) {
        // Allow preview for request calculations, but could revert in full async implementation
        return super.previewRedeem(shares);
    }

    /*//////////////////////////////////////////////////////////////
                            MAX FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Max withdraw returns 0 to force async flow
     */
    function maxWithdraw(
        address owner
    ) public view virtual override returns (uint256) {
        // Force async withdrawal by returning 0
        return 0;
    }

    /**
     * @dev Max redeem returns 0 to force async flow
     */
    function maxRedeem(
        address owner
    ) public view virtual override returns (uint256) {
        // Force async redemption by returning 0
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                        ERC4626 OVERRIDES WITH PAUSE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Override deposit to add pause functionality
     */
    function deposit(
        uint256 assets,
        address receiver
    ) public virtual override whenNotPaused returns (uint256) {
        // Perform standard ERC4626 deposit to pull WMON in and mint shares
        uint256 shares = super.deposit(assets, receiver);
        // Unwrap WMON to native and delegate via CoreVault
        (bool successUnwrap, ) = address(asset()).call(
            abi.encodeWithSignature("withdraw(uint256)", assets)
        );
        require(successUnwrap, "Magma: unwrap failed");
        _delegatedNativeAssets += assets;
        (bool successDelegate, ) = coreVault.call(
            abi.encodeWithSignature("delegate(uint256)", assets)
        );
        require(successDelegate, "Magma: core vault delegate failed");
        return shares;
    }

    /**
     * @dev Override mint to add pause functionality
     */
    function mint(
        uint256 shares,
        address receiver
    ) public virtual override whenNotPaused returns (uint256) {
        uint256 assets = previewMint(shares);
        uint256 minted = super.mint(shares, receiver);
        (bool successUnwrap, ) = address(asset()).call(
            abi.encodeWithSignature("withdraw(uint256)", assets)
        );
        require(successUnwrap, "Magma: unwrap failed");
        _delegatedNativeAssets += assets;
        (bool successDelegate, ) = coreVault.call(
            abi.encodeWithSignature("delegate(uint256)", assets)
        );
        require(successDelegate, "Magma: core vault delegate failed");
        return minted;
    }
}
