// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {console} from "forge-std/console.sol";

/**
 * @title MockStakingPrecompile
 * @dev Mock implementation of Monad staking precompile for testing
 * Following the specification from Monad_Staking.md
 */
contract MockStakingPrecompile {
    // Function selectors from the spec
    bytes4 internal constant SEL_ADD_VALIDATOR = 0x00000001;
    bytes4 internal constant SEL_DELEGATE = 0x00000002;
    bytes4 internal constant SEL_UNDELEGATE = 0x00000003;
    bytes4 internal constant SEL_COMPOUND = 0x00000004;
    bytes4 internal constant SEL_WITHDRAW = 0x00000005;
    bytes4 internal constant SEL_CLAIM_REWARDS = 0x00000006;
    bytes4 internal constant SEL_GET_VALIDATOR_INFO = 0x00000007;
    bytes4 internal constant SEL_GET_DELEGATOR_INFO = 0x00000008;
    bytes4 internal constant SEL_GET_WITHDRAWAL_REQUEST = 0x00000009;
    bytes4 internal constant SEL_GET_CONSENSUS_VALSET = 0x0000000A;
    bytes4 internal constant SEL_GET_SNAPSHOT_VALSET = 0x0000000B;
    bytes4 internal constant SEL_GET_EXECUTION_VALSET = 0x0000000C;

    // Constants from the spec
    uint256 public constant EPOCH_LENGTH = 50000; // blocks
    uint256 public constant EPOCH_DELAY_PERIOD = 5000; // blocks
    uint8 public constant WITHDRAWAL_DELAY = 7; // epochs (TBD in spec, using 7 for testing)
    uint256 public constant MIN_VALIDATE_STAKE = 100 ether;
    uint256 public constant ACTIVE_VALIDATOR_STAKE = 1000 ether;
    uint256 public constant NUM_ACTIVE_VALIDATORS = 200;
    uint256 public constant REWARD = 1 ether; // per block
    uint256 public constant UNIT_BIAS = 1e18;

    // Structs from the spec
    struct KeysPacked {
        bytes secp_pubkey; // 33 bytes
        bytes bls_pubkey; // 48 bytes
    }

    struct ValExecution {
        uint256 stake;
        uint256 acc;
        uint256 commission;
        KeysPacked keys;
        uint256 address_flags;
        uint256 unclaimed_rewards;
    }

    struct ValConsensus {
        uint256 stake;
        KeysPacked keys;
    }

    struct DelInfo {
        uint256 stake; // Current active stake
        uint256 acc; // Last checked accumulator
        uint256 rewards; // Last checked rewards
        uint256 delta_stake; // Stake to be activated next epoch
        uint256 next_delta_stake; // Stake to be activated in 2 epochs
        uint64 delta_epoch; // Epoch when delta_stake becomes active
        uint64 next_delta_epoch; // Epoch when next_delta_stake becomes active
    }

    struct WithdrawalRequest {
        uint256 amount;
        uint256 acc;
        uint64 epoch;
    }

    struct Accumulator {
        uint256 val;
        uint256 refcount;
    }

    // State variables from the spec
    uint64 public epoch = 1;
    bool public in_boundary = false;
    uint64 public last_val_id = 0;
    uint256 public current_block = 1;

    constructor() {
        // Ensure state is properly initialized
        epoch = 1;
        current_block = 1;
    }

    // Initialize function for when deployed via vm.etch (bypasses constructor)
    function initialize() external {
        epoch = 1;
        current_block = 1;
    }

    // Mappings from the spec
    mapping(uint64 => ValExecution) public val_execution;
    mapping(uint64 => ValConsensus) public val_consensus;
    mapping(uint64 => ValConsensus) public val_snapshot;
    mapping(uint64 => mapping(address => DelInfo)) public delegator;
    mapping(uint64 => mapping(address => mapping(uint8 => WithdrawalRequest))) public withdrawal;
    mapping(uint64 => mapping(uint64 => Accumulator)) public epoch_acc;

    // Additional state for mock
    uint64[] public execution_valset;
    uint64[] public consensus_valset;
    uint64[] public snapshot_valset;

    fallback() external payable {
        require(msg.data.length >= 4, "Insufficient data");

        bytes4 selector = bytes4(msg.data[:4]);
        if (selector == SEL_ADD_VALIDATOR) {
            _handleAddValidator();
        } else if (selector == SEL_DELEGATE) {
            _handleDelegate();
        } else if (selector == SEL_UNDELEGATE) {
            _handleUndelegate();
        } else if (selector == SEL_COMPOUND) {
            _handleCompound();
        } else if (selector == SEL_WITHDRAW) {
            _handleWithdraw();
        } else if (selector == SEL_CLAIM_REWARDS) {
            _handleClaimRewards();
        } else if (selector == SEL_GET_VALIDATOR_INFO) {
            _handleGetValidatorInfo();
        } else if (selector == SEL_GET_DELEGATOR_INFO) {
            _handleGetDelegatorInfo();
        } else if (selector == SEL_GET_WITHDRAWAL_REQUEST) {
            _handleGetWithdrawalRequest();
        } else if (selector == SEL_GET_CONSENSUS_VALSET) {
            _handleGetConsensusValset();
        } else if (selector == SEL_GET_SNAPSHOT_VALSET) {
            _handleGetSnapshotValset();
        } else if (selector == SEL_GET_EXECUTION_VALSET) {
            _handleGetExecutionValset();
        } else {
            // Debug: Add the selector to the error message
            revert(string(abi.encodePacked("Unknown selector: ", _toHexString(uint256(uint32(selector)), 4))));
        }
    }

    function _toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = _HEX_SYMBOLS[value & 0xf];
            value >>= 4;
        }
        require(value == 0, "Strings: hex length insufficient");
        return string(buffer);
    }

    bytes16 private constant _HEX_SYMBOLS = "0123456789abcdef";

    // Helper functions
    function _isInBoundaryPeriod() internal view returns (bool) {
        uint256 epochStart = ((epoch - 1) * EPOCH_LENGTH) + 1;
        uint256 boundaryBlock = epochStart + EPOCH_LENGTH - EPOCH_DELAY_PERIOD;
        return current_block >= boundaryBlock;
    }

    function _getActivationEpoch() internal view returns (uint64) {
        return _isInBoundaryPeriod() ? epoch + 2 : epoch + 1;
    }

    function _getWithdrawalEpoch() internal view returns (uint64) {
        uint64 activationEpoch = _getActivationEpoch();
        return activationEpoch + WITHDRAWAL_DELAY;
    }

    function _handleAddValidator() internal {
        (bytes memory secp_pubkey, bytes memory bls_pubkey, address auth_address, uint256 amount, uint256 commission) =
            abi.decode(msg.data[4:], (bytes, bytes, address, uint256, uint256));

        require(msg.value == amount, "Amount mismatch");
        require(amount >= MIN_VALIDATE_STAKE, "Below min validate stake");
        require(commission <= 20e16, "Commission too high"); // Max 20%

        last_val_id++;
        uint64 valId = last_val_id;

        // Create validator
        val_execution[valId] = ValExecution({
            stake: amount,
            acc: 0,
            commission: commission,
            keys: KeysPacked(secp_pubkey, bls_pubkey),
            address_flags: 0,
            unclaimed_rewards: 0
        });

        // Create delegator account for validator
        uint64 activationEpoch = _getActivationEpoch();
        delegator[valId][auth_address] = DelInfo({
            stake: 0,
            acc: 0,
            rewards: 0,
            delta_stake: amount,
            next_delta_stake: 0,
            delta_epoch: activationEpoch,
            next_delta_epoch: 0
        });

        // Add to execution valset if meets threshold
        if (amount >= ACTIVE_VALIDATOR_STAKE) {
            execution_valset.push(valId);
        }

        bytes memory result = abi.encode(valId);
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }

    function _handleDelegate() internal {
        (uint64 valId, uint256 amount) = abi.decode(msg.data[4:], (uint64, uint256));
        require(amount > 0, "Amount must be > 0");
        require(val_execution[valId].stake > 0, "Invalid validator");
        require(address(this).balance >= amount, "Insufficient ETH balance");

        DelInfo storage del = delegator[valId][msg.sender];
        uint64 activationEpoch = _getActivationEpoch();

        // Update validator stake
        val_execution[valId].stake += amount;

        // Update delegator info
        if (del.delta_epoch == 0) {
            // First delegation
            del.delta_stake = amount;
            del.delta_epoch = activationEpoch;
        } else if (del.delta_epoch == activationEpoch) {
            // Same activation epoch
            del.delta_stake += amount;
        } else {
            // Different activation epoch
            del.next_delta_stake += amount;
            del.next_delta_epoch = activationEpoch;
        }

        // Add to execution valset if threshold met
        if (val_execution[valId].stake >= ACTIVE_VALIDATOR_STAKE) {
            bool found = false;
            for (uint256 i = 0; i < execution_valset.length; i++) {
                if (execution_valset[i] == valId) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                execution_valset.push(valId);
            }
        }

        bytes memory result = abi.encode(true);
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }

    function _handleUndelegate() internal {
        (uint64 valId, uint256 amount, uint8 withdrawalId) = abi.decode(msg.data[4:], (uint64, uint256, uint8));

        require(amount > 0, "Amount must be > 0");
        require(val_execution[valId].stake > 0, "Invalid validator");

        DelInfo storage del = delegator[valId][msg.sender];
        require(del.stake >= amount, "Insufficient stake");
        require(val_execution[valId].stake >= amount, "Validator insufficient stake");

        // Deactivation timing
        uint64 withdrawalEpoch = _getWithdrawalEpoch();

        // Update delegator stake (safely)
        if (del.stake >= amount) {
            del.stake -= amount;
        } else {
            del.stake = 0;
        }

        // Update validator stake (safely)
        if (val_execution[valId].stake >= amount) {
            val_execution[valId].stake -= amount;
        } else {
            val_execution[valId].stake = 0;
        }

        // Create withdrawal request
        withdrawal[valId][msg.sender][withdrawalId] =
            WithdrawalRequest({amount: amount, acc: val_execution[valId].acc, epoch: withdrawalEpoch});

        // Remove from execution valset if below threshold
        if (val_execution[valId].stake < ACTIVE_VALIDATOR_STAKE) {
            for (uint256 i = 0; i < execution_valset.length; i++) {
                if (execution_valset[i] == valId) {
                    execution_valset[i] = execution_valset[execution_valset.length - 1];
                    execution_valset.pop();
                    break;
                }
            }
        }
        bytes memory result = abi.encode(true);
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }

    function _handleWithdraw() internal {
        (uint64 valId, uint8 withdrawalId) = abi.decode(msg.data[4:], (uint64, uint8));

        WithdrawalRequest storage request = withdrawal[valId][msg.sender][withdrawalId];
        require(request.amount > 0, "No withdrawal request");
        require(request.epoch <= epoch, "Withdrawal not ready");

        uint256 amount = request.amount;
        delete withdrawal[valId][msg.sender][withdrawalId];

        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");

        bytes memory result = abi.encode(true);
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }

    function _handleCompound() internal {
        (uint64 valId) = abi.decode(msg.data[4:], (uint64));
        require(val_execution[valId].stake > 0, "Invalid validator");

        DelInfo storage del = delegator[valId][msg.sender];
        require(del.rewards > 0, "No rewards to compound");

        uint256 rewards = del.rewards;
        del.rewards = 0;

        // Add rewards as new delegation
        uint64 activationEpoch = _getActivationEpoch();
        val_execution[valId].stake += rewards;

        if (del.delta_epoch == 0) {
            del.delta_stake = rewards;
            del.delta_epoch = activationEpoch;
        } else if (del.delta_epoch == activationEpoch) {
            del.delta_stake += rewards;
        } else {
            del.next_delta_stake += rewards;
            del.next_delta_epoch = activationEpoch;
        }

        bytes memory result = abi.encode(true);
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }

    function _handleClaimRewards() internal {
        (uint64 valId) = abi.decode(msg.data[4:], (uint64));
        require(val_execution[valId].stake > 0, "Invalid validator");

        DelInfo storage del = delegator[valId][msg.sender];
        require(del.rewards > 0, "No rewards to claim");

        uint256 rewards = del.rewards;
        del.rewards = 0;

        (bool success,) = msg.sender.call{value: rewards}("");
        require(success, "Reward transfer failed");
    }

    function _handleGetValidatorInfo() internal view {
        (uint64 valId) = abi.decode(msg.data[4:], (uint64));

        ValExecution memory valExec = val_execution[valId];
        ValConsensus memory valCons = val_consensus[valId];
        ValConsensus memory valSnap = val_snapshot[valId];

        bytes memory result = abi.encode(valExec, valCons.stake, valSnap.stake);
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }

    function _handleGetDelegatorInfo() internal view {
        (uint64 valId, address delegatorAddr) = abi.decode(msg.data[4:], (uint64, address));

        DelInfo memory del = delegator[valId][delegatorAddr];
        // According to the docs: "Typed view for delegator info: return stake amount (first word)"
        // The CoreVault expects only the stake amount, not the full struct
        bytes memory result = abi.encode(del.stake);
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }

    function _handleGetWithdrawalRequest() internal view {
        (uint64 valId, address delegatorAddr, uint8 withdrawalId) = abi.decode(msg.data[4:], (uint64, address, uint8));

        WithdrawalRequest memory request = withdrawal[valId][delegatorAddr][withdrawalId];
        bytes memory result = abi.encode(request.amount, request.acc, request.epoch);
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }

    function _handleGetConsensusValset() internal view {
        (uint32 start_index) = abi.decode(msg.data[4:], (uint32));

        uint256 len = consensus_valset.length;
        uint256 end = start_index + 100; // Max 100 per call
        if (end > len) end = len;

        uint64[] memory result = new uint64[](end - start_index);
        for (uint256 i = start_index; i < end; i++) {
            result[i - start_index] = consensus_valset[i];
        }

        bool at_end = end >= len;
        uint32 next_start = uint32(end);

        bytes memory encoded = abi.encode(at_end, next_start, result);
        assembly {
            return(add(encoded, 0x20), mload(encoded))
        }
    }

    function _handleGetSnapshotValset() internal view {
        (uint32 start_index) = abi.decode(msg.data[4:], (uint32));

        uint256 len = snapshot_valset.length;
        uint256 end = start_index + 100;
        if (end > len) end = len;

        uint64[] memory result = new uint64[](end - start_index);
        for (uint256 i = start_index; i < end; i++) {
            result[i - start_index] = snapshot_valset[i];
        }

        bool at_end = end >= len;
        uint32 next_start = uint32(end);

        bytes memory encoded = abi.encode(at_end, next_start, result);
        assembly {
            return(add(encoded, 0x20), mload(encoded))
        }
    }

    function _handleGetExecutionValset() internal view {
        (uint32 start_index) = abi.decode(msg.data[4:], (uint32));

        uint256 len = execution_valset.length;
        uint256 end = start_index + 100;
        if (end > len) end = len;

        uint64[] memory result = new uint64[](end - start_index);
        for (uint256 i = start_index; i < end; i++) {
            result[i - start_index] = execution_valset[i];
        }

        bool at_end = end >= len;
        uint32 next_start = uint32(end);

        bytes memory encoded = abi.encode(at_end, next_start, result);
        assembly {
            return(add(encoded, 0x20), mload(encoded))
        }
    }

    // Admin functions for testing
    function advanceBlock() external {
        current_block++;

        // Check if we need to advance epoch
        uint256 epochStart = ((epoch - 1) * EPOCH_LENGTH) + 1;
        if (current_block >= epochStart + EPOCH_LENGTH) {
            _advanceEpoch();
        }

        // Update boundary status
        in_boundary = _isInBoundaryPeriod();
    }

    function _advanceEpoch() internal {
        // Simulate syscall_snapshot - copy execution to consensus
        delete consensus_valset;
        for (uint256 i = 0; i < execution_valset.length; i++) {
            uint64 valId = execution_valset[i];
            consensus_valset.push(valId);
            val_consensus[valId] = ValConsensus({stake: val_execution[valId].stake, keys: val_execution[valId].keys});
        }

        // Copy old consensus to snapshot
        delete snapshot_valset;
        for (uint256 i = 0; i < consensus_valset.length; i++) {
            uint64 valId = consensus_valset[i];
            snapshot_valset.push(valId);
            val_snapshot[valId] = val_consensus[valId];
        }

        // Activate pending delegations
        for (uint256 i = 0; i < execution_valset.length; i++) {
            // uint64 valId = execution_valset[i];
            // Note: In a full implementation, we'd iterate through all delegators
            // For simplicity, this mock doesn't track all delegators
        }

        epoch++;
    }

    function advanceEpoch() external {
        _advanceEpoch();
    }

    function setDelegatorStake(uint64 valId, address delegatorAddr, uint256 amount) external {
        delegator[valId][delegatorAddr].stake = amount;

        // Always create or update validator to match
        val_execution[valId] = ValExecution({
            stake: amount, // For testing, validator stake = delegator stake
            acc: 0,
            commission: 0,
            keys: KeysPacked(bytes(""), bytes("")),
            address_flags: 0,
            unclaimed_rewards: 0
        });

        // Add to execution valset if not already present
        bool found = false;
        for (uint256 i = 0; i < execution_valset.length; i++) {
            if (execution_valset[i] == valId) {
                found = true;
                break;
            }
        }
        if (!found) {
            execution_valset.push(valId);
        }
    }

    function setDelegatorRewards(uint64 valId, address delegatorAddr, uint256 rewards) external {
        delegator[valId][delegatorAddr].rewards = rewards;
    }

    function addRewards(uint64 valId, uint256 blockReward) external {
        require(val_execution[valId].stake > 0, "Invalid validator");

        uint256 commission = (blockReward * val_execution[valId].commission) / 1e18;
        uint256 delegatorReward = blockReward - commission;

        val_execution[valId].unclaimed_rewards += commission;

        // Distribute to delegators (simplified - in reality would use accumulator)
        // For testing, we just add to validator's delegator account
        if (val_execution[valId].stake > 0) {
            val_execution[valId].acc += (delegatorReward * UNIT_BIAS) / val_execution[valId].stake;
        }
    }

    // Debug functions for testing
    function debugDelegatorStake(uint64 valId, address delegatorAddr) external view returns (uint256) {
        return delegator[valId][delegatorAddr].stake;
    }

    function debugValidatorStake(uint64 valId) external view returns (uint256) {
        return val_execution[valId].stake;
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
