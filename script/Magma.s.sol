// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Magma} from "../src/Magma.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MagmaScript is Script {
    Magma public magma;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        // In production, replace this with the actual underlying asset address
        // For example: IERC20 underlyingAsset = IERC20(0x...); // USDC, WETH, etc.
        address underlyingAssetAddress = address(0); // TODO: Replace with real asset

        require(
            underlyingAssetAddress != address(0),
            "Must specify underlying asset address"
        );

        // Deploy Magma vault - the vault shares are gMON tokens
        magma = new Magma(IERC20(underlyingAssetAddress), "gMON", "gMON");

        console.log("Deployed Magma Vault at:", address(magma));
        console.log("Vault Name:", magma.name());
        console.log("Vault Symbol:", magma.symbol());
        console.log("Underlying Asset:", address(magma.asset()));
        console.log("Default Delay:", magma.DEFAULT_DELAY());

        vm.stopBroadcast();
    }
}
