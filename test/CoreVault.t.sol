// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseTest} from "./BaseTest.t.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {CoreVault} from "../src/CoreVault.sol";

contract CoreVaultTest is BaseTest {
    function setUp() public override {
        BaseTest.setUp();
        // Redeploy CoreVault with epochSeconds = 0 to bypass epoch guard for this unit test
        address coreImpl = address(new CoreVault());
        address coreProxy = UnsafeUpgrades.deployUUPSProxy(
            coreImpl, abi.encodeCall(CoreVault.initialize, (address(magma), uint256(0), uint256(0)))
        );
        coreVault = CoreVault(payable(coreProxy));
        // Wire magma to new coreVault
        vm.prank(admin);
        magma.setVaults(address(coreVault), address(gvault));
    }

    function testAddAndRemoveValidator() public {
        uint64 v1 = uint64(uint160(address(0x101)));
        vm.prank(admin);
        coreVault.addValidator(v1);
        assertTrue(coreVault.isWhitelisted(v1));

        vm.prank(admin);
        coreVault.removeValidator(v1);
        assertFalse(coreVault.isWhitelisted(v1));
    }
}
