// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

abstract contract MagmaBase is Initializable, ERC4626Upgradeable, ERC165Upgradeable {
    // ERC-7540 Interface ID
    bytes4 internal constant INTERFACE_ID_ERC7540 = 0x2f0a18c5;

    // Default delay for async operations (1 day)
    uint256 public constant DEFAULT_DELAY = 1 days;

    // Admin for Magma, CoreVault validator management, etc
    address public admin;

    // Pause state for deposits and withdrawals
    bool public paused;

    // Tracks total native MON delegated via CoreVault (in asset units, 1:1 with WMON)
    uint256 internal _delegatedNativeAssets;

    // Tracks principal assets for each user for rewards calculation
    mapping(address => uint256) internal principalAssets;
    /// @notice The fee for rewards.
    /// @dev The fee is expressed as a percentage of the reward amount.
    uint256 public rewardsFee;

    /// @notice The address that receives the rewards fee.
    address public rewardsFeeReceiver;

    // Struct to track pending withdrawal requests
    struct WithdrawalRequest {
        uint256 shares; // Amount of shares to redeem
        uint256 assets; // Amount of assets to withdraw
        uint256 timestamp; // When the request was made
        uint256 claimableTime; // When assets become claimable
        bool isRedeem; // True if redeem request, false if withdraw request
        address validator; // Non-zero when the request is tied to a gVault validator
    }

    // Mapping from controller to their pending withdrawal requests
    mapping(address => WithdrawalRequest) public pendingWithdrawals;

    // Mapping for operator approvals (ERC-7540)
    mapping(address => mapping(address => bool)) public isOperator;

    // Events for ERC-7540 compatibility and admin
    event WithdrawRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );

    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    event Paused(address indexed admin);
    event Unpaused(address indexed admin);
    event Referral(
        address indexed sender, address indexed receiver, uint256 assets, uint256 shares, bytes32 indexed referralId
    );

    event RebalanceAttempted(uint16 bps);
    event RebalanceFundsReceived(address indexed from, uint256 amount);

    // Vault contract references (to be set by admin)
    address public coreVault;
    address public gVault;

    function __MagmaBase_init(IERC20 asset_, string memory name_, string memory symbol_, address admin_)
        internal
        onlyInitializing
    {
        __ERC20_init(name_, symbol_);
        __ERC4626_init(IERC20(address(asset_)));
        __ERC165_init();
        admin = admin_;
    }

    /**
     * @dev Allow contract to receive native ETH/MON (needed for unwrapping)
     */
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                            ERC-165 SUPPORT
    //////////////////////////////////////////////////////////////*/
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165Upgradeable) returns (bool) {
        return interfaceId == INTERFACE_ID_ERC7540 || super.supportsInterface(interfaceId);
    }

    // Role and admin functions moved to MagmaRoleManagementModule

    /**
     * @dev Return the total assets managed by the vault, including delegated native and held WMON
     */
    function totalAssets() public view virtual override(ERC4626Upgradeable) returns (uint256) {
        return _delegatedNativeAssets + IERC20(asset()).balanceOf(address(this));
    }

    // Abstract internals that other modules may call
    function _undelegate(uint256 assets) internal virtual;
    function _completeUndelegationAndWrap(uint256 assets) internal virtual;
    function _undelegateFromValidator(uint64 valId, uint256 assets) internal virtual;
    function _completeUndelegationFromGVault(uint256 assets) internal virtual;

    uint256[50] private __gap;
}
