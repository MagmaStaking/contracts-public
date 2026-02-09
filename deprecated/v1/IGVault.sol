// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IBaseVault} from "../../interfaces/IBaseVault.sol";

interface IGVault is IBaseVault {
    // Admin functions
    function addValidator(uint64 valId) external;
    function changeValidatorCap(uint64 valId, uint256 newCap) external;
    function setDefaultCapBps(uint256 newBps) external;
    function adminInitiateRebalanceBps(uint16 bps) external;
    function adminCompleteRebalance() external;

    // Withdrawal completion function
    function completeUserWithdrawal(address user)
        external
        returns (uint256 _totalWithdrawn, uint256 _totalWithdrawnAfterFeen);

    // Delegation functions (onlyMagma)
    function delegate(address user, uint64 valId) external payable;
    function undelegate(address user, uint64 valId, uint256 amount) external;

    // Withdrawal completion functions

    // Initialization
    function initialize(address _magma, uint256 _epochSeconds) external;

    // View functions
    function delegatedAmountOf(address user, uint64 valId) external returns (uint256);
    function maxWithdrawableFromGVault(address _user, uint64 _valId) external view returns (uint256);
    function validatorCap(uint64 valId) external view returns (uint256);
    function defaultCapBps() external view returns (uint256);

    event PositionUpdated(address indexed user, uint64 indexed valId, uint256 indexed amount, bool isDelegate);
    event CapChanged(uint64 indexed valId, uint256 indexed newCap);
    event DefaultCapUpdated(uint256 indexed newDefaultBps);
    event GVaultMultiplierUpdated(uint256 indexed oldP, uint256 indexed newP, uint16 indexed bps);
    event GVaultRescaled(uint256 indexed factorK, uint256 indexed newP, uint256 indexed newS);

    // Rebalance admin events
    event AdminInitiatedRebalance(uint16 indexed bps);
    event AdminCompletedRebalance(uint256 indexed amountForwarded);
    event AdminCompletedRebalanceWithdrawal(uint64 indexed valId, uint256 indexed amount);
    event RewardsInjected(uint256 indexed amount, uint64 indexed valId);
}
