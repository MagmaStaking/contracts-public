// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

abstract contract PausableValId is Initializable, ContextUpgradeable {
    /// @custom:storage-location erc7201:openzeppelin.storage.PausableValId
    struct PausableValIdStorage {
        mapping(uint64 => bool) _paused;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.PausableValId")) - 1)) & ~bytes32(uint256(0xff))
    /* solhint-disable-next-line const-name-snakecase */
    bytes32 private constant PausableValIdStorageLocation =
        0xa6041e4ae1cf4ce626132eb45536c67977df2cdadeba9f118e22eb8c2f4aa600;

    function _getPausableStorageValId() private pure returns (PausableValIdStorage storage $) {
        assembly {
            $.slot := PausableValIdStorageLocation
        }
    }

    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event PausedValId(address indexed account, uint64 indexed valId);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event UnpausedValId(address indexed account, uint64 indexed valId);

    /**
     * @dev The operation failed because the validator is paused.
     */
    error EnforcedPauseValId();

    /**
     * @dev The operation failed because the validator is not paused.
     */
    error ExpectedPauseValId();

    /**
     * @dev Modifier to make a function callable only when the validator is not paused.
     *
     * Requirements:
     *
     * - The validator must not be paused.
     */
    modifier whenNotPausedValId(uint64 _valId) {
        _requireNotPausedValId(_valId);
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the validator is paused.
     *
     * Requirements:
     *
     * - The validator must be paused.
     */
    modifier whenPausedValId(uint64 _valId) {
        _requirePausedValId(_valId);
        _;
    }

    /* solhint-disable-next-line */
    function __PausableValId_init() internal onlyInitializing {}

    /**
     * @dev Returns true if the validator is paused, and false otherwise.
     */
    function pausedValId(uint64 _valId) public view virtual returns (bool) {
        PausableValIdStorage storage $ = _getPausableStorageValId();
        return $._paused[_valId];
    }

    /**
     * @dev Throws if the validator is paused.
     */
    function _requireNotPausedValId(uint64 _valId) internal view virtual {
        if (pausedValId(_valId)) {
            revert EnforcedPauseValId();
        }
    }

    /**
     * @dev Throws if the validator is not paused.
     */
    function _requirePausedValId(uint64 _valId) internal view virtual {
        if (!pausedValId(_valId)) {
            revert ExpectedPauseValId();
        }
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The validator must not be paused.
     */
    function _pauseValId(uint64 _valId) internal virtual whenNotPausedValId(_valId) {
        PausableValIdStorage storage $ = _getPausableStorageValId();
        $._paused[_valId] = true;
        emit PausedValId(_msgSender(), _valId);
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The validator must be paused.
     */
    function _unpauseValId(uint64 _valId) internal virtual whenPausedValId(_valId) {
        PausableValIdStorage storage $ = _getPausableStorageValId();
        $._paused[_valId] = false;
        emit UnpausedValId(_msgSender(), _valId);
    }
}
