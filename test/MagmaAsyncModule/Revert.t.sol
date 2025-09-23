// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {MagmaAsyncModuleTest} from "./index.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {WrappedMonad} from "monad/WrappedMonad.sol";
import {MagmaBase} from "src/MagmaBase.sol";
import {Magma} from "src/Magma.sol";
import {ICoreVault} from "interfaces/ICoreVault.sol";
import "src/MagmaErrorsModule.sol";
import {MockStakingPrecompile} from "../mock/MockStakingPrecompile.sol";

contract Revert {
    receive() external payable {
        revert();
    }
}

contract MockMaxDeposit is Magma {
    function maxDeposit(address) public view override returns (uint256) {
        return 3 ether;
    }
}

contract MagmaAsyncModuleRevertTest is MagmaAsyncModuleTest {
    function setUp() public override {
        MagmaAsyncModuleTest.setUp();
    }

    function test_RevertWhen_PreviewWithdraw() public {
        vm.expectRevert();
        magma.previewWithdraw(1);
    }

    function test_RevertWhen_PreviewRedeem() public {
        vm.expectRevert();
        magma.previewRedeem(1);
    }

    function test_RevertWhen_Withdraw() public {
        vm.expectRevert();
        magma.withdraw(1, address(1), address(1));
    }

    function test_RevertWhen_DepositZeroAssets() public {
        uint256 assets = 0;
        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();
        wmon.approve(address(magma), assets);
        vm.expectRevert(ErrZeroAmount.selector);
        magma.deposit(assets, user);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositMONExceedsMaxAssets() public {
        uint256 assets = 5 ether;
        uint256 maxAssets = 3 ether;
        MockMaxDeposit mockMagma = new MockMaxDeposit();
        mockMagma.initialize(
            IERC20(address(wmon)), "gMON", "gMON", admin, address(coreVault), address(gvault), 0, 0, address(0), uint256(1)
        );

        vm.deal(user, assets);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, user, assets, maxAssets)
        );
        vm.prank(user);
        mockMagma.depositMON{value: assets}(user, 0);
    }

    function test_RevertWhen_RequestRedeemPending() public {
        uint256 assets = 6 ether;
        uint256 shares = _depositHelper(assets);

        vm.startPrank(user);
        assertEq(0, magma.requestRedeem(shares / 2, user, user));
        vm.expectRevert(ErrRequestPending.selector);
        magma.requestRedeem(shares / 2, user, user);

        vm.stopPrank();
    }

    function test_RevertWhen_RequestRedeemZeroShares() public {
        vm.prank(user);
        vm.expectRevert(ErrZeroShares.selector);
        magma.requestRedeem(0, user, user);
    }

    // test_RevertWhen_RequestRedeemZeroAddressController will never be necessary since address zero cannot be authorized
    function test_RevertWhen_RequestRedeemZeroAddressController() public {
        uint256 assets = 5 ether;
        uint256 shares = _depositHelper(assets);
        vm.prank(user);
        vm.expectRevert(ErrZeroAddress.selector);
        magma.requestRedeem(shares, address(0), user);
    }

    function test_RevertWhen_RequestRedeemNotAuthorized() public {
        vm.expectRevert(ErrNotAuthorized.selector);
        magma.requestRedeem(5, user, user);
    }

    function test_RevertWhen_RequestRedeemInsufficientShares() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ErrInsufficientShares.selector, 5, 0));
        magma.requestRedeem(5, user, user);
    }

    function test_RevertWhen_RedeemNotAuthorized() public {
        uint256 assets = 5 ether;
        (uint256 requestId,) = _requestRedeemHelper(assets);
        vm.prank(user);
        vm.expectRevert(ErrNotAuthorized.selector);
        magma.redeem(requestId, address(2), user);
    }

    function test_RevertWhen_RedeemNoRequest() public {
        vm.prank(user);
        vm.expectRevert(RequestInexistent.selector);
        magma.redeem(0, user, user);
    }

    function test_RevertWhen_RedeemPending() public {
        uint256 assets = 5 ether;
        uint256 shares = _depositHelper(assets);
        vm.startPrank(user);
        uint256 requestId = magma.requestRedeem(shares, user, user);
        vm.expectRevert(ErrRequestPending.selector);
        magma.redeem(requestId, user, user);
        vm.stopPrank();
    }

    function test_RevertWhen_RedeemWithdrawalFailed() public {
        uint256 assets = 5 ether;
        (uint256 requestId,) = _requestRedeemHelper(assets);
        MockStakingPrecompile(STAKING_PRECOMPILE).setWithdrawRevert(true);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ErrWithdrawalFailed.selector, 1, 0));
        magma.redeem(requestId, user, user);
    }

    function test_RevertWhen_RedeemMONNativeTransferFailed() public {
        Revert _revert = new Revert();
        uint256 assets = 5 ether;
        (uint256 requestId,) = _requestRedeemHelper(assets);
        vm.prank(user);
        vm.expectRevert(ErrNativeTransferFailed.selector);
        magma.redeemMON(requestId, user, address(_revert));
    }

    function test_RevertWhen_DepositCoreVaultRedeemFromGVaultWithStake() public {
        uint256 assets = 5 ether;
        // CoreVault stake
        uint256 shares = _depositHelper(assets, user, false);
        // Deposit to gVault
        _depositHelper(assets, address(1000), true);
        _activateAllStakes();
        _activateGVaultStakes();
        vm.prank(user);
        vm.expectRevert(NotEnoughAssetsGVault.selector);
        magma.requestRedeemGVault(shares, user, user, 3);
    }

    function test_RevertWhen_DepositCoreVaultRedeemFromGVaultNoStake() public {
        uint256 assets = 5 ether;
        uint256 shares = _depositHelper(assets);
        vm.prank(user);
        vm.expectRevert(NotEnoughAssetsGVault.selector);
        magma.requestRedeemGVault(shares, user, user, 3);
    }

    function test_RevertWhen_DepositGVaultRedeemFromCoreVaultNoStake() public {
        uint256 assets = 5 ether;
        uint256 shares = _depositGVaultHelper(assets);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ErrInsufficientDelegated.selector, 5000000000000000000, 0));
        magma.requestRedeem(shares, user, user);
    }

    function test_RevertWhen_RebalanceDepositGVaultRequestAllShares() public {
        uint256 assets = 5 ether;
        uint256 shares = _depositGVaultHelper(assets);

        vm.prank(admin);
        gvault.adminInitiateRebalanceBps(5_000);

        vm.prank(user);
        vm.expectRevert(NotEnoughAssetsGVault.selector);
        assertEq(0, magma.requestRedeemGVault(shares, user, user, 3));
    }

    function test_RevertWhen_setRedeemDelayNotAdmin() public {
        uint256 newDelay = 3600;

        vm.expectRevert(abi.encodeWithSelector(ErrNotAdmin.selector));
        magma.setRedeemDelay(newDelay);
    }
}
