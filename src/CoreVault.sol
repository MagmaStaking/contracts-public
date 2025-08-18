// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {MagmaDelegation} from "./MagmaDelegation.sol";
import {IMagma} from "../interfaces/IMagma.sol";

contract CoreVault {
    MagmaDelegation public immutable magmaDelegation;
    IMagma public immutable magma;

    address[] public validators;
    mapping(address => bool) public isWhitelisted;
    mapping(address => uint256) public delegatedAmount;

    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event Rebalanced();

    constructor(address _magmaDelegation, address _magma) {
        magmaDelegation = MagmaDelegation(_magmaDelegation);
        magma = IMagma(_magma);
    }

    modifier onlyAdmin() {
        require(msg.sender == magma.admin(), "CoreVault: not admin");
        _;
    }

    modifier onlyMagma() {
        require(msg.sender == address(magma), "CoreVault: not magma");
        _;
    }

    function addValidator(address validator) external onlyAdmin {
        require(validator != address(0), "CoreVault: zero address");
        require(!isWhitelisted[validator], "CoreVault: already whitelisted");

        validators.push(validator);
        isWhitelisted[validator] = true;

        emit ValidatorAdded(validator);
        _rebalance();
    }

    function removeValidator(address validator) external onlyAdmin {
        require(isWhitelisted[validator], "CoreVault: not whitelisted");

        // Store the amount that was delegated to this validator
        uint256 amountToRedistribute = delegatedAmount[validator];

        // Undelegate all from this validator first
        if (amountToRedistribute > 0) {
            magmaDelegation.undelegate(validator, amountToRedistribute);
            delegatedAmount[validator] = 0;
        }

        // Remove from array
        for (uint256 i = 0; i < validators.length; i++) {
            if (validators[i] == validator) {
                validators[i] = validators[validators.length - 1];
                validators.pop();
                break;
            }
        }

        isWhitelisted[validator] = false;

        // Redistribute the amount to remaining validators if any
        if (validators.length > 0 && amountToRedistribute > 0) {
            uint256 amountPerValidator = amountToRedistribute /
                validators.length;
            for (uint256 i = 0; i < validators.length; i++) {
                magmaDelegation.delegate(validators[i], amountPerValidator);
                delegatedAmount[validators[i]] += amountPerValidator;
            }
        }

        emit ValidatorRemoved(validator);
    }

    function delegate(uint256 amount) external onlyMagma {
        require(validators.length > 0, "CoreVault: no validators");

        uint256 amountPerValidator = amount / validators.length;
        require(amountPerValidator > 0, "CoreVault: amount too small");

        for (uint256 i = 0; i < validators.length; i++) {
            magmaDelegation.delegate(validators[i], amountPerValidator);
            delegatedAmount[validators[i]] += amountPerValidator;
        }
    }

    function undelegate(uint256 amount) external onlyMagma {
        require(validators.length > 0, "CoreVault: no validators");

        uint256 amountPerValidator = amount / validators.length;
        require(amountPerValidator > 0, "CoreVault: amount too small");

        for (uint256 i = 0; i < validators.length; i++) {
            require(
                delegatedAmount[validators[i]] >= amountPerValidator,
                "CoreVault: insufficient delegation"
            );
            magmaDelegation.undelegate(validators[i], amountPerValidator);
            delegatedAmount[validators[i]] -= amountPerValidator;
        }
    }

    function completeUndelegation(uint256 unbondingIndex) external onlyMagma {
        magmaDelegation.completeUndelegation(unbondingIndex);
    }

    function rebalance() external onlyAdmin {
        _rebalance();
    }

    function _rebalance() internal {
        if (validators.length == 0) return;

        // Calculate total delegated
        uint256 totalDelegated = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            totalDelegated += delegatedAmount[validators[i]];
        }

        if (totalDelegated == 0) return;

        uint256 targetPerValidator = totalDelegated / validators.length;

        // First pass: undelegate excess from validators with more than target
        for (uint256 i = 0; i < validators.length; i++) {
            address validator = validators[i];
            if (delegatedAmount[validator] > targetPerValidator) {
                uint256 excess = delegatedAmount[validator] -
                    targetPerValidator;
                magmaDelegation.undelegate(validator, excess);
                delegatedAmount[validator] = targetPerValidator;
            }
        }

        // Second pass: delegate to validators with less than target
        for (uint256 i = 0; i < validators.length; i++) {
            address validator = validators[i];
            if (delegatedAmount[validator] < targetPerValidator) {
                uint256 deficit = targetPerValidator -
                    delegatedAmount[validator];
                magmaDelegation.delegate(validator, deficit);
                delegatedAmount[validator] = targetPerValidator;
            }
        }

        emit Rebalanced();
    }

    function getValidators() external view returns (address[] memory) {
        return validators;
    }

    function getValidatorCount() external view returns (uint256) {
        return validators.length;
    }

    function getTotalDelegated() external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            total += delegatedAmount[validators[i]];
        }
        return total;
    }
}
