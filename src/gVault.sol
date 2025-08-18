// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {MagmaDelegation} from "./MagmaDelegation.sol";
import {IMagma} from "../interfaces/IMagma.sol";

contract gVault {
    MagmaDelegation public immutable magmaDelegation;
    IMagma public immutable magma;

    // Whitelist of eligible validators
    mapping(address => bool) public isWhitelisted;
    address[] public whitelistedValidators;

    // Track user positions: amount delegated per validator
    mapping(address => mapping(address => uint256)) public delegatedAmountOf; // user => validator => amount
    mapping(address => address[]) private _userValidators; // user => list of validators with non-zero positions
    mapping(address => mapping(address => bool)) private _userHasValidator; // user => validator => in list

    // Per-validator deposit caps; if zero, use defaultCapPercent of Magma.totalAssets()
    mapping(address => uint256) public validatorCap;
    // Default cap percent in basis points (1% = 100 bps)
    uint256 public defaultCapBps = 100; // 1%

    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event PositionUpdated(
        address indexed user,
        address indexed validator,
        uint256 amount,
        bool isDelegate
    );
    event CapChanged(address indexed validator, uint256 newCap);
    event DefaultCapUpdated(uint256 newDefaultBps);

    constructor(address _magmaDelegation, address _magma) {
        magmaDelegation = MagmaDelegation(_magmaDelegation);
        magma = IMagma(_magma);
    }

    modifier onlyMagma() {
        require(msg.sender == address(magma), "gVault: not magma");
        _;
    }

    modifier onlyMagmaAdmin() {
        require(msg.sender == magma.admin(), "gVault: not admin");
        _;
    }

    // Admin: manage whitelist
    function addValidator(address validator) external onlyMagmaAdmin {
        require(validator != address(0), "gVault: zero address");
        require(!isWhitelisted[validator], "gVault: already whitelisted");
        isWhitelisted[validator] = true;
        whitelistedValidators.push(validator);
        emit ValidatorAdded(validator);
    }

    function removeValidator(address validator) external onlyMagmaAdmin {
        require(isWhitelisted[validator], "gVault: not whitelisted");
        // Remove from array
        uint256 len = whitelistedValidators.length;
        for (uint256 i = 0; i < len; i++) {
            if (whitelistedValidators[i] == validator) {
                whitelistedValidators[i] = whitelistedValidators[len - 1];
                whitelistedValidators.pop();
                break;
            }
        }
        isWhitelisted[validator] = false;
        emit ValidatorRemoved(validator);
    }

    function getWhitelistedValidators()
        external
        view
        returns (address[] memory)
    {
        return whitelistedValidators;
    }

    // Admin: set per-validator explicit cap (can increase or decrease)
    function changeValidatorCap(
        address validator,
        uint256 newCap
    ) external onlyMagmaAdmin {
        require(isWhitelisted[validator], "gVault: not whitelisted");
        validatorCap[validator] = newCap;
        emit CapChanged(validator, newCap);
    }

    // Admin: update default cap percent (bps)
    function setDefaultCapBps(uint256 newBps) external onlyMagmaAdmin {
        require(newBps <= 10_000, "gVault: invalid bps");
        defaultCapBps = newBps;
        emit DefaultCapUpdated(newBps);
    }

    function _maxCapFor(address validator) internal view returns (uint256) {
        uint256 cap = validatorCap[validator];
        if (cap != 0) return cap;
        // default: 1% of Magma.totalAssets
        (bool ok, bytes memory data) = address(magma).staticcall(
            abi.encodeWithSignature("totalAssets()")
        );
        if (!ok || data.length == 0) return 0;
        uint256 total = abi.decode(data, (uint256));
        return (total * defaultCapBps) / 10_000;
    }

    function delegate(address validator, uint256 amount) external onlyMagma {
        require(isWhitelisted[validator], "gVault: validator not whitelisted");
        address user = tx.origin;
        require(user != address(0), "gVault: invalid user");
        // Cap check
        uint256 cap = _maxCapFor(validator);
        require(cap > 0, "gVault: cap is zero");
        uint256 newAmt = delegatedAmountOf[user][validator] + amount;
        require(newAmt <= cap, "gVault: exceeds cap");
        magmaDelegation.delegate(validator, amount);
        // Update position
        delegatedAmountOf[user][validator] = newAmt;
        if (!_userHasValidator[user][validator]) {
            _userHasValidator[user][validator] = true;
            _userValidators[user].push(validator);
        }
        emit PositionUpdated(user, validator, amount, true);
    }

    function undelegate(address validator, uint256 amount) external onlyMagma {
        require(isWhitelisted[validator], "gVault: validator not whitelisted");
        address user = tx.origin;
        require(user != address(0), "gVault: invalid user");
        uint256 curr = delegatedAmountOf[user][validator];
        require(curr >= amount, "gVault: insufficient position");
        magmaDelegation.undelegate(validator, amount);
        uint256 newAmt = curr - amount;
        delegatedAmountOf[user][validator] = newAmt;
        if (newAmt == 0 && _userHasValidator[user][validator]) {
            // remove from user's list
            address[] storage list = _userValidators[user];
            uint256 n = list.length;
            for (uint256 i = 0; i < n; i++) {
                if (list[i] == validator) {
                    list[i] = list[n - 1];
                    list.pop();
                    break;
                }
            }
            _userHasValidator[user][validator] = false;
        }
        emit PositionUpdated(user, validator, amount, false);
    }

    function completeUndelegation(uint256 unbondingIndex) external onlyMagma {
        magmaDelegation.completeUndelegation(unbondingIndex);
    }

    // Helpers for reading user positions
    function getUserValidators(
        address user
    ) external view returns (address[] memory) {
        return _userValidators[user];
    }

    function getUserPositions(
        address user
    )
        external
        view
        returns (address[] memory validators, uint256[] memory amounts)
    {
        address[] memory list = _userValidators[user];
        uint256 n = list.length;
        validators = new address[](n);
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            address v = list[i];
            validators[i] = v;
            amounts[i] = delegatedAmountOf[user][v];
        }
    }
}
