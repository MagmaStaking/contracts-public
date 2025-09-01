// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Magma} from "../src/Magma.sol";
import {CoreVault} from "../src/CoreVault.sol";
import {gVault} from "../src/gVault.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// MagmaDelegationModule is now abstract and inherited; no separate deployment

contract MagmaScript is Script {
    Magma public magma;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address underlyingAssetAddress = vm.envAddress("UNDERLYING_ASSET");
        require(
            underlyingAssetAddress != address(0),
            "missing UNDERLYING_ASSET"
        );

        // Deploy UUPS proxy and initialize
        address magmaProxy = Upgrades.deployUUPSProxy(
            "Magma.sol",
            abi.encodeCall(
                Magma.initialize,
                (
                    IERC20(underlyingAssetAddress),
                    "gMON",
                    "gMON",
                    msg.sender,
                    address(0),
                    address(0)
                )
            )
        );
        magma = Magma(payable(magmaProxy));

        // Based on 250 parallel withdraws per 25,000 second epoch
        uint256 delay = 25000 / 250;
        uint256 epoch = 25000;

        address coreProxy = Upgrades.deployUUPSProxy(
            "CoreVault.sol",
            abi.encodeCall(CoreVault.initialize, (address(magma), delay, epoch))
        );
        address gvProxy = Upgrades.deployUUPSProxy(
            "gVault.sol",
            abi.encodeCall(gVault.initialize, (address(magma), delay, epoch))
        );

        magma.setVaults(coreProxy, gvProxy);

        console.log("Deployed Magma Vault at:", address(magma));
        console.log("Deployed CoreVault at:", coreProxy);
        console.log("Deployed gVault at:", gvProxy);
        console.log("Vault Name:", magma.name());
        console.log("Vault Symbol:", magma.symbol());
        console.log("Underlying Asset:", address(magma.asset()));
        console.log("Default Delay:", magma.DEFAULT_DELAY());

        vm.stopBroadcast();
    }
}
