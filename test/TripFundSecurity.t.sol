// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {TripFund} from "../src/TripFund.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {TripFundFixture} from "./helpers/TripFundFixture.sol";
import {TestToken} from "./helpers/TestToken.sol";

interface TokenTransferObserver {
    function onTokenTransfer() external;
}

/// @dev Calls back before moving balances, then can reject the completed transfer.
contract HostileToken is TestToken {
    enum Result {
        Normal,
        ReturnFalse,
        Revert
    }

    error ForcedTokenFailure();

    Result private transferResult;
    Result private transferFromResult;
    address private observer;

    function setResults(Result transfer_, Result transferFrom_) external {
        transferResult = transfer_;
        transferFromResult = transferFrom_;
    }

    function setObserver(address observer_) external {
        observer = observer_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _notify();
        super.transfer(to, amount);
        return _succeeds(transferResult);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _notify();
        super.transferFrom(from, to, amount);
        return _succeeds(transferFromResult);
    }

    function _succeeds(Result result) private pure returns (bool) {
        if (result == Result.Revert) revert ForcedTokenFailure();
        return result != Result.ReturnFalse;
    }

    function _notify() private {
        if (observer != address(0)) TokenTransferObserver(observer).onTokenTransfer();
    }
}

/// @dev Models ERC20 implementations that transfer successfully without returning a bool.
contract NoReturnToken is TestToken {
    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        assembly ("memory-safe") {
            return(0, 0)
        }
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        assembly ("memory-safe") {
            return(0, 0)
        }
    }
}

