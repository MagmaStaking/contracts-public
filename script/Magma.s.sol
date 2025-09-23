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
        require(underlyingAssetAddress != address(0), "missing UNDERLYING_ASSET");

        address feeReceiverAddress = vm.envAddress("FEE_RECEIVER");
        require(feeReceiverAddress != address(0), "missing FEE_RECEIVER");

        // Based on 250 parallel withdraws per 25,000 second epoch
        uint256 delay = 25000 / 250;
        uint256 epoch = 25000;

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
                    address(0),
                    0,
                    0,
                    feeReceiverAddress,
                    delay
                )
            )
        );
        magma = Magma(payable(magmaProxy));

        address coreProxy = Upgrades.deployUUPSProxy(
            "CoreVault.sol", abi.encodeCall(CoreVault.initialize, (address(magma), epoch, uint64(10)))
        );
        address gvProxy =
            Upgrades.deployUUPSProxy("gVault.sol", abi.encodeCall(gVault.initialize, (address(magma), epoch)));

        magma.setVaults(coreProxy, gvProxy);

        console.log("Deployed Magma Vault at:", address(magma));
        console.log("Deployed CoreVault at:", coreProxy);
        console.log("Deployed gVault at:", gvProxy);
        console.log("Vault Name:", magma.name());
        console.log("Vault Symbol:", magma.symbol());
        console.log("Underlying Asset:", address(magma.asset()));

        vm.stopBroadcast();
    }
}

/**
 * TODO:
 * ffi = true
 * @custom:oz-upgrades-from Magma review https://docs.openzeppelin.com/upgrades-plugins/api-foundry-upgrades https://docs.openzeppelin.com/upgrades-plugins/api-core#define-reference-contracts
 * @custom:storage-location erc7201:openzeppelin.storage.ERC4626,
 * MakeFile with ----force or forge clean before running forge script https://github.com/OpenZeppelin/openzeppelin-foundry-upgrades?tab=readme-ov-file
 * fix openzeppelin lib here
 * you can do a test script just to test
 * Important Include the --sender <ADDRESS> flag for the forge script command when performing upgrades, specifying an address that owns the proxy or proxy admin. Otherwise, OwnableUnauthorizedAccount errors will occur.
 * NO STATE VARIABLES above struct
 * read https://eips.ethereum.org/EIPS/eip-7201 before PR
 */

/**
 * Summary of how to implement a namespace-base root layout
 * To implement this pattern, simply follow these steps:
 *
 * Do not use state variables.
 * Would be state variables must be defined as fields in a struct.
 * Choose a unique namespace for the contract.
 * Use a function to calculate the new root of this contract from the namespace. ERC-7201 proposes a function to be used.
 * Create a utility function to return a reference to the struct base. Use assembly to explicitly indicate that the slot where the base of the struct is located is the slot calculated by the function defined in the previous item.
 * Every time you read or update a struct field, use the utility function to point to the base of the struct.
 * In the next section, we will see how to document the utilization of namespaces within a contract.
 */
