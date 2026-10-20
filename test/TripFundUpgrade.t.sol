// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {TripFund} from "../src/TripFund.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {TripFundFixture} from "./helpers/TripFundFixture.sol";

contract TripFundUpgradeTest is TripFundFixture {
    function test_ValidatedUpgradePreservesStateAndRefundRights() public {
        // Both deployment and upgrade run OpenZeppelin safety/layout validation via FFI.
        address proxy = Upgrades.deployTransparentProxy(
            "TripFund.sol:TripFund",
            adminOwner,
            abi.encodeCall(TripFund.initialize, (address(token), organizer, GOAL, deadline))
        );
        fund = TripFund(proxy);
        vm.prank(alice);
        token.approve(proxy, type(uint256).max);
        vm.prank(bob);
        token.approve(proxy, type(uint256).max);
        _contribute(alice, 40 ether);
        _contribute(bob, 10 ether);
        token.mint(proxy, 9 ether);

        address previousImplementation = Upgrades.getImplementationAddress(proxy);
        address previousAdmin = Upgrades.getAdminAddress(proxy);
        vm.warp(deadline - 1);
        Upgrades.upgradeProxy(proxy, "TripFundV2.sol:TripFundV2", "", adminOwner);
        TripFundV2 upgraded = TripFundV2(proxy);

        assertEq(address(upgraded), proxy);
        assertTrue(Upgrades.getImplementationAddress(proxy) != previousImplementation);
        assertEq(Upgrades.getAdminAddress(proxy), previousAdmin);
        assertEq(address(upgraded.token()), address(token));
        assertEq(upgraded.organizer(), organizer);
        assertEq(upgraded.goal(), GOAL);
        assertEq(upgraded.deadline(), deadline);
        assertEq(upgraded.contributions(alice), 40 ether);
        assertEq(upgraded.contributions(bob), 10 ether);
        assertEq(upgraded.totalRaised(), 50 ether);
        assertEq(token.balanceOf(proxy), 59 ether);
        assertFalse(upgraded.withdrawn());

        _contribute(alice, 5 ether);
        vm.prank(bob);
        upgraded.contributeFor(carol, 20 ether);
        assertEq(upgraded.contributions(bob), 10 ether);
        assertEq(upgraded.contributions(carol), 20 ether);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE - 30 ether);
        assertEq(upgraded.totalRaised(), 75 ether);

        vm.warp(deadline);
        vm.prank(carol);
        upgraded.refund();
        vm.prank(alice);
        upgraded.refund();
        vm.prank(bob);
        upgraded.refund();
        assertEq(token.balanceOf(carol), 20 ether);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE - 20 ether);
        assertEq(upgraded.contributions(alice), 0);
        assertEq(upgraded.contributions(bob), 0);
        assertEq(upgraded.contributions(carol), 0);
        assertEq(upgraded.totalRaised(), 75 ether);
        assertEq(token.balanceOf(proxy), 9 ether);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        upgraded.initialize(address(token), organizer, GOAL, deadline + 1 days);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        TripFund(Upgrades.getImplementationAddress(proxy))
            .initialize(address(token), organizer, GOAL, deadline + 1 days);
    }

    function test_OnlyProxyAdminOwnerCanUpgrade() public {
        ProxyAdmin admin = ProxyAdmin(Upgrades.getAdminAddress(address(fund)));
        TripFundV2 implementation = new TripFundV2();
        assertEq(admin.owner(), adminOwner);
        address[2] memory outsiders = [alice, organizer];
        for (uint256 i; i < outsiders.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsiders[i])
            );
            vm.prank(outsiders[i]);
            admin.upgradeAndCall(
                ITransparentUpgradeableProxy(address(fund)), address(implementation), ""
            );
        }
        vm.prank(adminOwner);
        admin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(fund)), address(implementation), ""
        );
        assertEq(Upgrades.getImplementationAddress(address(fund)), address(implementation));
    }

    function test_UpgradeDoesNotResetWithdrawnFlag() public {
        _contribute(alice, GOAL);
        vm.warp(deadline);
        vm.prank(organizer);
        fund.withdraw();
        TripFundV2 upgraded = _upgrade();
        assertTrue(upgraded.withdrawn());
        assertEq(upgraded.totalRaised(), GOAL);
        vm.expectRevert(TripFund.AlreadyWithdrawn.selector);
        vm.prank(organizer);
        upgraded.withdraw();
        vm.expectRevert(TripFund.GoalReached.selector);
        vm.prank(alice);
        upgraded.refund();
    }

    function test_SponsoredContributionUsesPayerAndEmitsBeneficiary() public {
        TripFundV2 upgraded = _upgrade();
        _contribute(bob, 5 ether);
        vm.expectEmit(true, true, false, true, address(upgraded));
        emit TripFund.Contributed(alice, bob, 12 ether);
        vm.prank(alice);
        upgraded.contributeFor(bob, 12 ether);
        assertEq(upgraded.contributions(alice), 0);
        assertEq(upgraded.contributions(bob), 17 ether);
        assertEq(upgraded.totalRaised(), 17 ether);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - 12 ether);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE - 5 ether);
    }

    function test_SponsoredContributionRejectsZeroBeneficiaryAndAmount() public {
        TripFundV2 upgraded = _upgrade();
        vm.expectRevert(TripFund.InvalidBeneficiary.selector);
        vm.prank(alice);
        upgraded.contributeFor(address(0), 1 ether);
        vm.expectRevert(TripFund.InvalidAmount.selector);
        vm.prank(alice);
        upgraded.contributeFor(bob, 0);
        assertEq(upgraded.totalRaised(), 0);
        assertEq(upgraded.contributions(bob), 0);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
    }

    function test_SponsoredContributionRequiresPayersAllowance() public {
        TripFundV2 upgraded = _upgrade();
        token.mint(carol, 10 ether);
        // Bob has approved the proxy, but Carol is the payer and has not.
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(upgraded), 0, 10 ether
            )
        );
        vm.prank(carol);
        upgraded.contributeFor(bob, 10 ether);
        assertEq(upgraded.totalRaised(), 0);
        assertEq(upgraded.contributions(bob), 0);
        assertEq(token.balanceOf(carol), 10 ether);
        assertEq(token.balanceOf(address(fund)), 0);
    }

    function test_SponsoredContributionRequiresPayersBalance() public {
        TripFundV2 upgraded = _upgrade();
        vm.prank(carol);
        token.approve(address(upgraded), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, carol, 0, 1 ether
            )
        );
        vm.prank(carol);
        upgraded.contributeFor(alice, 1 ether);
        assertEq(upgraded.totalRaised(), 0);
        assertEq(upgraded.contributions(alice), 0);
        assertEq(token.balanceOf(carol), 0);
        assertEq(token.allowance(carol, address(upgraded)), 1 ether);
    }

    function test_SponsoredContributionAtDeadlineReverts() public {
        TripFundV2 upgraded = _upgrade();
        vm.warp(deadline - 1);
        vm.prank(alice);
        upgraded.contributeFor(bob, 1 ether);
        vm.warp(deadline);
        vm.expectRevert(TripFund.ContributionsClosed.selector);
        vm.prank(alice);
        upgraded.contributeFor(bob, 1 ether);
        assertEq(upgraded.totalRaised(), 1 ether);
    }

    function test_SponsorCannotRefundBeneficiarysContribution() public {
        TripFundV2 upgraded = _upgrade();
        vm.prank(alice);
        upgraded.contributeFor(carol, 10 ether);
        vm.warp(deadline);
        vm.expectRevert(TripFund.NoContribution.selector);
        vm.prank(alice);
        upgraded.refund();
        vm.prank(carol);
        upgraded.refund();
        assertEq(token.balanceOf(carol), 10 ether);
        vm.expectRevert(TripFund.NoContribution.selector);
        vm.prank(carol);
        upgraded.refund();
    }

    function _upgrade() internal returns (TripFundV2) {
        TripFundV2 implementation = new TripFundV2();
        ProxyAdmin admin = ProxyAdmin(Upgrades.getAdminAddress(address(fund)));
        vm.prank(adminOwner);
        admin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(fund)), address(implementation), ""
        );
        return TripFundV2(address(fund));
    }
}
