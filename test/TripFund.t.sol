// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TripFund} from "../src/TripFund.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {TripFundFixture} from "./helpers/TripFundFixture.sol";

/// @dev The same original requirements apply before and after the V2 extension.
abstract contract TripFundBehaviorTest is TripFundFixture {
    function test_InitialParameters() public view {
        assertEq(address(fund.token()), address(token));
        assertEq(fund.organizer(), organizer);
        assertEq(fund.goal(), GOAL);
        assertEq(fund.deadline(), deadline);
        assertEq(fund.totalRaised(), 0);
        assertEq(fund.contributions(alice), 0);
        assertFalse(fund.withdrawn());
    }

    function test_RejectsZeroToken() public {
        _expectInvalidInitialization(
            address(0), organizer, GOAL, deadline, TripFund.InvalidToken.selector
        );
    }

    function test_RejectsZeroOrganizer() public {
        _expectInvalidInitialization(
            address(token), address(0), GOAL, deadline, TripFund.InvalidOrganizer.selector
        );
    }

    function test_RejectsZeroGoal() public {
        _expectInvalidInitialization(
            address(token), organizer, 0, deadline, TripFund.InvalidGoal.selector
        );
    }

    function test_RejectsNonFutureDeadlines() public {
        _expectInvalidInitialization(
            address(token), organizer, GOAL, block.timestamp, TripFund.InvalidDeadline.selector
        );
        _expectInvalidInitialization(
            address(token), organizer, GOAL, block.timestamp - 1, TripFund.InvalidDeadline.selector
        );
    }

    function test_ImplementationCannotBeInitialized() public {
        TripFund implementation = TripFund(_implementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(token), organizer, GOAL, deadline);
    }

    function test_ProxyCannotBeInitializedAgain() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fund.initialize(address(token), carol, 1, deadline + 1);
        assertEq(fund.organizer(), organizer);
        assertEq(fund.goal(), GOAL);
        assertEq(fund.deadline(), deadline);
    }

    function test_TwoContributorsAndRepeatedContributions() public {
        _contribute(alice, 20 ether);
        _contribute(bob, 30 ether);
        _contribute(alice, 15 ether);

        assertEq(fund.contributions(alice), 35 ether);
        assertEq(fund.contributions(bob), 30 ether);
        assertEq(fund.totalRaised(), 65 ether);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - 35 ether);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE - 30 ether);
        assertEq(token.balanceOf(address(fund)), 65 ether);
    }

    function test_ZeroContributionRollsBack() public {
        _contribute(alice, 20 ether);
        _assertContributionRollback(0, abi.encodeWithSelector(TripFund.InvalidAmount.selector));
    }

    function test_InsufficientAllowanceRollsBack() public {
        _contribute(alice, 20 ether);
        vm.prank(alice);
        token.approve(address(fund), 5 ether);

        _assertContributionRollback(
            6 ether,
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(fund), 5 ether, 6 ether
            )
        );
    }

    function test_InsufficientBalanceRollsBackAllowanceAndAccounting() public {
        _contribute(alice, 20 ether);
        uint256 amount = INITIAL_BALANCE + 1;
        vm.prank(alice);
        token.approve(address(fund), amount);

        _assertContributionRollback(
            amount,
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                alice,
                INITIAL_BALANCE - 20 ether,
                amount
            )
        );
    }

    function test_ContributionOneSecondBeforeDeadline() public {
        vm.warp(deadline - 1);
        _contribute(alice, 1 ether);
        assertEq(fund.contributions(alice), 1 ether);
        assertEq(fund.totalRaised(), 1 ether);
        assertEq(token.balanceOf(address(fund)), 1 ether);
    }

    function test_ContributionsRejectedAtAndAfterDeadline() public {
        vm.warp(deadline);
        _assertContributionRollback(
            1 ether, abi.encodeWithSelector(TripFund.ContributionsClosed.selector)
        );
        vm.warp(deadline + 1);
        _assertContributionRollback(
            1 ether, abi.encodeWithSelector(TripFund.ContributionsClosed.selector)
        );
    }

    function test_NoPayoutBeforeDeadlineEvenWhenGoalReached() public {
        _contribute(alice, GOAL);
        vm.warp(deadline - 1);

        vm.prank(organizer);
        vm.expectRevert(TripFund.DeadlineNotReached.selector);
        fund.withdraw();
        vm.prank(alice);
        vm.expectRevert(TripFund.DeadlineNotReached.selector);
        fund.refund();

        assertFalse(fund.withdrawn());
        assertEq(fund.contributions(alice), GOAL);
        assertEq(token.balanceOf(address(fund)), GOAL);
        assertEq(token.balanceOf(organizer), 0);
    }

    function test_NoPayoutBeforeDeadlineWhenGoalNotReached() public {
        _contribute(alice, 1 ether);
        vm.expectRevert(TripFund.DeadlineNotReached.selector);
        vm.prank(alice);
        fund.refund();
        vm.expectRevert(TripFund.DeadlineNotReached.selector);
        vm.prank(organizer);
        fund.withdraw();
        assertEq(fund.contributions(alice), 1 ether);
        assertEq(token.balanceOf(address(fund)), 1 ether);
    }

    function test_EmptyFundHasNoPayouts() public {
        vm.warp(deadline);
        vm.expectRevert(TripFund.GoalNotReached.selector);
        vm.prank(organizer);
        fund.withdraw();
        vm.expectRevert(TripFund.NoContribution.selector);
        vm.prank(alice);
        fund.refund();
    }

    function test_ExactGoalWithdrawnAtDeadline() public {
        _contribute(alice, 40 ether);
        _contribute(bob, 60 ether);
        vm.warp(deadline);
        vm.prank(organizer);
        fund.withdraw();

        assertTrue(fund.withdrawn());
        assertEq(fund.totalRaised(), GOAL);
        assertEq(token.balanceOf(organizer), GOAL);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - 40 ether);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE - 60 ether);
    }

    function test_AllContributionsAboveGoalAreWithdrawn() public {
        _contribute(alice, GOAL);
        _contribute(bob, 25 ether);
        vm.warp(deadline + 1);
        vm.prank(organizer);
        fund.withdraw();

        assertTrue(fund.withdrawn());
        assertEq(fund.totalRaised(), 125 ether);
        assertEq(token.balanceOf(organizer), 125 ether);
        assertEq(token.balanceOf(address(fund)), 0);
    }

    function test_NonOrganizerCannotWithdraw() public {
        _contribute(alice, GOAL);
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(TripFund.NotOrganizer.selector);
        fund.withdraw();

        assertFalse(fund.withdrawn());
        assertEq(token.balanceOf(address(fund)), GOAL);
        assertEq(token.balanceOf(organizer), 0);
    }

    function test_WithdrawalCannotBeRepeated() public {
        _contribute(alice, GOAL);
        vm.warp(deadline);
        vm.startPrank(organizer);
        fund.withdraw();
        vm.expectRevert(TripFund.AlreadyWithdrawn.selector);
        fund.withdraw();
        vm.stopPrank();

        assertEq(fund.totalRaised(), GOAL);
        assertEq(token.balanceOf(organizer), GOAL);
    }

    function test_FailedFundCannotBeWithdrawn() public {
        _contribute(alice, GOAL - 1);
        vm.warp(deadline);
        vm.prank(organizer);
        vm.expectRevert(TripFund.GoalNotReached.selector);
        fund.withdraw();

        assertFalse(fund.withdrawn());
        assertEq(token.balanceOf(address(fund)), GOAL - 1);
        assertEq(token.balanceOf(organizer), 0);
    }

    function test_SuccessfulFundCannotBeRefundedBeforeOrAfterWithdrawal() public {
        _contribute(alice, GOAL);
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(TripFund.GoalReached.selector);
        fund.refund();

        vm.prank(organizer);
        fund.withdraw();
        vm.prank(alice);
        vm.expectRevert(TripFund.GoalReached.selector);
        fund.refund();

        assertEq(fund.totalRaised(), GOAL);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - GOAL);
        assertEq(token.balanceOf(organizer), GOAL);
    }

    function test_IndependentFullRefundsAtFailedFund() public {
        _contribute(alice, 20 ether);
        _contribute(bob, 30 ether);
        _contribute(alice, 5 ether);
        vm.warp(deadline + 1);
        vm.prank(alice);
        fund.refund();

        assertEq(fund.contributions(alice), 0);
        assertEq(fund.contributions(bob), 30 ether);
        assertEq(fund.totalRaised(), 55 ether);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE - 30 ether);
        assertEq(token.balanceOf(address(fund)), 30 ether);

        vm.prank(bob);
        fund.refund();
        assertEq(fund.contributions(bob), 0);
        assertEq(fund.totalRaised(), 55 ether);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(token.balanceOf(organizer), 0);
    }

    function test_NonContributorCannotRefund() public {
        _contribute(alice, 20 ether);
        vm.warp(deadline);
        vm.prank(carol);
        vm.expectRevert(TripFund.NoContribution.selector);
        fund.refund();

        assertEq(fund.contributions(alice), 20 ether);
        assertEq(token.balanceOf(address(fund)), 20 ether);
    }

    function test_RefundCannotBeRepeated() public {
        _contribute(alice, 20 ether);
        vm.warp(deadline);
        vm.startPrank(alice);
        fund.refund();
        vm.expectRevert(TripFund.NoContribution.selector);
        fund.refund();
        vm.stopPrank();

        assertEq(fund.totalRaised(), 20 ether);
        assertEq(fund.contributions(alice), 0);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
    }

    function test_DirectDonationCannotMeetGoalAndRemainsAfterRefunds() public {
        _contribute(alice, 40 ether);
        _contribute(bob, 20 ether);
        _donate(GOAL);
        assertEq(fund.totalRaised(), 60 ether);
        assertEq(fund.contributions(carol), 0);
        assertEq(token.balanceOf(address(fund)), 160 ether);

        vm.warp(deadline);
        vm.prank(organizer);
        vm.expectRevert(TripFund.GoalNotReached.selector);
        fund.withdraw();
        vm.prank(alice);
        fund.refund();
        vm.prank(bob);
        fund.refund();

        assertEq(fund.totalRaised(), 60 ether);
        assertEq(token.balanceOf(address(fund)), GOAL);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE);
        assertEq(token.balanceOf(organizer), 0);
    }

    function test_DirectDonationRemainsAfterSuccessfulWithdrawal() public {
        _contribute(alice, GOAL);
        _donate(7 ether);
        assertEq(fund.totalRaised(), GOAL);
        assertEq(fund.contributions(carol), 0);

        vm.warp(deadline);
        vm.prank(organizer);
        fund.withdraw();

        assertEq(fund.totalRaised(), GOAL);
        assertEq(token.balanceOf(organizer), GOAL);
        assertEq(token.balanceOf(address(fund)), 7 ether);
    }

    function test_ContributionEmitsPayerBeneficiaryAndAmount() public {
        vm.expectEmit(true, true, false, true, address(fund));
        emit TripFund.Contributed(alice, alice, 13 ether);
        _contribute(alice, 13 ether);
    }

    function test_RefundEmitsContributorAndAmount() public {
        _contribute(alice, 13 ether);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(fund));
        emit TripFund.Refunded(alice, 13 ether);
        vm.prank(alice);
        fund.refund();
    }

    function test_WithdrawalEmitsOrganizerAndWholeAmount() public {
        _contribute(alice, GOAL + 13 ether);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(fund));
        emit TripFund.Withdrawn(organizer, GOAL + 13 ether);
        vm.prank(organizer);
        fund.withdraw();
    }

    function testFuzz_RepeatedContributionsSum(uint96 first, uint96 second, uint96 third) public {
        uint256 a = bound(first, 1, INITIAL_BALANCE / 2);
        uint256 b = bound(second, 1, INITIAL_BALANCE / 2);
        uint256 c = bound(third, 1, INITIAL_BALANCE / 2);
        _contribute(alice, a);
        _contribute(bob, b);
        _contribute(alice, c);

        assertEq(fund.contributions(alice), a + c);
        assertEq(fund.contributions(bob), b);
        assertEq(fund.totalRaised(), a + b + c);
        assertEq(token.balanceOf(address(fund)), a + b + c);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - a - c);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE - b);
    }

    function testFuzz_RefundsRestoreBalancesWithoutReducingTotal(uint96 first, uint96 second)
        public
    {
        uint256 a = bound(first, 1, GOAL / 2 - 1);
        uint256 b = bound(second, 1, GOAL / 2 - 1);
        _contribute(alice, a);
        _contribute(bob, b);
        vm.warp(deadline);
        vm.prank(bob);
        fund.refund();
        vm.prank(alice);
        fund.refund();

        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.contributions(alice), 0);
        assertEq(fund.contributions(bob), 0);
        assertEq(fund.totalRaised(), a + b);
    }

    function _expectInvalidInitialization(
        address token_,
        address organizer_,
        uint256 goal_,
        uint256 deadline_,
        bytes4 expectedError
    ) internal {
        address implementation = _implementation();
        bytes memory data =
            abi.encodeCall(TripFund.initialize, (token_, organizer_, goal_, deadline_));
        vm.expectRevert(expectedError);
        new TransparentUpgradeableProxy(implementation, adminOwner, data);
    }

    function _assertContributionRollback(uint256 amount, bytes memory expectedError) internal {
        uint256 contributionBefore = fund.contributions(alice);
        uint256 raisedBefore = fund.totalRaised();
        uint256 payerBalanceBefore = token.balanceOf(alice);
        uint256 fundBalanceBefore = token.balanceOf(address(fund));
        uint256 allowanceBefore = token.allowance(alice, address(fund));
        vm.prank(alice);
        vm.expectRevert(expectedError);
        fund.contribute(amount);

        assertEq(fund.contributions(alice), contributionBefore);
        assertEq(fund.totalRaised(), raisedBefore);
        assertEq(token.balanceOf(alice), payerBalanceBefore);
        assertEq(token.balanceOf(address(fund)), fundBalanceBefore);
        assertEq(token.allowance(alice, address(fund)), allowanceBefore);
    }

    function _donate(uint256 amount) internal {
        token.mint(carol, amount);
        vm.prank(carol);
        token.transfer(address(fund), amount);
    }
}

contract TripFundV1Test is TripFundBehaviorTest {}

contract TripFundV2Test is TripFundBehaviorTest {
    function _implementation() internal override returns (address) {
        return address(new TripFundV2());
    }
}
