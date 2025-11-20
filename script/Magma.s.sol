/* solhint-disable no-console */
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Magma} from "../src/Magma.sol";
import {CoreVault} from "../src/CoreVault.sol";
import {gVault} from "../src/gVault.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev MagmaDelegationModule is now abstract and inherited; no separate deployment
 */
contract DeployMagma is Script {
    Magma public magma;

    function run() public {
        vm.startBroadcast();

        // WMON
        address underlyingAssetAddress = vm.envAddress("UNDERLYING_ASSET");
        require(underlyingAssetAddress != address(0), "missing UNDERLYING_ASSET");

        address feeReceiverAddress = vm.envAddress("FEE_RECEIVER");
        require(feeReceiverAddress != address(0), "missing FEE_RECEIVER");

        address mevRewardsInjectorAddress = vm.envAddress("MEV_REWARDS_INJECTOR");
        require(mevRewardsInjectorAddress != address(0), "missing MEV_REWARDS_INJECTOR");

        // Based on 250 parallel withdraws per 25,000 second epoch
        uint256 delay = 25000 / 250;
        uint256 epoch = 25000;

        // Deploy UUPS proxy and initialize
        address magmaProxy = Upgrades.deployUUPSProxy(
            "Magma.sol",
            abi.encodeCall(
                Magma.initialize,
                Magma.InitializeParams({
                    asset: IERC20(underlyingAssetAddress),
                    name: "gMON",
                    symbol: "gMON",
                    rewardsFee: 0,
                    withdrawalFee: 0,
                    feeReceiver: feeReceiverAddress,
                    redeemDelay: delay,
                    mevRewardsInjector: mevRewardsInjectorAddress
                })
            )
        );
        magma = Magma(payable(magmaProxy));

        address coreProxy = Upgrades.deployUUPSProxy(
            "CoreVault.sol", abi.encodeCall(CoreVault.initialize, (address(magma), epoch, uint64(10)))
        );
        address gvProxy =
            Upgrades.deployUUPSProxy("gVault.sol", abi.encodeCall(gVault.initialize, (address(magma), epoch)));

        magma.initVaults(coreProxy, gvProxy);

        console.log("Deployed Magma Vault at:", address(magma));
        console.log("Deployed CoreVault at:", coreProxy);
        console.log("Deployed gVault at:", gvProxy);

        vm.stopBroadcast();
    }
}