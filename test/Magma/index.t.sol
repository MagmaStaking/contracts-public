/* solhint-disable */
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {BaseTest} from "../BaseTest.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {WrappedMonad} from "monad/WrappedMonad.sol";
import {Magma} from "src/Magma.sol";
import {ICoreVault} from "interfaces/ICoreVault.sol";
import {IBaseVault} from "interfaces/IBaseVault.sol";
import {MockStakingPrecompile} from "../mock/MockStakingPrecompile.sol";
import {ErrRequestInexistent} from "src/MagmaErrorsModule.sol";

contract MagmaAsyncModuleTest is BaseTest {
    function setUp() public virtual override {
        BaseTest.setUp();

        _setupValidatorInStakingPrecompile(3);
        _advanceEpoch();
        vm.startPrank(admin);
        gvault.addValidator(3);
        gvault.changeValidatorCap(3, 5 ether);
        magma.refreshCache();
        vm.stopPrank();
    }

    function _depositHelper(uint256 assets, address depositor, bool toGVault) internal returns (uint256) {
        uint256 shares = magma.convertToShares(assets);
        vm.deal(depositor, shares);
        vm.startPrank(depositor);
        wmon.deposit{value: shares}();
        wmon.approve(address(magma), shares);
        assertEq(shares, toGVault ? magma.depositGVault(assets, depositor, 3, 0) : magma.deposit(shares, depositor));
        vm.stopPrank();

        return shares;
    }

    function _depositHelper(uint256 assets) internal returns (uint256) {
        /**
         * As a helper deposit 100 more stake so the original amount can easily be withdrawn taking into account the
         * _onetwentiethThreshold
         */
        _depositHelper(assets * 100, address(1000), false);
        uint256 shares = _depositHelper(assets, user, false);

        _activateAllStakes();

        return shares;
    }

    function _depositGVaultHelper(uint256 assets) internal returns (uint256) {
        uint256 shares = _depositHelper(assets, user, true);
        _activateAllStakes();
        _activateGVaultStakes();
        return shares;
    }

    // Helper to activate gVault validator stakes
    function _activateGVaultStakes() internal {
        // Get all validators from gVault
        uint64[] memory validators = gvault.getValidators();

        for (uint256 i = 0; i < validators.length; i++) {
            uint64 valId = validators[i];

            // Only activate for validator 3 (where gVault delegates in this test)
            // Use gVault's totalAssets to get the exact amount that needs activation
            if (valId == 3) {
                uint256 gvaultTotalAssets = gvault.totalAssets();
                if (gvaultTotalAssets > 0) {
                    MockStakingPrecompile(STAKING_PRECOMPILE).setDelegatorStake(
                        valId, address(gvault), gvaultTotalAssets
                    );
                }
            }
        }
    }

    function _requestRedeemHelper(uint256 assets) internal returns (uint256, uint256) {
        uint256 shares = _depositHelper(assets);
        vm.prank(user);
        uint256 requestId = magma.requestRedeem(shares, user, user);

        vm.warp(block.timestamp + DELAY);
        _advanceEpochsForWithdrawal();

        return (requestId, shares);
    }

    function _requestRedeemGVaultHelper(uint256 assets) internal returns (uint256, uint256) {
        uint256 shares = _depositGVaultHelper(assets);
        vm.prank(user);
        uint256 requestId = magma.requestRedeemGVault(shares, user, user, 3);

        vm.warp(block.timestamp + DELAY);
        _advanceEpochsForWithdrawal();

        return (requestId, shares);
    }

    function _setWithdrawalFee(uint256 fee) internal {
        vm.prank(admin);
        magma.setWithdrawalFee(fee);
    }

    function test_ERC165Support() public view {
        bytes4 erc7540InterfaceId = 0x620ee8e4;
        assertTrue(magma.supportsInterface(erc7540InterfaceId));
    }

    function test_Metadata() public view {
        assertEq(magma.asset(), address(wmon));
        assertEq(magma.name(), "gMON");
        assertEq(magma.symbol(), "gMON");
        assertEq(magma.decimals(), 18);
    }

    // No fees on deposits so convertToShares should equal previewMint and convertToAssets should equal previewDeposit
    function test_DepositHelpersRates() public view {
        uint256 assets = 5 ether;
        uint256 shares = magma.convertToShares(assets);
        assertEq(assets, magma.previewMint(shares));
        assertEq(assets, magma.convertToAssets(shares));
        assertEq(shares, magma.previewDeposit(assets));
    }

    function test_Mint() public {
        uint256 assetsBefore = magma.totalAssets();
        uint256 balanceBefore = address(magma).balance;
        uint256 assets = 5 ether;

        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();

        uint256 shares = magma.convertToShares(assets);
        wmon.approve(address(magma), assets);

        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(user, address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), user, shares);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(user, user, assets, shares);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Withdrawal(address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit Magma.DepositWithReferral(user, user, assets, shares, 0);

        // 7540 vault assertions
        assertEq(assets, magma.mint(shares, user));
        assertEq(address(magma).balance, balanceBefore);
        assertEq(magma.totalAssets(), assetsBefore + assets);

        // User assertions
        assertEq(magma.balanceOf(user), shares);
        assertEq(wmon.balanceOf(user), 0);
        assertEq(user.balance, 0);

        vm.stopPrank();
    }

    function test_Deposit() public {
        uint256 assetsBefore = magma.totalAssets();
        uint256 balanceBefore = address(magma).balance;
        uint256 assets = 5 ether;

        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();

        uint256 shares = magma.convertToShares(assets);
        wmon.approve(address(magma), assets);

        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(user, address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), user, shares);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(user, user, assets, shares);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Withdrawal(address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit Magma.DepositWithReferral(user, user, assets, shares, 0);

        // 7540 vault assertions
        assertEq(shares, magma.deposit(assets, user));
        assertEq(address(magma).balance, balanceBefore);
        assertEq(wmon.balanceOf(address(magma)), 0);
        assertEq(magma.totalAssets(), assetsBefore + assets);

        // User assertions
        assertEq(magma.balanceOf(user), shares);
        assertEq(wmon.balanceOf(user), 0);
        assertEq(user.balance, 0);

        vm.stopPrank();
    }

    function test_DepositWMON() public {
        uint256 assetsBefore = magma.totalAssets();
        uint256 balanceBefore = address(magma).balance;
        uint256 assets = 5 ether;

        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();

        uint256 shares = magma.convertToShares(assets);
        wmon.approve(address(magma), assets);

        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(user, address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), user, shares);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(user, user, assets, shares);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Withdrawal(address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit Magma.DepositWithReferral(user, user, assets, shares, 3);

        // 7540 vault assertions
        assertEq(shares, magma.depositWMON(assets, user, 3));
        assertEq(address(magma).balance, balanceBefore);
        assertEq(wmon.balanceOf(address(magma)), 0);
        assertEq(magma.totalAssets(), assetsBefore + assets);

        // User assertions
        assertEq(magma.balanceOf(user), shares);
        assertEq(wmon.balanceOf(user), 0);
        assertEq(user.balance, 0);

        vm.stopPrank();
    }

    function test_DepositMON() public {
        uint256 assetsBefore = magma.totalAssets();
        uint256 balanceBefore = address(magma).balance;
        uint256 assets = 5 ether;

        vm.deal(user, assets);
        vm.startPrank(user);

        uint256 shares = magma.convertToShares(assets);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), user, shares);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(user, user, assets, shares);
        vm.expectEmit(true, true, true, true);
        emit Magma.DepositWithReferral(user, user, assets, shares, 3);

        // 7540 vault assertions
        assertEq(shares, magma.depositMON{value: assets}(user, 3));
        assertEq(address(magma).balance, balanceBefore);
        assertEq(wmon.balanceOf(address(magma)), 0);
        assertEq(magma.totalAssets(), assetsBefore + assets);

        // User assertions
        assertEq(magma.balanceOf(user), shares);
        assertEq(wmon.balanceOf(user), 0);
        assertEq(user.balance, 0);

        vm.stopPrank();
    }

    function test_DepositGVault() public {
        uint256 assetsBefore = magma.totalAssets();
        uint256 balanceBefore = address(magma).balance;
        uint256 assets = 5 ether;

        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();

        // No fees on deposits so convertToShares should equal previewMint
        uint256 shares = magma.convertToShares(assets);
        assertEq(assets, magma.previewMint(shares));

        wmon.approve(address(magma), assets);

        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(user, address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), user, shares);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(user, user, assets, shares);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Withdrawal(address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit Magma.DepositWithReferral(user, user, assets, shares, 3);

        // 7540 vault assertions
        assertEq(shares, magma.depositGVault(assets, user, 3, 3));
        assertEq(address(magma).balance, balanceBefore);
        assertEq(magma.totalAssets(), assetsBefore + assets);
        assertEq(wmon.balanceOf(address(magma)), 0);

        // gVault assertions
        assertEq(assets, gvault.delegatedAmountOf(user, 3));
        assertEq(shares, gvault.delegatedSharesOf(user, 3));
        assertEq(assets, gvault.maxWithdrawableFromGVault(user, 3));

        // User assertions
        assertEq(magma.balanceOf(user), shares);
        assertEq(wmon.balanceOf(user), 0);
        assertEq(user.balance, 0);

        vm.stopPrank();
    }

    function test_DepositToAnotherReceiver() public {
        address receiver = address(15);
        uint256 assetsBefore = magma.totalAssets();
        uint256 balanceBefore = address(magma).balance;
        uint256 assets = 5 ether;

        vm.deal(user, assets);
        vm.startPrank(user);
        wmon.deposit{value: assets}();

        uint256 shares = magma.convertToShares(assets);
        wmon.approve(address(magma), assets);

        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(user, address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), receiver, shares);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Deposit(user, receiver, assets, shares);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Withdrawal(address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit Magma.DepositWithReferral(user, receiver, assets, shares, 0);

        // 7540 vault assertions
        assertEq(shares, magma.deposit(assets, receiver));
        assertEq(address(magma).balance, balanceBefore);
        assertEq(wmon.balanceOf(address(magma)), 0);
        assertEq(magma.totalAssets(), assetsBefore + assets);

        // Receiver assertions
        assertEq(magma.balanceOf(receiver), shares, "Receiver shares should equal to minted shares");
        assertEq(wmon.balanceOf(receiver), 0);
        assertEq(receiver.balance, 0);

        vm.stopPrank();
    }

    function test_MultipleDepositsToBothVaults() public {
        uint256 assetsBefore = magma.totalAssets();
        uint256 balanceBefore = address(magma).balance;
        uint256 assets = 5 ether;

        vm.deal(user, assets * 2);
        vm.startPrank(user);
        wmon.deposit{value: assets * 2}();

        uint256 shares = magma.convertToShares(assets);
        wmon.approve(address(magma), assets * 2);

        // 7540 vault assertions
        assertEq(shares, magma.deposit(assets, user));
        assertEq(shares, magma.depositGVault(assets, user, 3, 3));
        assertEq(address(magma).balance, balanceBefore);
        assertEq(wmon.balanceOf(address(magma)), 0);
        assertEq(magma.totalAssets(), assetsBefore + (assets * 2));

        // User assertions
        assertEq(magma.balanceOf(user), shares * 2);
        assertEq(wmon.balanceOf(user), 0);
        assertEq(user.balance, 0);

        vm.stopPrank();
    }

    function test_PendingRedeemRequest() public {
        uint256 assets = 5 ether;
        address controller = address(123);
        uint256 shares = _depositHelper(assets);

        vm.prank(user);
        uint256 requestId = magma.requestRedeem(shares, controller, user);
        assertEq(shares, magma.pendingRedeemRequest(requestId, controller));
    }

    function test_ClaimableRedeemRequest() public {
        uint256 assets = 5 ether;
        address controller = address(123);
        uint256 shares = _depositHelper(assets);
        vm.warp(2 days);
        vm.prank(user);
        uint256 requestId = magma.requestRedeem(shares, controller, user);
        assertEq(0, magma.claimableRedeemRequest(requestId, controller));
        vm.warp(block.timestamp + (DELAY / 2));
        assertEq(0, magma.claimableRedeemRequest(requestId, controller));
        vm.warp(block.timestamp + (DELAY / 2));
        assertEq(shares, magma.claimableRedeemRequest(requestId, controller));
    }

    function test_RequestRedeem() public {
        uint256 assets = 5 ether;
        uint256 shares = _depositHelper(assets);
        uint256 sharesUserBefore = magma.balanceOf(user);
        uint256 assetsBefore = magma.totalAssets();

        _assertInitialRedeemState();

        uint256 requestId = _performRedeemRequest(shares);

        _assertPostRedeemRequestState(shares, assets, requestId, sharesUserBefore, assetsBefore, false);
    }

    function _performRedeemRequest(uint256 shares) internal returns (uint256) {
        uint256 requestIdCountBefore = 0;

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(user, address(0), shares);
        vm.expectEmit(true, true, true, true);
        emit Magma.RedeemRequest(user, user, requestIdCountBefore, user, shares);

        vm.prank(user);
        uint256 requestId = magma.requestRedeem(shares, user, user);
        assertEq(0, requestId);

        return requestId;
    }

    function _assertPostRedeemRequestState(
        uint256 shares,
        uint256 assets,
        uint256 requestId,
        uint256 sharesUserBefore,
        uint256 assetsBefore,
        bool expectedIsGVault
    ) internal view {
        Magma.RedeemRequests memory redeemData = magma.pendingRedeemRequestData(requestId, user);

        // 7540 vault assertions
        assertEq(user, redeemData.owner);
        assertEq(shares, redeemData.shares);
        assertEq(assets, redeemData.assets);
        assertEq(expectedIsGVault, redeemData.isGVault);
        assertEq(block.timestamp + DELAY, redeemData.claimableTime);
        assertEq(0, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets() + assets);

        // gVault specific assertions (only for gVault tests)
        if (expectedIsGVault) {
            assertEq(0, gvault.delegatedAmountOf(user, 3));
            assertEq(0, gvault.delegatedSharesOf(user, 3));
            assertEq(0, gvault.maxWithdrawableFromGVault(user, 3));
        }

        // user assertions
        assertEq(magma.balanceOf(user), sharesUserBefore - shares);
    }

    function test_RequestRedeemGVault() public {
        uint256 assets = 5 ether;
        uint256 shares = _depositGVaultHelper(assets);
        uint256 sharesUserBefore = magma.balanceOf(user);
        uint256 assetsBefore = magma.totalAssets();

        _assertInitialRedeemState();

        uint256 requestId = _performRedeemGVaultRequest(shares, assets);

        _assertPostRedeemRequestState(shares, assets, requestId, sharesUserBefore, assetsBefore, true);
    }

    function _assertInitialRedeemState() internal view {
        uint256 requestIdCountBefore = 0;
        Magma.RedeemRequests memory redeemData = magma.pendingRedeemRequestData(requestIdCountBefore, user);
        assertEq(address(0), redeemData.owner);
        assertEq(0, redeemData.shares);
        assertEq(0, redeemData.assets);
        assertEq(0, redeemData.claimableTime);
        assertEq(0, magma.balanceOf(address(magma)));
    }

    function _performRedeemGVaultRequest(uint256 shares, uint256 /* assets */ ) internal returns (uint256) {
        uint256 requestIdCountBefore = 0;

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(user, address(0), shares);
        vm.expectEmit(true, true, true, true);
        emit Magma.RedeemRequest(user, user, requestIdCountBefore, user, shares);

        vm.prank(user);
        uint256 requestId = magma.requestRedeemGVault(shares, user, user, 3);
        assertEq(0, requestId);

        return requestId;
    }

    function test_Redeem() public {
        uint256 assets = 5 ether;
        (uint256 requestId, uint256 shares) = _requestRedeemHelper(assets);
        uint256 userWMONBefore = wmon.balanceOf(address(user));
        uint256 assetsBefore = magma.totalAssets();

        // Assertions before redeem
        Magma.RedeemRequests memory redeemData = magma.pendingRedeemRequestData(requestId, user);
        assertEq(user, redeemData.owner);
        assertEq(shares, redeemData.shares);
        assertEq(assets, redeemData.assets);
        assertEq(false, redeemData.isGVault);

        vm.expectEmit(true, true, true, true);
        emit IBaseVault.UserWithdrawalCompleted(user, assets);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Deposit(address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(address(magma), user, assets);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(user, user, address(magma), assets, shares);

        vm.prank(user);
        assertEq(assets, magma.redeem(requestId, user, user));

        // 7540 vault assertions
        Magma.RedeemRequests memory redeemDataAfter = magma.pendingRedeemRequestData(requestId, user);
        assertEq(address(0), redeemDataAfter.owner);
        assertEq(0, redeemDataAfter.shares);
        assertEq(0, redeemDataAfter.assets);
        assertEq(0, redeemDataAfter.claimableTime);

        assertEq(0, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets());
        assertEq(address(magma).balance, 0);
        assertEq(wmon.balanceOf(address(magma)), 0);

        // User assertions
        assertEq(wmon.balanceOf(address(user)), userWMONBefore + assets);
        assertEq(magma.balanceOf(address(user)), 0);
        assertEq(user.balance, 0);
    }

    function test_RedeemGVault() public {
        uint256 assets = 5 ether;
        (uint256 requestId, uint256 shares) = _requestRedeemGVaultHelper(assets);
        uint256 userWMONBefore = wmon.balanceOf(address(user));
        uint256 assetsBefore = magma.totalAssets();

        // Assertions before redeem
        Magma.RedeemRequests memory redeemData = magma.pendingRedeemRequestData(requestId, user);
        assertEq(user, redeemData.owner);
        assertEq(shares, redeemData.shares);
        assertEq(assets, redeemData.assets);
        assertEq(true, redeemData.isGVault);

        vm.expectEmit(true, true, true, true);
        emit IBaseVault.UserWithdrawalCompleted(user, assets);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Deposit(address(magma), assets);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(address(magma), user, assets);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(user, user, address(magma), assets, shares);

        vm.prank(user);
        assertEq(assets, magma.redeem(requestId, user, user));

        // 7540 vault assertions
        Magma.RedeemRequests memory redeemDataAfter = magma.pendingRedeemRequestData(requestId, user);
        assertEq(address(0), redeemDataAfter.owner);
        assertEq(0, redeemDataAfter.shares);
        assertEq(0, redeemDataAfter.assets);
        assertEq(0, redeemDataAfter.claimableTime);

        assertEq(0, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets());
        assertEq(address(magma).balance, 0);
        assertEq(wmon.balanceOf(address(magma)), 0);

        // gVault assertions
        assertEq(0, gvault.delegatedAmountOf(user, 3));
        assertEq(0, gvault.delegatedSharesOf(user, 3));
        assertEq(0, gvault.maxWithdrawableFromGVault(user, 3));

        // User assertions
        assertEq(wmon.balanceOf(address(user)), userWMONBefore + assets);
        assertEq(magma.balanceOf(address(user)), 0);
        assertEq(user.balance, 0);
    }

    function test_RedeemMON() public {
        uint256 assets = 5 ether;
        (uint256 requestId, uint256 shares) = _requestRedeemHelper(assets);
        uint256 userMONBefore = user.balance;
        uint256 assetsBefore = magma.totalAssets();

        // Assertions before redeem
        Magma.RedeemRequests memory redeemData = magma.pendingRedeemRequestData(requestId, user);
        assertEq(user, redeemData.owner);
        assertEq(shares, redeemData.shares);
        assertEq(assets, redeemData.assets);
        assertEq(false, redeemData.isGVault);

        vm.expectEmit(true, true, true, true);
        emit IBaseVault.UserWithdrawalCompleted(user, assets);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(user, user, address(magma), assets, shares);

        vm.prank(user);
        assertEq(assets, magma.redeemMON(requestId, user, user));

        // 7540 vault assertions
        Magma.RedeemRequests memory redeemDataAfter = magma.pendingRedeemRequestData(requestId, user);
        assertEq(address(0), redeemDataAfter.owner);
        assertEq(0, redeemDataAfter.shares);
        assertEq(0, redeemDataAfter.assets);
        assertEq(0, redeemDataAfter.claimableTime);

        assertEq(0, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets());
        assertEq(address(magma).balance, 0);
        assertEq(wmon.balanceOf(address(magma)), 0);

        // User assertions
        assertEq(user.balance, userMONBefore + assets);
        assertEq(magma.balanceOf(address(user)), 0);
        assertEq(wmon.balanceOf(address(user)), 0);
    }

    function test_RedeemWithdrawalSlashed() public {
        uint256 assets = 6 ether;
        uint256 expectedAssets = assets / 2;
        (uint256 requestId, uint256 shares) = _requestRedeemHelper(assets);
        uint256 userWMONBefore = wmon.balanceOf(address(user));
        uint256 assetsBefore = magma.totalAssets();
        uint256 sharesAfterSlash = magma.convertToShares(expectedAssets);

        // Assertions before redeem
        Magma.RedeemRequests memory redeemData = magma.pendingRedeemRequestData(requestId, user);
        assertEq(user, redeemData.owner);
        assertEq(shares, redeemData.shares);
        assertEq(assets, redeemData.assets);

        MockStakingPrecompile(STAKING_PRECOMPILE).setSlashDivider(2);

        vm.expectEmit(true, true, true, true);
        emit IBaseVault.UserWithdrawalCompleted(user, expectedAssets);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), user, shares - sharesAfterSlash);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Deposit(address(magma), expectedAssets);
        vm.expectEmit(true, true, true, true);
        emit WrappedMonad.Transfer(address(magma), user, expectedAssets);
        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(user, user, address(magma), expectedAssets, sharesAfterSlash);

        vm.prank(user);
        assertEq(expectedAssets, magma.redeem(requestId, user, user));

        // 7540 vault assertions
        Magma.RedeemRequests memory redeemDataAfter = magma.pendingRedeemRequestData(requestId, user);
        assertEq(address(0), redeemDataAfter.owner);
        assertEq(0, redeemDataAfter.shares);
        assertEq(0, redeemDataAfter.assets);
        assertEq(0, redeemDataAfter.claimableTime);

        assertEq(0, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets());
        assertEq(address(magma).balance, 0);
        assertEq(wmon.balanceOf(address(magma)), 0);

        // User assertions
        assertEq(wmon.balanceOf(address(user)), userWMONBefore + expectedAssets);
        assertEq(magma.balanceOf(address(user)), shares - sharesAfterSlash);
        assertEq(user.balance, 0);
    }

    function test_MultipleRequestIds() public {
        uint256 requestId1 = 0;
        uint256 requestId2 = 1;
        address user2 = address(15);
        address operator = address(25);
        uint256 assets = 5 ether;
        uint256 userWMONBefore = wmon.balanceOf(user);
        uint256 user2WMONBefore = wmon.balanceOf(user2);
        uint256 shares = _depositHelper(assets);
        uint256 shares2 = _depositHelper(assets, user2, false);
        assertEq(shares, shares2, "When depositing asssets by 2 different users, share amount should be the same");

        vm.prank(user);
        magma.setOperator(operator, true);
        vm.prank(user2);
        magma.setOperator(operator, true);

        // Test operator of users requests redemptions that will be handled by a different controller
        vm.startPrank(operator);
        vm.expectEmit(true, true, true, true);
        emit Magma.RedeemRequest(operator, user, requestId1, operator, shares);
        assertEq(requestId1, magma.requestRedeem(shares, operator, user));
        vm.expectEmit(true, true, true, true);
        emit Magma.RedeemRequest(operator, user2, requestId2, operator, shares);
        assertEq(requestId2, magma.requestRedeem(shares, operator, user2));

        uint256 assetsBefore = magma.totalAssets();

        vm.warp(block.timestamp + DELAY);
        _advanceEpochsForWithdrawal();

        assertEq(
            assets,
            magma.redeem(requestId1, operator, user),
            "Redeem amount should be same as assets depositted by user"
        );
        assertEq(
            assets,
            magma.redeem(requestId2, operator, user2),
            "Redeem amount should be same as assets depositted by user2"
        );
        // 7540 vault assertions
        assertEq(0, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets(), "Magma total Assets should not have changed");
        assertEq(address(magma).balance, 0, "MON balance of Magma should be 0");
        assertEq(wmon.balanceOf(address(magma)), 0, "WMON balance of Magma should be 0");

        // User assertions
        assertEq(
            wmon.balanceOf(user),
            userWMONBefore + assets,
            "WMON balance of user should be equal to pass balance + assets redeemed"
        );
        assertEq(magma.balanceOf(user), 0);
        assertEq(user.balance, 0);

        // User2 assertions
        assertEq(
            wmon.balanceOf(user2),
            user2WMONBefore + assets,
            "WMON balance of user2 should be equal to pass balance + assets redeemed"
        );
        assertEq(magma.balanceOf(user2), 0);
        assertEq(user2.balance, 0);

        vm.stopPrank();
    }

    function test_SetOperator() public {
        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit Magma.OperatorSet(user, address(15), true);
        magma.setOperator(address(15), true);
    }

    function test_ControllerReceiverOperatorFlow() public {
        address userOperator = address(15);
        address controller = address(25);
        address controllerOperator = address(35);
        address receiver = address(35);
        uint256 assets = 5 ether;
        uint256 receiverWMONBefore = wmon.balanceOf(receiver);
        uint256 shares = _depositHelper(assets);

        vm.prank(user);
        magma.setOperator(userOperator, true);
        vm.prank(controller);
        magma.setOperator(controllerOperator, true);

        // Test operator of users requests redemptions that will be handled by a different controller
        vm.prank(userOperator);
        uint256 requestId = magma.requestRedeem(shares, controller, user);
        uint256 assetsBefore = magma.totalAssets();

        vm.warp(block.timestamp + DELAY);
        _advanceEpochsForWithdrawal();

        // Test controller operator will handle redemption to a different receiver
        vm.prank(controllerOperator);
        assertEq(assets, magma.redeem(requestId, controller, receiver));

        // 7540 vault assertions
        assertEq(0, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets(), "Magma total Assets should not have changed");
        assertEq(address(magma).balance, 0, "MON balance of Magma should be 0");
        assertEq(wmon.balanceOf(address(magma)), 0, "WMON balance of Magma should be 0");

        // Receiver assertions
        assertEq(
            wmon.balanceOf(receiver),
            receiverWMONBefore + assets,
            "WMON balance of Magma should be equal to pass balance + assets redeemed"
        );
        assertEq(magma.balanceOf(receiver), 0);
        assertEq(receiver.balance, 0);
    }

    function test_AdminCanRedeemOnBehalfOfUser() public {
        // Test that admin can redeem on behalf of users to prevent stuck WIDs
        // This is important when there are limited withdrawal IDs and users may abandon requests

        address controller = address(25);
        address receiver = address(45);
        uint256 assets = 5 ether;
        uint256 receiverWMONBefore = wmon.balanceOf(receiver);
        uint256 shares = _depositHelper(assets);

        // User requests redemption with specific controller
        vm.prank(user);
        uint256 requestId = magma.requestRedeem(shares, controller, user);
        uint256 assetsBefore = magma.totalAssets();

        // Wait for redemption delay
        vm.warp(block.timestamp + DELAY);
        _advanceEpochsForWithdrawal();

        // Admin can redeem on behalf of any controller to prevent stuck WIDs
        // This is crucial when withdrawal IDs are limited and users may not complete their redemptions
        vm.prank(admin);
        uint256 redeemedAssets = magma.redeem(requestId, controller, receiver);

        // Verify the redemption worked correctly
        assertEq(redeemedAssets, assets, "Redeemed assets should equal requested assets");

        // 7540 vault assertions
        assertEq(magma.balanceOf(address(magma)), 0, "Magma should have no shares");
        assertEq(assetsBefore, magma.totalAssets(), "Magma total assets should not have changed");
        assertEq(address(magma).balance, 0, "MON balance of Magma should be 0");
        assertEq(wmon.balanceOf(address(magma)), 0, "WMON balance of Magma should be 0");

        // Receiver assertions - should receive the WMON tokens
        assertEq(
            wmon.balanceOf(receiver),
            receiverWMONBefore + assets,
            "Receiver should have received the redeemed WMON tokens"
        );
        assertEq(magma.balanceOf(receiver), 0, "Receiver should have no magma shares");
        assertEq(receiver.balance, 0, "Receiver should have no native MON");

        // Verify that the request has been properly cleaned up
        // The request should no longer exist after redemption
        vm.expectRevert(ErrRequestInexistent.selector);
        vm.prank(admin);
        magma.redeem(requestId, controller, receiver);
    }

    function test_DepositGVaultRedeemFromCoreVault() public {
        uint256 assets = 5 ether;
        // Deposit to gVault
        uint256 shares = _depositHelper(assets, user, true);
        // CoreVault stake
        _depositHelper(assets * 100, address(1000), false);
        _activateAllStakes();
        _activateGVaultStakes();

        vm.prank(user);
        uint256 requestId = magma.requestRedeem(shares, user, user);

        vm.warp(block.timestamp + DELAY);
        _advanceEpochsForWithdrawal();
        uint256 userWMONBefore = wmon.balanceOf(address(user));
        uint256 assetsBefore = magma.totalAssets();

        // Assertions before redeem
        Magma.RedeemRequests memory redeemData = magma.pendingRedeemRequestData(requestId, user);
        assertEq(user, redeemData.owner);
        assertEq(shares, redeemData.shares);
        assertEq(assets, redeemData.assets);
        assertEq(false, redeemData.isGVault);

        vm.prank(user);
        assertEq(assets, magma.redeem(requestId, user, user));

        // 7540 vault assertions
        Magma.RedeemRequests memory redeemDataAfter = magma.pendingRedeemRequestData(requestId, user);
        assertEq(address(0), redeemDataAfter.owner);
        assertEq(0, redeemDataAfter.shares);
        assertEq(0, redeemDataAfter.assets);
        assertEq(0, redeemDataAfter.claimableTime);
        assertEq(0, magma.balanceOf(address(magma)));
        assertEq(assetsBefore, magma.totalAssets());
        assertEq(address(magma).balance, 0);
        assertEq(wmon.balanceOf(address(magma)), 0);

        // gVault assertions
        assertEq(assets, gvault.delegatedAmountOf(user, 3), "Delegated amount should be 0");
        assertEq(shares, gvault.delegatedSharesOf(user, 3), "Delegated shares should be 0");
        assertEq(assets, gvault.maxWithdrawableFromGVault(user, 3), "maxWithdrawableFromGVault should be 0");

        // User assertions
        assertEq(wmon.balanceOf(address(user)), userWMONBefore + assets);
        assertEq(magma.balanceOf(address(user)), 0);
        assertEq(user.balance, 0);
    }

    function test_GVaultRedeemFlowWhenRebalance() public {
        uint256 assets = 5 ether;

        // Setup phase
        (uint256 assetsBefore, uint256 shares, uint256 userWMONBefore) = _setupRebalanceTest(assets);

        // First redeem phase - redeem from gVault
        uint256 requestId1 = _performGVaultRedeemInRebalance(assets, shares);

        // Assertions after first redeem
        _assertAfterGVaultRedeem(requestId1, assets, shares, assetsBefore, userWMONBefore);

        // Second redeem phase - redeem remaining from CoreVault
        uint256 requestId2 = _performCoreVaultRedeemInRebalance(assets, shares);

        // Final assertions
        _assertAfterFullRebalanceRedeem(requestId2, assets, shares, assetsBefore, userWMONBefore);
    }

    function _setupRebalanceTest(uint256 assets)
        internal
        returns (uint256 assetsBefore, uint256 shares, uint256 userWMONBefore)
    {
        // CoreVault stake so user can redeem from corevault with his remaining shares after redeeming from gVault
        _depositHelper(assets * 100, address(1000), false);
        assetsBefore = magma.totalAssets();
        shares = _depositGVaultHelper(assets);
        userWMONBefore = wmon.balanceOf(address(user));

        vm.prank(admin);
        gvault.adminInitiateRebalanceBps(5_000);
    }

    function _performGVaultRedeemInRebalance(uint256 assets, uint256 shares) internal returns (uint256 requestId1) {
        uint256 assetsGVault = gvault.maxWithdrawableFromGVault(user, 3);
        uint256 sharesGVault = magma.convertToAssets(assetsGVault);

        assertEq(assets / 2, assetsGVault);
        assertEq(assets, magma.convertToAssets(shares));

        vm.startPrank(user);
        requestId1 = magma.requestRedeemGVault(sharesGVault, user, user, 3);
        vm.warp(block.timestamp + DELAY);
        _advanceEpochsForWithdrawal();
        assertEq(assets / 2, magma.redeem(requestId1, user, user));
    }

    function _assertAfterGVaultRedeem(
        uint256 requestId1,
        uint256 assets,
        uint256 shares,
        uint256 assetsBefore,
        uint256 userWMONBefore
    ) internal view {
        // 7540 vault assertions
        Magma.RedeemRequests memory redeemDataAfter = magma.pendingRedeemRequestData(requestId1, user);
        assertEq(address(0), redeemDataAfter.owner);
        assertEq(0, redeemDataAfter.shares);
        assertEq(0, redeemDataAfter.assets);
        assertEq(0, redeemDataAfter.claimableTime);

        assertEq(0, magma.balanceOf(address(magma)));
        assertEq(
            assetsBefore + assets / 2,
            magma.totalAssets(),
            "Total assets should be equal to assets before + 1/2 of depositted assets"
        );
        assertEq(address(magma).balance, 0);
        assertEq(wmon.balanceOf(address(magma)), 0);

        // Calculate sharesGVault for assertions
        uint256 assetsGVault = assets / 2; // This was asserted earlier
        uint256 sharesGVault = magma.convertToAssets(assetsGVault);

        // gVault assertions
        assertEq(assets / 2, gvault.delegatedAmountOf(user, 3), "Delegated amount in gVault should be 0");
        assertEq(shares - sharesGVault, gvault.delegatedSharesOf(user, 3), "Delegates shares in gVault should be 0");
        assertEq(0, gvault.maxWithdrawableFromGVault(user, 3), "maxWithdrawableFromGVault should be 0");

        // User assertions
        assertEq(wmon.balanceOf(address(user)), userWMONBefore + assets / 2);
        assertEq(
            magma.balanceOf(address(user)),
            shares - sharesGVault,
            "Shares to be redeemed on corevault should be consistent with the balance of the user"
        );
        assertEq(user.balance, 0);
    }

    function _performCoreVaultRedeemInRebalance(uint256 assets, uint256 shares) internal returns (uint256 requestId2) {
        uint256 assetsGVault = assets / 2; // From previous calculations
        uint256 sharesGVault = magma.convertToAssets(assetsGVault);

        requestId2 = magma.requestRedeem(shares - sharesGVault, user, user);
        vm.warp(block.timestamp + DELAY);
        _advanceEpochsForWithdrawal();
        assertEq(
            assets / 2, magma.redeem(requestId2, user, user), "Redeem from coreVault should return half the assets"
        );

        vm.stopPrank();
    }

    function _assertAfterFullRebalanceRedeem(
        uint256 requestId2,
        uint256 assets,
        uint256 shares,
        uint256 assetsBefore,
        uint256 userWMONBefore
    ) internal view {
        // 7540 vault assertions
        Magma.RedeemRequests memory redeemDataAfter = magma.pendingRedeemRequestData(requestId2, user);
        assertEq(address(0), redeemDataAfter.owner);
        assertEq(0, redeemDataAfter.shares);
        assertEq(0, redeemDataAfter.assets);
        assertEq(0, redeemDataAfter.claimableTime);

        assertEq(0, magma.balanceOf(address(magma)));
        assertEq(
            assetsBefore,
            magma.totalAssets(),
            "Assets before depositing should equal assets after depositing and redeeming"
        );
        assertEq(address(magma).balance, 0);
        assertEq(wmon.balanceOf(address(magma)), 0);

        // Calculate sharesGVault for final assertions
        uint256 assetsGVault = assets / 2;
        uint256 sharesGVault = magma.convertToAssets(assetsGVault);

        // gVault assertions
        assertEq(assets / 2, gvault.delegatedAmountOf(user, 3), "Delegated amount should be 0");
        assertEq(shares - sharesGVault, gvault.delegatedSharesOf(user, 3), "Delegated shares should be 0");
        assertEq(0, gvault.maxWithdrawableFromGVault(user, 3), "maxWithdrawableFromGVault should be 0");

        // User assertions
        assertEq(wmon.balanceOf(address(user)), userWMONBefore + assets);
        assertEq(magma.balanceOf(address(user)), 0);
        assertEq(user.balance, 0);
    }

    function test_setRedeemDelay_OnlyAdmin_Success() public {
        uint256 newDelay = 3600; // 1 hour

        vm.prank(admin);
        magma.setRedeemDelay(newDelay);
    }
}
