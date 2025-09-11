// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IGVault} from "../interfaces/IGVault.sol";

abstract contract MagmaBase is Initializable, ERC4626Upgradeable, ERC165Upgradeable {
    // ERC-7540 Asynchronous redemption Vault Interface ID
    bytes4 internal constant INTERFACE_ID_ERC7540 = 0x620ee8e4;

    // Default delay for async operations (1 day)
    uint256 public constant DEFAULT_DELAY = 1 days;

    // Admin for Magma, CoreVault validator management, etc
    address public admin;

    // Pause state for deposits and withdrawals
    bool public paused;

    // Tracks total native MON delegated via CoreVault and GVault (in asset units, 1:1 with WMON)
    uint256 internal _delegatedNativeAssets;

    // Tracks principal assets for each user for rewards calculation
    mapping(address => uint256) internal principalAssets;
    /// @notice The fee for rewards.
    /// @dev The fee is expressed as a percentage of the reward amount.
    uint256 public rewardsFee;

    /// @notice The address that receives the rewards fee.
    address public rewardsFeeReceiver;

    /// @notice Struct to track pending redeem requests
    /// @dev Claimable state may transition automatically after a timestamp has passed.
    /// @dev https://eips.ethereum.org/EIPS/eip-7540#no-event-for-claimable-state
    /// @dev https://eips.ethereum.org/EIPS/eip-7540#request-lifecycle
    struct RedeemRequests {
        uint256 shares; // Amount of shares to redeem
        uint256 assets; // Amount of assets to withdraw
        uint256 claimableTime; // When assets become claimable
    }

    uint256 internal _requestIdCount = 0;

    // Mapping from controller to their pending withdrawal requests
    mapping(address controller => mapping(uint256 requestId => RedeemRequests)) public pendingRedeemRequests;

    // Mapping for operator approvals (ERC-7540)
    mapping(address controller => mapping(address operator => bool)) public isOperator;

    /// @dev Emitted upon a successful deposit, will be sent on every deposit to facilitate on the indexer side
    event DepositWithReferral(
        address indexed sender, address indexed owner, uint256 assets, uint256 shares, uint256 indexed referralId
    );

    // Events for ERC-7540 compatibility and admin
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
    ICoreVault public coreVault;
    IGVault public gVault;

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
     * @dev Allow contract to receive native MON (needed for unwrapping)
     */
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                            ERC-165 SUPPORT
    //////////////////////////////////////////////////////////////*/
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165Upgradeable) returns (bool) {
        return interfaceId == INTERFACE_ID_ERC7540 || super.supportsInterface(interfaceId);
    }

    // Role and admin functions moved to MagmaRoleManagementModule

    // Abstract internals that other modules may call
    function _undelegate(uint256 assets) internal virtual;

    function _completeUndelegationAndWrap(uint256 assets) internal virtual;

    function _undelegateFromValidator(uint64 valId, uint256 assets) internal virtual;

    function _completeUndelegationFromGVault(uint256 assets) internal virtual;

    uint256[50] private __gap;
}
