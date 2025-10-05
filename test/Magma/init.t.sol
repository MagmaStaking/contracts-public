/* solhint-disable */
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {BaseTest} from "../BaseTest.t.sol";
import {WrappedMonad} from "monad/WrappedMonad.sol";
import {Magma} from "src/Magma.sol";
import {ICoreVault} from "interfaces/ICoreVault.sol";
import {IBaseVault} from "interfaces/IBaseVault.sol";
import {MockStakingPrecompile} from "../mock/MockStakingPrecompile.sol";
import {ErrZeroAddress, ErrNotAdmin, ErrVaultsSet} from "src/MagmaErrorsModule.sol";

contract MagmaAsyncModuleInitTest is BaseTest {
    function setUp() public virtual override {
        BaseTest.setUp();
    }

    function test_InitVaults() public {
        vm.expectRevert(ErrNotAdmin.selector);
        magma.initVaults(address(coreVault), address(gvault));

        vm.prank(admin);
        vm.expectRevert(ErrZeroAddress.selector);
        magma.initVaults(address(0), address(gvault));

        vm.expectEmit(true, true, true, true);
        emit Magma.VaultsSet(address(coreVault), address(gvault));
        vm.prank(admin);
        magma.initVaults(address(coreVault), address(gvault));
        assertEq(address(coreVault), magma.coreVault());
        assertEq(address(gvault), magma.gVault());

        vm.prank(admin);
        vm.expectRevert(ErrVaultsSet.selector);
        magma.initVaults(address(2), address(3));
    }
}
