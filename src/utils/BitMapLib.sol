// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ErrNoFreeWithdrawalId} from "../MagmaErrorsModule.sol";

/**
 * @title BitMapLib
 * @dev Library for managing withdrawal ID bitmaps for validator operations
 * Handles allocation and deallocation of withdrawal IDs (0-255) with support for reserved admin IDs
 */
library BitMapLib {
    error NoFreeWithdrawalId();

    // Reserved admin withdrawal IDs for different vault types
    uint8 internal constant ADMIN_WID = 255;

    /**
     * @dev Struct to store bitmap state for a validator
     * @param bitmap 256-bit bitmap where each bit represents a withdrawal ID (bit set = ID in use)
     * @param nextWithdrawalId Cursor for the next withdrawal ID to check (optimization for allocation)
     */
    struct WithdrawalBitMap {
        uint256 bitmap;
        uint8 nextWithdrawalId;
    }

    /**
     * @dev Initialize bitmap for CoreVault with ADMIN_WID marked as reserved
     * @param bitMap The bitmap storage reference
     */
    function init(WithdrawalBitMap storage bitMap) internal {
        uint256 adminMask = 1 << ADMIN_WID;
        bitMap.bitmap |= adminMask;
    }

    /**
     * @dev Allocate a free withdrawal ID for CoreVault, skipping ADMIN_WID
     * @param bitMap The bitmap storage reference
     * @return wid The allocated withdrawal ID (0-255)
     * @custom:throws NoFreeWithdrawalId if all 256 IDs are occupied
     */
    function allocateWithdrawalId(WithdrawalBitMap storage bitMap) internal returns (uint8 wid) {
        return _allocateWithdrawalId(bitMap, ADMIN_WID);
    }

    /**
     * @dev Mark a withdrawal ID as completed (free) in the bitmap for CoreVault, skipping ADMIN_WID
     * @param bitMap The bitmap storage reference
     * @param withdrawalId The withdrawal ID to mark as free
     */
    function markWithdrawalCompleted(WithdrawalBitMap storage bitMap, uint8 withdrawalId) internal {
        uint256 mask = 1 << withdrawalId;
        bitMap.bitmap &= ~mask; // Clear the bit
    }

    /**
     * @dev Check if a withdrawal ID is currently in use
     * @param bitMap The bitmap storage reference
     * @param withdrawalId The withdrawal ID to check
     * @return true if the ID is in use, false if available
     */
    function isWithdrawalIdInUse(WithdrawalBitMap storage bitMap, uint8 withdrawalId) internal view returns (bool) {
        uint256 mask = 1 << withdrawalId;
        return (bitMap.bitmap & mask) != 0;
    }

    /**
     * @dev Get the current bitmap value
     * @param bitMap The bitmap storage reference
     * @return The 256-bit bitmap value
     */
    function getBitmap(WithdrawalBitMap storage bitMap) internal view returns (uint256) {
        return bitMap.bitmap;
    }

    /**
     * @dev Get the next withdrawal ID cursor
     * @param bitMap The bitmap storage reference
     * @return The next withdrawal ID cursor
     */
    function getNextWithdrawalId(WithdrawalBitMap storage bitMap) internal view returns (uint8) {
        return bitMap.nextWithdrawalId;
    }

    /**
     * @dev Count the number of withdrawal IDs currently in use
     * @param bitMap The bitmap storage reference
     * @return count The number of bits set in the bitmap
     */
    function countInUse(WithdrawalBitMap storage bitMap) internal view returns (uint256 count) {
        uint256 bitmap = bitMap.bitmap;
        // Brian Kernighan's algorithm to count set bits
        while (bitmap != 0) {
            bitmap &= bitmap - 1; // Clear the lowest set bit
            count++;
        }
    }

    /**
     * @dev Internal function to allocate a free withdrawal ID, skipping the specified reserved ID
     * @param bitMap The bitmap storage reference
     * @param reservedId The reserved ID to skip during allocation
     * @return wid The allocated withdrawal ID (0-255)
     * @custom:throws NoFreeWithdrawalId if all 256 IDs are occupied
     */
    function _allocateWithdrawalId(WithdrawalBitMap storage bitMap, uint8 reservedId) private returns (uint8 wid) {
        uint256 bitmap = bitMap.bitmap;
        uint8 start = bitMap.nextWithdrawalId;

        // Find first free slot starting from cursor
        for (uint16 i = 0; i < 256; i++) {
            uint8 candidate = uint8(uint16(start) + i);
            if (candidate == reservedId) continue;

            uint256 mask = 1 << candidate;
            if (bitmap & mask == 0) {
                // Mark as used in bitmap
                bitMap.bitmap |= mask;
                bitMap.nextWithdrawalId = uint8(uint16(candidate) + 1);
                return candidate;
            }
        }
        // If all 256 are occupied, revert
        revert NoFreeWithdrawalId();
    }
}
