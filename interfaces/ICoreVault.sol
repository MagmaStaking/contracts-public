// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IBaseVault} from "./IBaseVault.sol";

interface ICoreVault is IBaseVault {
    // Admin functions
    function addValidator(uint64 valId) external;
    function addValidators(uint64[] memory validators) external;
    function executeValidatorUndelegation(uint64 valId) external;
    function completeValidatorRemovalWithdrawal(uint64 valId) external;
    function adminRebalanceInitiate() external;
    function setMaxValidatorPerBatch(uint64 maxValidatorPerBatch) external;

    // Delegation functions (onlyMagma)
    function delegate() external payable;
    function undelegate(uint256 amount, address user) external;

    // Withdrawal completion function
    function completeUserWithdrawal(address user)
        external
        returns (uint256 _totalWithdrawn, uint256 _totalWithdrawnAfterFee);

    // Initialization
    function initialize(address _magma, uint256 _epochSeconds, uint64 maxValidatorPerBatch_) external;

    // View functions
    function delegatedAmount(uint64 valId) external returns (uint256);
    function getValidators() external view returns (uint64[] memory);
    function getValidatorCount() external view returns (uint256);
    function getTotalDelegated() external returns (uint256);

    // Events
    event RebalanceInitiated(
        uint256 totalUndelegated, uint256 numValidators, uint256 targetPerValidator, uint256 totalDelegated
    );
    event RewardsInjected(uint256 indexed amount);
}
