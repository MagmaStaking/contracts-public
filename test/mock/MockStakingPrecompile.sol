/* solhint-disable */
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";
import {IMonadStaking} from "../../interfaces/IMonadStaking.sol";

/**
 * @title MockStakingPrecompile
 * @dev Mock implementation of Monad staking precompile for testing
 * Following the specification from Monad_Staking.md
 */
contract MockStakingPrecompile is IMonadStaking {
    // Constants from the spec
    uint256 public constant EPOCH_LENGTH = 50000; // blocks
    uint256 public constant EPOCH_DELAY_PERIOD = 5000; // blocks
    uint8 public constant WITHDRAWAL_DELAY = 7; // epochs (TBD in spec, using 7 for testing)
    uint256 public constant MIN_VALIDATE_STAKE = 100 ether;
    uint256 public constant ACTIVE_VALIDATOR_STAKE = 1000 ether;
    uint256 public constant NUM_ACTIVE_VALIDATORS = 200;
    uint256 public constant REWARD = 1 ether; // per block
    uint256 public constant UNIT_BIAS = 1e18;

    bool public withdrawRevert = false;
    uint256 public slashDivider = 1;

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
        uint256 deltaStake; // Stake to be activated next epoch
        uint256 nextDeltaStake; // Stake to be activated in 2 epochs
        uint64 deltaEpoch; // Epoch when deltaStake becomes active
        uint64 nextDeltaEpoch; // Epoch when nextDeltaStake becomes active
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
        slashDivider = 1;
        withdrawRevert = false;
    }

    // Initialize function for when deployed via vm.etch (bypasses constructor)
    function initialize() external {
        epoch = 1;
        current_block = 1;
        slashDivider = 1;
        withdrawRevert = false;
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

    // Direct implementation of IMonadStaking interface functions

    // Helper function to unpack addValidator payload
    function _unpackAddValidatorPayload(bytes memory payload)
        internal
        pure
        returns (
            bytes memory secp_pubkey,
            bytes memory bls_pubkey,
            address auth_address,
            uint256 amount,
            uint256 commission
        )
    {
        // According to Monad docs, payload is abi.encodePacked of:
        // bytes secpPubkey (33 bytes)
        // bytes blsPubkey (48 bytes)
        // address authAddress (20 bytes)
        // uint256 amount (32 bytes)
        // uint256 commission (32 bytes)
        require(payload.length >= 33 + 48 + 20 + 32 + 32, "Invalid payload length");

        secp_pubkey = new bytes(33);
        bls_pubkey = new bytes(48);

        uint256 offset = 0;

        // Extract secp_pubkey (33 bytes)
        for (uint256 i = 0; i < 33; i++) {
            secp_pubkey[i] = payload[offset + i];
        }
        offset += 33;

        // Extract bls_pubkey (48 bytes)
        for (uint256 i = 0; i < 48; i++) {
            bls_pubkey[i] = payload[offset + i];
        }
        offset += 48;

        // Extract auth_address (20 bytes)
        assembly {
            auth_address := mload(add(add(payload, 0x20), offset))
        }
        offset += 20;

        // Extract amount (32 bytes)
        assembly {
            amount := mload(add(add(payload, 0x20), offset))
        }
        offset += 32;

        // Extract commission (32 bytes)
        assembly {
            commission := mload(add(add(payload, 0x20), offset))
        }
    }

    // Helper functions
    function setWithdrawRevert(bool _withdrawRevert) public {
        withdrawRevert = _withdrawRevert;
    }

    function setSlashDivider(uint256 divider) public {
        slashDivider = divider;
    }

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

    function addValidator(
        bytes calldata payload,
        bytes calldata, /* signedSecpMessage */
        bytes calldata /* signedBlsMessage */
    ) external payable override returns (uint64 validatorId) {
        // Unpack the payload according to the official specification
        (bytes memory secp_pubkey, bytes memory bls_pubkey, address auth_address, uint256 amount, uint256 commission) =
            _unpackAddValidatorPayload(payload);

        require(msg.value == amount, "Amount mismatch");
        require(amount >= MIN_VALIDATE_STAKE, "Below min validate stake");
        require(commission <= 20e16, "Commission too high"); // Max 20%

        // For testing, we skip signature verification
        // In production, would verify signedSecpMessage and signedBlsMessage

        last_val_id++;
        validatorId = last_val_id;

        // Create validator
        val_execution[validatorId] = ValExecution({
            stake: amount,
            acc: 0,
            commission: commission,
            keys: KeysPacked(secp_pubkey, bls_pubkey),
            address_flags: 0,
            unclaimed_rewards: 0
        });

        // Create delegator account for validator
        uint64 activationEpoch = _getActivationEpoch();
        delegator[validatorId][auth_address] = DelInfo({
            stake: 0,
            acc: 0,
            rewards: 0,
            deltaStake: amount,
            nextDeltaStake: 0,
            deltaEpoch: activationEpoch,
            nextDeltaEpoch: 0
        });

        // Add to execution valset if meets threshold
        if (amount >= ACTIVE_VALIDATOR_STAKE) {
            execution_valset.push(validatorId);
        }

        return validatorId;
    }

    function delegate(uint64 validatorId) external payable override returns (bool success) {
        uint256 amount = msg.value;
        require(amount > 0, "Amount must be > 0");
        require(val_execution[validatorId].stake > 0, "Invalid validator");

        DelInfo storage del = delegator[validatorId][msg.sender];
        uint64 activationEpoch = _getActivationEpoch();

        // Track this delegator for this validator
        if (!hasDelegator[validatorId][msg.sender]) {
            validatorDelegators[validatorId].push(msg.sender);
            hasDelegator[validatorId][msg.sender] = true;
        }

        // Update validator stake
        val_execution[validatorId].stake += amount;

        // Update delegator info
        if (del.deltaEpoch == 0) {
            // First delegation
            del.deltaStake = amount;
            del.deltaEpoch = activationEpoch;
        } else if (del.deltaEpoch == activationEpoch) {
            // Same activation epoch
            del.deltaStake += amount;
        } else {
            // Different activation epoch
            del.nextDeltaStake += amount;
            del.nextDeltaEpoch = activationEpoch;
        }

        // Add to execution valset if threshold met
        if (val_execution[validatorId].stake >= ACTIVE_VALIDATOR_STAKE) {
            bool found = false;
            for (uint256 i = 0; i < execution_valset.length; i++) {
                if (execution_valset[i] == validatorId) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                execution_valset.push(validatorId);
            }
        }

        return true;
    }

    function undelegate(uint64 validatorId, uint256 amount, uint8 withdrawId)
        external
        override
        returns (bool success)
    {
        require(amount > 0, "Amount must be > 0");
        require(val_execution[validatorId].stake > 0, "Invalid validator");

        DelInfo storage del = delegator[validatorId][msg.sender];
        require(del.stake >= amount, "Insufficient stake");
        require(val_execution[validatorId].stake >= amount, "Validator insufficient stake");

        // Deactivation timing
        uint64 withdrawalEpoch = _getWithdrawalEpoch();

        // Update delegator stake (safely)
        if (del.stake >= amount) {
            del.stake -= amount;
        } else {
            del.stake = 0;
        }

        // Update validator stake (safely)
        if (val_execution[validatorId].stake >= amount) {
            val_execution[validatorId].stake -= amount;
        } else {
            val_execution[validatorId].stake = 0;
        }

        // Create withdrawal request
        withdrawal[validatorId][msg.sender][withdrawId] =
            WithdrawalRequest({amount: amount, acc: val_execution[validatorId].acc, epoch: withdrawalEpoch});

        // Remove from execution valset if below threshold
        if (val_execution[validatorId].stake < ACTIVE_VALIDATOR_STAKE) {
            for (uint256 i = 0; i < execution_valset.length; i++) {
                if (execution_valset[i] == validatorId) {
                    execution_valset[i] = execution_valset[execution_valset.length - 1];
                    execution_valset.pop();
                    break;
                }
            }
        }

        return true;
    }

    function withdraw(uint64 validatorId, uint8 withdrawId) external override returns (bool success) {
        if (withdrawRevert) {
            return false;
        }

        WithdrawalRequest storage request = withdrawal[validatorId][msg.sender][withdrawId];
        require(request.amount > 0, "No withdrawal request");
        require(request.epoch <= epoch, "Withdrawal not ready");

        uint256 amount = request.amount;
        delete withdrawal[validatorId][msg.sender][withdrawId];

        (bool transferSuccess,) = msg.sender.call{value: amount}("");
        require(transferSuccess, "Transfer failed");

        return true;
    }

    function compound(uint64 validatorId) external override returns (bool success) {
        require(val_execution[validatorId].stake > 0, "Invalid validator");

        DelInfo storage del = delegator[validatorId][msg.sender];
        require(del.rewards > 0, "No rewards to compound");

        uint256 rewards = del.rewards;
        del.rewards = 0;

        // Add rewards as new delegation
        uint64 activationEpoch = _getActivationEpoch();
        val_execution[validatorId].stake += rewards;

        if (del.deltaEpoch == 0) {
            del.deltaStake = rewards;
            del.deltaEpoch = activationEpoch;
        } else if (del.deltaEpoch == activationEpoch) {
            del.deltaStake += rewards;
        } else {
            del.nextDeltaStake += rewards;
            del.nextDeltaEpoch = activationEpoch;
        }

        return true;
    }

    function claimRewards(uint64 validatorId) external override returns (bool success) {
        if (val_execution[validatorId].stake == 0) {
            return false;
        }

        DelInfo storage del = delegator[validatorId][msg.sender];
        if (del.rewards == 0) {
            return false;
        }

        uint256 rewards = del.rewards;
        del.rewards = 0;

        (bool transferSuccess,) = msg.sender.call{value: rewards}("");
        if (!transferSuccess) {
            return false;
        }

        return true;
    }

    // Missing interface functions that need to be implemented
    function changeCommission(uint64 validatorId, uint256 commission) external override returns (bool success) {
        require(val_execution[validatorId].stake > 0, "Invalid validator");
        require(commission <= 20e16, "Commission too high"); // Max 20%
        val_execution[validatorId].commission = commission;
        return true;
    }

    function externalReward(uint64 validatorId) external override returns (bool success) {
        // For testing purposes, this is a no-op
        require(val_execution[validatorId].stake > 0, "Invalid validator");
        return true;
    }

    function getValidator(uint64 validatorId)
        external
        view
        override
        returns (
            address authAddress,
            uint64 flags,
            uint256 stake,
            uint256 accRewardPerToken,
            uint256 commission,
            uint256 unclaimedRewards,
            uint256 consensusStake,
            uint256 consensusCommission,
            uint256 snapshotStake,
            uint256 snapshotCommission,
            bytes memory secpPubkey,
            bytes memory blsPubkey
        )
    {
        // Split into multiple assignments to avoid stack too deep
        ValExecution storage valExec = val_execution[validatorId];

        authAddress = address(0); // simplified for testing
        flags = uint64(valExec.address_flags);
        stake = valExec.stake;
        accRewardPerToken = valExec.acc;
        commission = valExec.commission;
        unclaimedRewards = valExec.unclaimed_rewards;
        consensusStake = val_consensus[validatorId].stake;
        consensusCommission = valExec.commission; // simplified
        snapshotStake = val_snapshot[validatorId].stake;
        snapshotCommission = valExec.commission; // simplified
        secpPubkey = valExec.keys.secp_pubkey;
        blsPubkey = valExec.keys.bls_pubkey;
    }

    function getDelegator(uint64 validatorId, address delegatorAddr)
        external
        view
        override
        returns (
            uint256 stake,
            uint256 accRewardPerToken,
            uint256 unclaimedRewards,
            uint256 deltaStake,
            uint256 nextDeltaStake,
            uint64 deltaEpoch,
            uint64 nextDeltaEpoch
        )
    {
        DelInfo memory del = delegator[validatorId][delegatorAddr];
        return (del.stake, del.acc, del.rewards, del.deltaStake, del.nextDeltaStake, del.deltaEpoch, del.nextDeltaEpoch);
    }

    function getWithdrawalRequest(uint64 validatorId, address delegatorAddr, uint8 withdrawId)
        external
        override
        returns (uint256 withdrawalAmount, uint256 accRewardPerToken, uint64 withdrawEpoch)
    {
        WithdrawalRequest memory request = withdrawal[validatorId][delegatorAddr][withdrawId];
        return (request.amount / slashDivider, request.acc, request.epoch);
    }

    function getConsensusValidatorSet(uint32 startIndex)
        external
        override
        returns (bool isDone, uint32 nextIndex, uint64[] memory valIds)
    {
        uint256 len = consensus_valset.length;
        uint256 end = startIndex + 100; // Max 100 per call
        if (end > len) end = len;

        uint64[] memory result = new uint64[](end - startIndex);
        for (uint256 i = startIndex; i < end; i++) {
            result[i - startIndex] = consensus_valset[i];
        }

        return (end >= len, uint32(end), result);
    }

    function getSnapshotValidatorSet(uint32 startIndex)
        external
        override
        returns (bool isDone, uint32 nextIndex, uint64[] memory valIds)
    {
        uint256 len = snapshot_valset.length;
        uint256 end = startIndex + 100;
        if (end > len) end = len;

        uint64[] memory result = new uint64[](end - startIndex);
        for (uint256 i = startIndex; i < end; i++) {
            result[i - startIndex] = snapshot_valset[i];
        }

        return (end >= len, uint32(end), result);
    }

    function getExecutionValidatorSet(uint32 startIndex)
        external
        override
        returns (bool isDone, uint32 nextIndex, uint64[] memory valIds)
    {
        uint256 len = execution_valset.length;
        uint256 end = startIndex + 100;
        if (end > len) end = len;

        uint64[] memory result = new uint64[](end - startIndex);
        for (uint256 i = startIndex; i < end; i++) {
            result[i - startIndex] = execution_valset[i];
        }

        return (end >= len, uint32(end), result);
    }

    function getDelegations(address, /* delegatorAddr */ uint64 startValId)
        external
        override
        returns (bool isDone, uint64 nextValId, uint64[] memory valIds)
    {
        // Simplified implementation for testing
        uint64[] memory result = new uint64[](0);
        return (true, startValId, result);
    }

    function getDelegators(uint64 validatorId, address startDelegator)
        external
        override
        returns (bool isDone, address nextDelegator, address[] memory delegators)
    {
        // Return the stored delegators for this validator
        address[] memory result = validatorDelegators[validatorId];
        return (true, startDelegator, result);
    }

    function getEpoch() external override returns (uint64, bool) {
        return (epoch, in_boundary);
    }

    function syscallOnEpochChange(uint64) external override {
        // No-op for testing
    }

    function syscallReward(address) external override {
        // No-op for testing
    }

    function syscallSnapshot() external override {
        // No-op for testing
    }

    // Old handler functions removed - now using direct interface implementation

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

        // Activate pending delegations - we need to track all active delegators
        // For our test purposes, we'll activate pending stakes for known delegators
        for (uint256 i = 0; i < execution_valset.length; i++) {
            uint64 valId = execution_valset[i];
            // We need to activate pending stakes for any delegator that has them
            // This is a simplified approach for testing
            _activatePendingStakes(valId);
        }

        epoch++;
    }

    function advanceEpoch() external {
        _advanceEpoch();
    }

    function setDelegatorStake(uint64 valId, address delegatorAddr, uint256 amount) external {
        // Store the old stake to calculate validator total change
        uint256 oldStake = delegator[valId][delegatorAddr].stake;

        // Clear all pending stakes to avoid ErrPendingStakeNotZero issues
        delegator[valId][delegatorAddr].stake = amount;
        delegator[valId][delegatorAddr].deltaStake = 0;
        delegator[valId][delegatorAddr].nextDeltaStake = 0;
        delegator[valId][delegatorAddr].deltaEpoch = 0;
        delegator[valId][delegatorAddr].nextDeltaEpoch = 0;

        // Update validator total stake by adjusting for this delegator's change
        if (val_execution[valId].stake == 0) {
            // First time setting up this validator
            val_execution[valId] = ValExecution({
                stake: amount,
                acc: 0,
                commission: 0,
                keys: KeysPacked(bytes(""), bytes("")),
                address_flags: 0,
                unclaimed_rewards: 0
            });
        } else {
            // Adjust existing validator stake: remove old delegator stake, add new
            val_execution[valId].stake = val_execution[valId].stake - oldStake + amount;
        }

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

    function setDelegatorPendingStake(uint64 valId, address delegatorAddr, uint256 deltaStake, uint256 nextDeltaStake)
        external
    {
        delegator[valId][delegatorAddr].deltaStake = deltaStake;
        delegator[valId][delegatorAddr].nextDeltaStake = nextDeltaStake;
    }

    // Helper function to manually set up a validator with specific ID for testing
    function setupValidator(uint64 valId, uint256 stake) external {
        val_execution[valId] = ValExecution({
            stake: stake,
            acc: 0,
            commission: 0,
            keys: KeysPacked("", ""),
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

    // Keep track of delegators for each validator
    mapping(uint64 => address[]) public validatorDelegators;
    mapping(uint64 => mapping(address => bool)) public hasDelegator;

    function _activatePendingStakes(uint64 valId) internal {
        address[] storage delegators = validatorDelegators[valId];
        for (uint256 i = 0; i < delegators.length; i++) {
            address delegatorAddr = delegators[i];
            DelInfo storage del = delegator[valId][delegatorAddr];

            // Activate deltaStake if the epoch matches
            if (del.deltaEpoch <= epoch && del.deltaStake > 0) {
                del.stake += del.deltaStake;
                del.deltaStake = 0;
            }

            // Move nextDeltaStake to deltaStake if needed
            if (del.nextDeltaEpoch <= epoch && del.nextDeltaStake > 0) {
                del.deltaStake = del.nextDeltaStake;
                del.deltaEpoch = epoch + 1;
                del.nextDeltaStake = 0;
                del.nextDeltaEpoch = 0;
            }
        }
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

    /**
     * @dev Helper function to create a withdrawal request for testing
     * This simulates a completed undelegation that's ready for withdrawal
     */
    function createWithdrawalRequest(
        uint64 valId,
        address delegatorAddr,
        uint8 withdrawalId,
        uint256 amount,
        uint64 withdrawalEpoch
    ) external {
        withdrawal[valId][delegatorAddr][withdrawalId] =
            WithdrawalRequest({amount: amount, acc: val_execution[valId].acc, epoch: withdrawalEpoch});

        // Contract balance should already be sufficient for withdrawal
        // In real scenario, this would come from validator unstaking
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
