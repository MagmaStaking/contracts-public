// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract MagmaIntegrationTest {
    function test_skip() public {
        // Integration tests require --ffi; skipping in default profile
        assert(true);
    }
}
