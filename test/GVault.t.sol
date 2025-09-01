// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseTest} from "./BaseTest.t.sol";

contract GVaultTest is BaseTest {
    function testAddValidatorAndDelegate() public {
        uint64 v1 = uint64(uint160(address(0x201)));
        vm.prank(admin);
        gvault.addValidator(v1);
        assertTrue(gvault.isWhitelisted(v1));
    }
}
