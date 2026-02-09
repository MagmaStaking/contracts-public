/* solhint-disable no-console */
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Magma} from "../deprecated/v1/Magma.sol";
import {MagmaV2} from "src/MagmaV2.sol";
import {IGVault} from "interfaces/IGVault.sol";
import {DeployGVaultUpgradeMagmaAtomic} from "src/DeployGVaultUpgradeMagmaAtomic.sol";

contract DeployGVaultUpgradeMagma is Script {
    uint256 epochSeconds = 22000;
    address payable magmaProxy = payable(0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081);
    Magma magmaV1 = Magma(magmaProxy);
    MagmaV2 magmaV2 = MagmaV2(magmaProxy);

    function run() public {
        vm.startBroadcast();

        DeployGVaultUpgradeMagmaAtomic deployGVaultUpgradeMagmaAtomic = new DeployGVaultUpgradeMagmaAtomic();

        if (deployGVaultUpgradeMagmaAtomic.owner() == msg.sender) {
            magmaV1.transferOwnership(address(deployGVaultUpgradeMagmaAtomic));

            address gVaultProxy =
                deployGVaultUpgradeMagmaAtomic.deployGVaultUpgradeMagmaAtomic(magmaProxy, msg.sender, epochSeconds);

            console.log("gVaultProxy", gVaultProxy);
            console.log("defaultCapBps", IGVault(gVaultProxy).defaultCapBps());
            console.log("magmaV2 owner", magmaV2.owner());
            console.log("deployGVaultUpgradeMagmaAtomic owner", deployGVaultUpgradeMagmaAtomic.owner());
        } else {
            console.log("Deployment was front runned");
        }

        vm.stopBroadcast();
    }
}
