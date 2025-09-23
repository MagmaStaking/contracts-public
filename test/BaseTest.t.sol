// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";
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
    address payable internal constant STAKING_PRECOMPILE = payable(address(0x0000000000000000000000000000000000001000));

    function setUp() public virtual {
        admin = address(0xA11CE);
        user = address(0xB0B);
        uint256 delay = 25000 / 250;
        uint256 epoch = 0; // Disable epoch guard for testing

        // Deploy mock staking precompile at the expected address
        stakingPrecompile = new MockStakingPrecompile();
        vm.etch(STAKING_PRECOMPILE, address(stakingPrecompile).code);

        // Fund the precompile with ETH for withdrawals
        vm.deal(STAKING_PRECOMPILE, 1000000 ether);

        // Initialize the mock since vm.etch bypasses constructor
        MockStakingPrecompile(STAKING_PRECOMPILE).initialize();

        // Deploy underlying wrapped asset
        wmon = new WrappedMonad();

        // Deploy Magma (implementation and proxy)
        address magmaImpl = address(new Magma());
        address magmaProxy = UnsafeUpgrades.deployUUPSProxy(
            magmaImpl,
            abi.encodeCall(
                Magma.initialize,
                (IERC20(address(wmon)), "gMON", "gMON", admin, address(0), address(0), 10, 0, admin, delay)
            )
        );
        magma = Magma(payable(magmaProxy));

        // CoreVault
        address coreImpl = address(new CoreVault());
        address coreProxy =
            UnsafeUpgrades.deployUUPSProxy(coreImpl, abi.encodeCall(CoreVault.initialize, (address(magma), epoch)));
        coreVault = CoreVault(payable(coreProxy));

        // gVault
        address gvImpl = address(new gVault());
        address gvProxy =
            UnsafeUpgrades.deployUUPSProxy(gvImpl, abi.encodeCall(gVault.initialize, (address(magma), epoch)));
        gvault = gVault(payable(gvProxy));

        // Wire magma vault refs
        vm.prank(admin);
        magma.setVaults(address(coreVault), address(gvault));

        // Set up some validators for testing
        // First register validators in the mock staking precompile
        _setupValidatorInStakingPrecompile(1);
        _setupValidatorInStakingPrecompile(2);

        // Advance epoch to activate the initial validator stakes
        _advanceEpoch();

        // Then add them to the CoreVault
        vm.startPrank(admin);
        coreVault.addValidator(1);
        coreVault.addValidator(2);
        vm.stopPrank();
    }

    // Helper function to register a validator in the staking precompile
    function _setupValidatorInStakingPrecompile(uint64 valId) internal virtual {
        // Register validator in mock staking precompile with minimal stake
        bytes memory secpPubkey = abi.encodePacked(bytes32(uint256(valId)), bytes1(0x02)); // 33 bytes
        bytes memory blsPubkey = new bytes(48); // 48 bytes

        // Create payload according to Monad specification
        bytes memory payload = abi.encodePacked(
            secpPubkey, // 33 bytes
            blsPubkey, // 48 bytes
            address(this), // 20 bytes (auth_address)
            uint256(100 ether), // 32 bytes (amount)
            uint256(0) // 32 bytes (commission)
        );

        // For testing, we use empty signatures
        bytes memory signedSecpMessage = new bytes(0);
        bytes memory signedBlsMessage = new bytes(0);

        vm.deal(address(this), 1000 ether);
        (bool success,) = STAKING_PRECOMPILE.call{value: 100 ether}(
            abi.encodeWithSelector(
                bytes4(0xf145204c), // SEL_ADD_VALIDATOR (official selector)
                payload,
                signedSecpMessage,
                signedBlsMessage
            )
        );
        require(success, "Failed to add validator to staking precompile");
    }

    // Helper function to set up validator stakes for testing
    function _setupValidatorStake(uint64 valId, uint256 amount) internal virtual {
        MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(valId, address(coreVault), amount);
    }

    // Helper to advance epochs for withdrawal testing
    function _advanceEpoch() internal {
        MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
    }

    // Helper to activate delegated stakes after deposits
    function _activateDelegatedStakes() internal {
        // Advance epoch to activate any pending delegations
        _advanceEpoch();

        // Manually set delegator stakes to match what should be delegated
        // This is needed because the mock precompile uses delayed activation
        uint256 val1Stake = coreVault.delegatedAmount(1);
        uint256 val2Stake = coreVault.delegatedAmount(2);

        if (val1Stake > 0) {
            MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(1, address(coreVault), val1Stake);
        }
        if (val2Stake > 0) {
            MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(2, address(coreVault), val2Stake);
        }
    }

    // Helper to activate all validator stakes to match CoreVault's tracking
    function _activateAllStakes() internal {
        // Get all validators from CoreVault
        uint64[] memory coreValidators = coreVault.getValidators();
        uint64[] memory gvaultValidators = gvault.getvalidators();

        for (uint256 i = 0; i < coreValidators.length; i++) {
            uint64 valId = coreValidators[i];
            uint256 delegatedAmount = coreVault.delegatedAmount(valId);

            if (delegatedAmount > 0) {
                MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(valId, address(coreVault), delegatedAmount);
            }
        }

        for (uint256 i = 0; i < gvaultValidators.length; i++) {
            uint64 valId = gvaultValidators[i];

            // Only activate the exact amount that gVault has staked
            // This should match the total assets that were deposited to gVault
            uint256 gvaultDelegatedAmount = gvault.totalAssets();

            // For simplicity, if gVault has assets and this is validator 3, activate the stake
            if (gvaultDelegatedAmount > 0) {
                MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(
                    valId, address(gvault), gvaultDelegatedAmount
                );
            }
        }
    }

    // Helper to advance multiple epochs and wait for withdrawals to mature
    function _advanceEpochsForWithdrawal() internal {
        // Advance enough epochs for withdrawal to be ready (WITHDRAWAL_DELAY is 7 epochs)
        for (uint256 i = 0; i < 8; i++) {
            MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        }
    }

    // Helper to advance 2 epochs for delegation activation
    function _activatePendingDelegations() internal {
        MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
        MockStakingPrecompile(STAKING_PRECOMPILE).advanceEpoch();
    }
}
