// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title MockStakingPrecompile
 * @dev Mock implementation of Monad staking precompile for testing
 */
contract MockStakingPrecompile {
    bytes4 internal constant SEL_DELEGATE = 0x00000002;
    bytes4 internal constant SEL_UNDELEGATE = 0x00000003;
    bytes4 internal constant SEL_COMPOUND = 0x00000004;
    bytes4 internal constant SEL_WITHDRAW = 0x00000005;
    bytes4 internal constant SEL_CLAIM_REWARDS = 0x00000006;
    bytes4 internal constant SEL_GET_WITHDRAW = 0x00000009;
    bytes4 internal constant SEL_GET_DELEGATOR = 0x00000008;

    // Mock state
    mapping(uint64 => mapping(address => uint256)) public delegatorStakes;
    mapping(uint64 => mapping(address => mapping(uint8 => WithdrawalRequest))) public withdrawalRequests;

    struct WithdrawalRequest {
        uint256 amount;
        uint256 acc;
        uint64 epoch;
    }

    // Track next epoch for withdrawals
    uint64 public currentEpoch = 1;

    fallback() external payable {
        bytes4 selector = bytes4(msg.data[:4]);

        if (selector == SEL_DELEGATE) {
            _handleDelegate();
        } else if (selector == SEL_UNDELEGATE) {
            _handleUndelegate();
        } else if (selector == SEL_COMPOUND) {
            _handleCompound();
        } else if (selector == SEL_WITHDRAW) {
            _handleWithdraw();
        } else if (selector == SEL_CLAIM_REWARDS) {
            _handleClaimRewards();
        } else if (selector == SEL_GET_WITHDRAW) {
            _handleGetWithdraw();
        } else if (selector == SEL_GET_DELEGATOR) {
            _handleGetDelegator();
        } else {
            revert("Unknown selector");
        }
    }

    function _handleDelegate() internal {
        (uint64 valId, uint256 amount) = abi.decode(msg.data[4:], (uint64, uint256));
        // In the real precompile, ETH would be automatically deducted from the caller's balance
        // For testing purposes, we just track the delegation amounts
        delegatorStakes[valId][msg.sender] += amount;
    }

    function _handleUndelegate() internal {
        (uint64 valId, uint256 amount, uint8 withdrawalId) = abi.decode(msg.data[4:], (uint64, uint256, uint8));
        require(delegatorStakes[valId][msg.sender] >= amount, "Insufficient stake");

        delegatorStakes[valId][msg.sender] -= amount;
        withdrawalRequests[valId][msg.sender][withdrawalId] =
            WithdrawalRequest({amount: amount, acc: 0, epoch: currentEpoch + 1});
    }

    function _handleWithdraw() internal {
        (uint64 valId, uint8 withdrawalId) = abi.decode(msg.data[4:], (uint64, uint8));
        WithdrawalRequest storage request = withdrawalRequests[valId][msg.sender][withdrawalId];
        require(request.amount > 0, "No withdrawal request");
        require(request.epoch <= currentEpoch, "Withdrawal not ready");

        uint256 amount = request.amount;
        delete withdrawalRequests[valId][msg.sender][withdrawalId];

        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
    }

    function _handleCompound() internal {
        (uint64 valId) = abi.decode(msg.data[4:], (uint64));
        // Mock compounding - add 1% rewards
        uint256 currentStake = delegatorStakes[valId][msg.sender];
        uint256 rewards = currentStake / 100; // 1% rewards
        delegatorStakes[valId][msg.sender] += rewards;
    }

    function _handleClaimRewards() internal {
        (uint64 valId) = abi.decode(msg.data[4:], (uint64));
        // Mock claiming - send 1% of stake as rewards
        uint256 currentStake = delegatorStakes[valId][msg.sender];
        uint256 rewards = currentStake / 100; // 1% rewards
        (bool success,) = msg.sender.call{value: rewards}("");
        require(success, "Reward transfer failed");
    }

    function _handleGetWithdraw() internal view {
        (uint64 valId, address delegator, uint8 withdrawalId) = abi.decode(msg.data[4:], (uint64, address, uint8));
        WithdrawalRequest storage request = withdrawalRequests[valId][delegator][withdrawalId];

        bytes memory result = abi.encode(request.amount, request.acc, request.epoch);
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }

    function _handleGetDelegator() internal view {
        (uint64 valId, address delegator) = abi.decode(msg.data[4:], (uint64, address));
        uint256 stake = delegatorStakes[valId][delegator];

        bytes memory result = abi.encode(stake);
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }

    // Admin functions for testing
    function setDelegatorStake(uint64 valId, address delegator, uint256 amount) external {
        delegatorStakes[valId][delegator] = amount;
    }

    function advanceEpoch() external {
        currentEpoch++;
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
