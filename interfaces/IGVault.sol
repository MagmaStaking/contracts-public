// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IBaseVault} from "./IBaseVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IGVault is IBaseVault {
    // Admin functions
    function addValidator(uint64 _valId) external;
    function executeValidatorUndelegation(uint64 _valId) external;
    function completeValidatorRemovalWithdrawal(uint64 _valId) external;
    function changeValidatorCap(uint64 _valId, uint256 _newCap) external;
    function pauseValId(uint64 _valId) external;
    function unpauseValId(uint64 _valId) external;
    function setDefaultCapBps(uint256 _newBps) external;
    function adminInitiateRebalanceBpsValId(uint16 _bps, uint64 _valId, uint256 _start, uint256 _stop) external;
    function adminCompleteRebalance(uint64 _valId) external;
    function setMinUserDepositAmount(uint256 _amount) external;

    // Withdrawal completion function
    function completeUserWithdrawal(address _user)
        external
        returns (uint256 _totalWithdrawn, uint256 _totalWithdrawnAfterFee);

    // Delegation functions (onlyMagma)
    function delegate(address _user, uint64 _valId, uint256 _magmaShares) external payable;
    function undelegate(address _user, uint64 _valId, uint256 _amount, uint256 _magmaShares) external;

    // Asset functions
    function magmaSharesToGvaultAssets(uint64 _valId, address _user, uint256 _magmaShares) external returns (uint256);
    function sharesForAssets(uint64 _valId, uint256 _assets, Math.Rounding _r) external returns (uint256);

    // Rewards functions
    function injectRewards(uint64 _valId) external payable;
    function claimAndCompoundRewards() external;

    // Initialization
    function initialize(address _magma, uint256 _epochSeconds) external;

    // View functions
    function accountsByValidatorLength(uint64 _valId) external view returns (uint256);
    function sharesForUserByValidator(address _account, uint64 _valId) external view returns (uint256);
    function totalSharesForValidator(uint64 _valId) external view returns (uint256);
    function magmaSharesForUserByValidator(address _account, uint64 _valId) external view returns (uint256);
    function validatorCap(uint64 _valId) external view returns (uint256);
    function defaultCapBps() external view returns (uint256);
    function delegatedAmount(uint64 _valId) external returns (uint256);
    function lastRebalancedStartIndex(uint64 _valId) external view returns (uint256);
    function lastRebalancedBps(uint64 _valId) external view returns (uint256);
    function minUserDepositAmount() external view returns (uint256);

    event CapChanged(uint64 indexed valId, uint256 indexed newCap);
    event DefaultCapUpdated(uint256 indexed newDefaultBps);
    event AdminInitiatedRebalance(uint16 indexed bps, uint64 indexed valId);
    event AdminInitiatedRebalanceBatch(uint16 indexed bps, uint64 indexed valId, uint256 indexed start, uint256 stop);
    event AdminCompletedRebalance(uint256 indexed amountForwarded, uint64 indexed valId);
    event RewardsInjected(uint256 indexed amount, uint64 indexed valId);
    event MinUserDepositAmountUpdated(uint256 indexed newAmount);
}
