// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IGVault} from "../interfaces/IGVault.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

abstract contract MagmaBase is
    Initializable,
    ERC4626Upgradeable,
    ERC165Upgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // ERC-7540 Asynchronous redemption Vault Interface ID
    bytes4 internal constant INTERFACE_ID_ERC7540 = 0x620ee8e4;

    // Time in seconds a user needs to wait between requestRedeem and redeem to be able to withdraw his stake
    uint256 public redeemDelay;

    // Admin for Magma, CoreVault validator management, etc
    address public admin;

    uint256 public constant BASE_BPS = 10_000;

    // Tracks principal assets for each user for rewards calculation
    mapping(address => uint256) internal principalAssets;
    /// @notice The fee for rewards.
    /// @dev The fee is expressed as a bps percentage of the reward amount.
    uint256 public rewardsFee;

    /// @notice The fee for withdrawals.
    /// @dev The fee is expressed as a bps percentage of the withdrawal amount.
    uint256 public withdrawalFee;

    /// @notice The address that receives the fees.
    address public feeReceiver;

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

    uint256 internal _requestIdCount;

    // Mapping from controller to their pending withdrawal requests
    mapping(address controller => mapping(uint256 requestId => RedeemRequests)) public pendingRedeemRequests;

    mapping(address owner => bool) internal _ownerRequested;

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

    event Referral(
        address indexed sender, address indexed receiver, uint256 assets, uint256 shares, bytes32 indexed referralId
    );

    // Vault contract references (to be set by admin)
    ICoreVault public coreVault;
    IGVault public gVault;

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
        __ReentrancyGuard_init();
        __Pausable_init();
        __ERC20_init(name_, symbol_);
        __ERC4626_init(IERC20(address(asset_)));
        __ERC165_init();
        admin = admin_;
        rewardsFee = rewardsFee_;
        withdrawalFee = withdrawalFee_;
        feeReceiver = feeReceiver_;
        _requestIdCount = 0;
        redeemDelay = redeemDelay_;
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

    uint256[50] private __gap;
}
