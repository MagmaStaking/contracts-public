// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IMagmaDelegation {
    // Structs
    struct Delegation {
        address validator;
        uint256 amount;
        uint256 timestamp;
    }

    struct UnbondingDelegation {
        address validator;
        uint256 amount;
        uint256 completionTime;
        bool completed;
    }

    // Events
    event Delegated(
        address indexed delegator,
        address indexed validator,
        uint256 amount
    );
    event Undelegated(
        address indexed delegator,
        address indexed validator,
        uint256 amount,
        uint256 completionTime
    );
    event UndelegationCompleted(
        address indexed delegator,
        uint256 indexed unbondingIndex,
        uint256 amount
    );
    event Redelegated(
        address indexed delegator,
        address indexed srcValidator,
        address indexed dstValidator,
        uint256 amount
    );

    // Functions
    function delegate(address validator, uint256 amount) external;
    function undelegate(address validator, uint256 amount) external;
    function completeUndelegation(uint256 unbondingIndex) external;
    function redelegate(
        address srcValidator,
        address dstValidator,
        uint256 amount
    ) external;

    // View functions
    function UNBONDING_PERIOD() external view returns (uint256);
    function delegations(
        address delegator,
        uint256 index
    ) external view returns (Delegation memory);
    function unbondingDelegations(
        address delegator,
        uint256 index
    ) external view returns (UnbondingDelegation memory);
    function getDelegationCount(
        address delegator
    ) external view returns (uint256);
    function getUnbondingCount(
        address delegator
    ) external view returns (uint256);
}
