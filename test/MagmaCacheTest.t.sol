// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./BaseTest.t.sol";
import {DelInfo} from "../src/MagmaDelegationModule.sol";

contract MagmaCacheTest is BaseTest {
    uint256 constant DEFAULT_CACHE_INTERVAL = 1 hours;

    function setUp() public override {
        super.setUp();

        // Ensure validators are available (BaseTest already adds 1 and 2)
        vm.startPrank(admin);
        if (!coreVault.isWhitelisted(1)) coreVault.addValidator(1);
        if (!coreVault.isWhitelisted(2)) coreVault.addValidator(2);
        coreVault.setMinUserWithdrawAmount(1 ether);
        vm.stopPrank();

        // Make some initial delegation
        vm.deal(address(magma), 100 ether);
        vm.prank(address(magma));
        coreVault.delegate{value: 100 ether}();

        // Activate stakes
        _activatePendingDelegations();
        _activateAllStakes();
    }

    function test_CacheIsPopulatedAfterRefresh() public {
        // Initially cache should be empty/stale
        assertEq(coreVault.lastDelegatorInfoUpdateTimestamp(), 0, "Cache should be uninitialized");
        assertEq(coreVault.cachedTotalAssets(), 0, "Cached assets should be 0");

        // Refresh the cache
        coreVault.refreshCache();

        // Cache should now be populated
        assertGt(coreVault.lastDelegatorInfoUpdateTimestamp(), 0, "Cache timestamp should be set");
        assertEq(coreVault.cachedTotalAssets(), 100 ether, "Cached assets should equal delegated amount");

        // Check individual validator cache
        DelInfo memory delInfo1 = coreVault.cachedDelegatorInfo(1);
        DelInfo memory delInfo2 = coreVault.cachedDelegatorInfo(2);
        assertEq(delInfo1.stake, 50 ether, "Validator 1 should have 50 ether cached");
        assertEq(delInfo2.stake, 50 ether, "Validator 2 should have 50 ether cached");
    }

    function test_CacheBecomesStaleAfterInterval() public {
        // Refresh cache
        coreVault.refreshCache();
        uint256 initialTimestamp = coreVault.lastDelegatorInfoUpdateTimestamp();

        // Cache should be fresh
        assertEq(initialTimestamp, block.timestamp, "Cache timestamp should match current time");

        // Fast forward past cache interval
        vm.warp(block.timestamp + DEFAULT_CACHE_INTERVAL + 1);

        // Verify cache is now stale (timestamp + interval < current time)
        uint256 cacheAge = block.timestamp - initialTimestamp;
        uint256 cacheInterval = coreVault.delegatorInfoUpdateInterval();
        assertGt(cacheAge, cacheInterval, "Cache should be stale");

        // RefreshCacheCheck should detect stale cache and refresh
        coreVault.refreshCacheCheck();

        // Cache should be updated
        assertGt(coreVault.lastDelegatorInfoUpdateTimestamp(), initialTimestamp, "Cache should be refreshed");
        assertEq(coreVault.lastDelegatorInfoUpdateTimestamp(), block.timestamp, "Cache should have current timestamp");
    }

    function test_CacheTrackingWorksForDelegations() public {
        // Refresh cache
        coreVault.refreshCache();

        // Initial state
        uint256 initialCachedAssets = coreVault.cachedTotalAssets();
        int256 initialNetPending = coreVault.cachedTotalNetPendingDelegations();

        assertEq(initialCachedAssets, 100 ether, "Should have initial cached assets");
        assertEq(initialNetPending, 0, "Should have no pending delegations initially");

        // Make additional delegation
        uint256 additionalAmount = 20 ether;
        vm.deal(address(magma), additionalAmount);
        vm.prank(address(magma));
        coreVault.delegate{value: additionalAmount}();

        // Check cache tracking
        int256 newNetPending = coreVault.cachedTotalNetPendingDelegations();
        assertEq(newNetPending, int256(additionalAmount), "Should track new delegation");

        // Total assets should reflect both cached and pending
        uint256 totalAssets = coreVault.totalAssets();
        uint256 expectedTotal = initialCachedAssets + additionalAmount;
        assertEq(totalAssets, expectedTotal, "Total assets should include pending delegations");
    }

    function test_UndelegationUsesCorrectCachedData() public {
        // Refresh cache to ensure clean state
        coreVault.refreshCache();

        // Verify initial cached state
        uint256 initialCachedAssets = coreVault.cachedTotalAssets();
        assertEq(initialCachedAssets, 100 ether, "Should have cached 100 ether");

        // Test undelegation - this uses _getDelegatorInfoCached internally
        uint256 undelegateAmount = 10 ether;
        vm.prank(address(magma));
        coreVault.undelegate(undelegateAmount, user);

        // Should succeed without reverting (proves cached data is working)
        // Check that undelegation tracking works
        int256 netPending = coreVault.cachedTotalNetPendingDelegations();
        assertEq(netPending, -int256(undelegateAmount), "Should track undelegation as negative");

        // Total assets should be reduced by undelegation
        uint256 totalAssets = coreVault.totalAssets();
        uint256 expectedTotal = 100 ether - undelegateAmount;
        assertEq(totalAssets, expectedTotal, "Total assets should reflect undelegation");

        // User should have withdrawal requests (may be split across validators)
        uint256 totalWithdrawalAmount = 0;
        uint256 requestCount = 0;

        // Count withdrawal requests until we hit an empty one
        for (uint256 i = 0; i < 10; i++) {
            try coreVault.userWithdrawalRequests(user, i) returns (uint256 amount, uint64 validator, uint8) {
                if (amount == 0) break;
                totalWithdrawalAmount += amount;
                requestCount++;
                assertGt(validator, 0, "Should have valid validator ID");
                // Note: withdrawalId can be 0 in some cases, so we don't assert on it
            } catch {
                break;
            }
        }

        assertEq(totalWithdrawalAmount, undelegateAmount, "Total withdrawal amount should match requested amount");
        assertGt(requestCount, 0, "Should have at least one withdrawal request");
    }

    function test_ConfigurableCacheInterval() public {
        // Check default interval
        assertEq(coreVault.delegatorInfoUpdateInterval(), DEFAULT_CACHE_INTERVAL, "Should have default interval");

        // Only admin can set the interval
        vm.expectRevert();
        vm.prank(user);
        coreVault.setDelegatorInfoUpdateInterval(30 minutes);

        // Admin can set valid intervals
        uint256 newInterval = 30 minutes;
        vm.prank(admin);
        coreVault.setDelegatorInfoUpdateInterval(newInterval);

        assertEq(coreVault.delegatorInfoUpdateInterval(), newInterval, "Should update to new interval");

        // Test interval validation - too long
        vm.expectRevert();
        vm.prank(admin);
        coreVault.setDelegatorInfoUpdateInterval(25 hours); // More than 24 hours

        // Test that new interval affects cache behavior
        coreVault.refreshCache();
        uint256 refreshTime = coreVault.lastDelegatorInfoUpdateTimestamp();

        // Fast forward by less than new interval - cache should still be fresh
        vm.warp(block.timestamp + newInterval - 1);
        uint256 cacheAge = block.timestamp - refreshTime;
        assertLt(cacheAge, newInterval, "Cache should still be fresh");

        // RefreshCacheCheck should not refresh since cache is still fresh
        coreVault.refreshCacheCheck();
        assertEq(coreVault.lastDelegatorInfoUpdateTimestamp(), refreshTime, "Cache timestamp should not change");

        // Fast forward past new interval - cache should be stale
        vm.warp(block.timestamp + 2);
        cacheAge = block.timestamp - refreshTime;
        assertGt(cacheAge, newInterval, "Cache should now be stale");

        // RefreshCacheCheck should now refresh
        coreVault.refreshCacheCheck();
        assertGt(coreVault.lastDelegatorInfoUpdateTimestamp(), refreshTime, "Cache should be refreshed");
    }
}
