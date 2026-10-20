// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TripFund} from "../../src/TripFund.sol";
import {TestToken} from "./TestToken.sol";

abstract contract TripFundFixture is Test {
    uint256 internal constant GOAL = 100 ether;
    uint256 internal constant INITIAL_BALANCE = 1000 ether;
    address internal organizer = makeAddr("organizer");
    address internal adminOwner = makeAddr("adminOwner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    TestToken internal token;
    TripFund internal fund;
    uint256 internal deadline;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        deadline = block.timestamp + 7 days;
        token = new TestToken();
        fund = _deploy(address(token), GOAL);
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        vm.prank(alice);
        token.approve(address(fund), type(uint256).max);
        vm.prank(bob);
        token.approve(address(fund), type(uint256).max);
    }

    function _implementation() internal virtual returns (address) {
        return address(new TripFund());
    }

    function _deploy(address token_, uint256 goal_) internal returns (TripFund) {
        return TripFund(
            address(
                new TransparentUpgradeableProxy(
                    _implementation(),
                    adminOwner,
                    abi.encodeCall(TripFund.initialize, (token_, organizer, goal_, deadline))
                )
            )
        );
    }

    function _contribute(address payer, uint256 amount) internal {
        vm.prank(payer);
        fund.contribute(amount);
    }
}