contract TripFundSecurityTest is TripFundFixture, TokenTransferObserver {
    HostileToken private hostile;
    uint256 private expectedContribution;
    uint256 private expectedRaised;
    bool private expectedWithdrawn;
    uint256 private callbacks;

    function setUp() public override {
        vm.warp(1_800_000_000);
        deadline = block.timestamp + 7 days;
        hostile = new HostileToken();
        _useToken(hostile);
    }

    function test_ContributeReturningFalseRestoresAccountingAndBalances() public {
        _checkContributionFailure(HostileToken.Result.ReturnFalse, _safeTransferError());
    }

    function test_ContributeRevertingRestoresAccountingAndBalances() public {
        _checkContributionFailure(
            HostileToken.Result.Revert,
            abi.encodeWithSelector(HostileToken.ForcedTokenFailure.selector)
        );
    }

    function test_WithdrawReturningFalseRestoresStateAndAllowsRetry() public {
        _checkWithdrawalFailure(HostileToken.Result.ReturnFalse, _safeTransferError());
    }

    function test_WithdrawRevertingRestoresStateAndAllowsRetry() public {
        _checkWithdrawalFailure(
            HostileToken.Result.Revert,
            abi.encodeWithSelector(HostileToken.ForcedTokenFailure.selector)
        );
    }

    function test_RefundReturningFalseRestoresStateAndAllowsRetry() public {
        _checkRefundFailure(HostileToken.Result.ReturnFalse, _safeTransferError());
    }

    function test_RefundRevertingRestoresStateAndAllowsRetry() public {
        _checkRefundFailure(
            HostileToken.Result.Revert,
            abi.encodeWithSelector(HostileToken.ForcedTokenFailure.selector)
        );
    }

    function test_ContributionCallbackSeesUpdatedAccountingAndCannotReenter() public {
        _observe(40 ether, 40 ether, false);

        _contribute(alice, 40 ether);

        assertEq(callbacks, 1);
        _assertUnpaid(40 ether);
    }

    function test_RefundCallbackSeesClearedContributionAndCannotReenter() public {
        _contribute(alice, 40 ether);
        vm.warp(deadline);
        _observe(0, 40 ether, false);

        vm.prank(alice);
        fund.refund();

        assertEq(callbacks, 1);
        assertEq(fund.contributions(alice), 0);
        assertEq(fund.totalRaised(), 40 ether);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
    }

    function test_WithdrawalCallbackSeesMarkedWithdrawalAndCannotReenter() public {
        _contribute(alice, GOAL);
        vm.warp(deadline);
        _observe(GOAL, GOAL, true);

        vm.prank(organizer);
        fund.withdraw();

        assertEq(callbacks, 1);
        assertTrue(fund.withdrawn());
        assertEq(token.balanceOf(organizer), GOAL);
        assertEq(token.balanceOf(address(fund)), 0);
    }

    function test_NoReturnTokenSupportsContributionAndWithdrawal() public {
        _useToken(new NoReturnToken());
        _contribute(alice, GOAL);
        vm.warp(deadline);

        vm.prank(organizer);
        fund.withdraw();

        assertTrue(fund.withdrawn());
        assertEq(fund.totalRaised(), GOAL);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - GOAL);
        assertEq(token.balanceOf(organizer), GOAL);
        assertEq(token.balanceOf(address(fund)), 0);
    }

    function test_NoReturnTokenSupportsRefund() public {
        _useToken(new NoReturnToken());
        _contribute(alice, 40 ether);
        vm.warp(deadline);

        vm.prank(alice);
        fund.refund();

        assertEq(fund.contributions(alice), 0);
        assertEq(fund.totalRaised(), 40 ether);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
    }

    /// @dev Called from the ERC20 while the outer fund operation is still executing.
    function onTokenTransfer() public virtual {
        assertEq(msg.sender, address(hostile));
        assertEq(fund.contributions(alice), expectedContribution);
        assertEq(fund.totalRaised(), expectedRaised);
        assertEq(fund.withdrawn(), expectedWithdrawn);
        ++callbacks;

        _assertReentrancyRejected(abi.encodeCall(TripFund.contribute, (1)));
        _assertReentrancyRejected(abi.encodeCall(TripFund.refund, ()));
        _assertReentrancyRejected(abi.encodeCall(TripFund.withdraw, ()));
    }

    function _checkContributionFailure(HostileToken.Result result, bytes memory reason) private {
        vm.prank(alice);
        token.approve(address(fund), 40 ether);
        hostile.setResults(HostileToken.Result.Normal, result);
        vm.expectRevert(reason);
        vm.prank(alice);
        fund.contribute(40 ether);
        _assertUnpaid(0);
        assertEq(token.allowance(alice, address(fund)), 40 ether);

        hostile.setResults(HostileToken.Result.Normal, HostileToken.Result.Normal);
        _contribute(alice, 40 ether);
        _assertUnpaid(40 ether);
        assertEq(token.allowance(alice, address(fund)), 0);
    }

    function _checkWithdrawalFailure(HostileToken.Result result, bytes memory reason) private {
        _contribute(alice, GOAL);
        vm.warp(deadline);
        hostile.setResults(result, HostileToken.Result.Normal);

        vm.expectRevert(reason);
        vm.prank(organizer);
        fund.withdraw();
        _assertUnpaid(GOAL);

        hostile.setResults(HostileToken.Result.Normal, HostileToken.Result.Normal);
        vm.prank(organizer);
        fund.withdraw();

        assertTrue(fund.withdrawn());
        assertEq(fund.totalRaised(), GOAL);
        assertEq(fund.contributions(alice), GOAL);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - GOAL);
        assertEq(token.balanceOf(organizer), GOAL);
        assertEq(token.balanceOf(address(fund)), 0);
    }

    function _checkRefundFailure(HostileToken.Result result, bytes memory reason) private {
        _contribute(alice, 40 ether);
        vm.warp(deadline);
        hostile.setResults(result, HostileToken.Result.Normal);

        vm.expectRevert(reason);
        vm.prank(alice);
        fund.refund();
        _assertUnpaid(40 ether);

        hostile.setResults(HostileToken.Result.Normal, HostileToken.Result.Normal);
        vm.prank(alice);
        fund.refund();

        assertFalse(fund.withdrawn());
        assertEq(fund.contributions(alice), 0);
        assertEq(fund.totalRaised(), 40 ether);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(organizer), 0);
        assertEq(token.balanceOf(address(fund)), 0);
    }

    function _assertUnpaid(uint256 amount) private view {
        assertFalse(fund.withdrawn());
        assertEq(fund.contributions(alice), amount);
        assertEq(fund.totalRaised(), amount);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - amount);
        assertEq(token.balanceOf(organizer), 0);
        assertEq(token.balanceOf(address(fund)), amount);
    }

    function _assertReentrancyRejected(bytes memory callData) internal {
        (bool success, bytes memory reason) = address(fund).call(callData);
        assertFalse(success, "nested fund operation succeeded");
        assertEq(
            reason,
            abi.encodeWithSelector(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector)
        );
    }

    function _observe(uint256 contribution, uint256 raised, bool withdrawn_) internal {
        expectedContribution = contribution;
        expectedRaised = raised;
        expectedWithdrawn = withdrawn_;
        hostile.setObserver(address(this));
    }

    function _safeTransferError() private view returns (bytes memory) {
        return abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(hostile));
    }

    function _useToken(TestToken token_) private {
        token = token_;
        fund = _deploy(address(token), GOAL);
        token.mint(alice, INITIAL_BALANCE);
        vm.prank(alice);
        token.approve(address(fund), type(uint256).max);
    }
}

contract TripFundV2SecurityTest is TripFundSecurityTest {
    function _implementation() internal override returns (address) {
        return address(new TripFundV2());
    }

    function onTokenTransfer() public override {
        super.onTokenTransfer();
        _assertReentrancyRejected(abi.encodeCall(TripFundV2.contributeFor, (bob, 1)));
    }

    function test_SponsoredContributionCallbackCannotReenter() public {
        _observe(40 ether, 40 ether, false);
        vm.prank(alice);
        TripFundV2(address(fund)).contributeFor(alice, 40 ether);
        assertEq(fund.contributions(alice), 40 ether);
        assertEq(fund.totalRaised(), 40 ether);
        assertEq(token.balanceOf(address(fund)), 40 ether);
    }
}
