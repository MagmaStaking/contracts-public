// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Magma} from "../src/Magma.sol";
import {CoreVault} from "../src/CoreVault.sol";
import {gVault} from "../src/gVault.sol";
// MagmaDelegationModule is abstract and inherited by vaults now
import {WrappedMonad} from "../monad/WrappedMonad.sol";
import {MockStakingPrecompile} from "./mock/MockStakingPrecompile.sol";

contract BaseTest is Test {
    address public admin;
    address public user;

    WrappedMonad public wmon;
    Magma public magma;
    CoreVault public coreVault;
    gVault public gvault;
    MockStakingPrecompile public stakingPrecompile;

    // Staking precompile address
    address payable internal constant STAKING_PRECOMPILE = payable(address(0x0000000000000000000000000000000000000100));

    function setUp() public virtual {
        admin = address(0xA11CE);
        user = address(0xB0B);

        // Deploy mock staking precompile at the expected address
        stakingPrecompile = new MockStakingPrecompile();
        vm.etch(STAKING_PRECOMPILE, address(stakingPrecompile).code);

        // Fund the precompile with ETH for withdrawals
        vm.deal(STAKING_PRECOMPILE, 1000000 ether);

        // Deploy underlying wrapped asset
        wmon = new WrappedMonad();

        // Deploy Magma (implementation and proxy)
        address magmaImpl = address(new Magma());
        address magmaProxy = UnsafeUpgrades.deployUUPSProxy(
            magmaImpl,
            abi.encodeCall(Magma.initialize, (IERC20(address(wmon)), "gMON", "gMON", admin, address(0), address(0)))
        );
        magma = Magma(payable(magmaProxy));

        uint256 delay = 25000 / 250;
        uint256 epoch = 25000;

        // CoreVault
        address coreImpl = address(new CoreVault());
        address coreProxy = UnsafeUpgrades.deployUUPSProxy(
            coreImpl, abi.encodeCall(CoreVault.initialize, (address(magma), delay, epoch))
        );
        coreVault = CoreVault(payable(coreProxy));

        // gVault
        address gvImpl = address(new gVault());
        address gvProxy =
            UnsafeUpgrades.deployUUPSProxy(gvImpl, abi.encodeCall(gVault.initialize, (address(magma), delay, epoch)));
        gvault = gVault(payable(gvProxy));

        // Wire magma vault refs
        vm.prank(admin);
        magma.setVaults(address(coreVault), address(gvault));
    }

    // Helper function to set up validator stakes for testing
    function _setupValidatorStake(uint64 valId, uint256 amount) internal {
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(valId, address(coreVault), amount);
    }

    // Helper to advance epochs for withdrawal testing
    function _advanceEpoch() internal {
        MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
    }
}
