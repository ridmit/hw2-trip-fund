// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @notice ERC20 trip fund, used through an atomically initialized transparent proxy.
contract TripFund is Initializable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    error InvalidToken();
    error InvalidOrganizer();
    error InvalidGoal();
    error InvalidDeadline();
    error InvalidAmount();
    error InvalidBeneficiary();
    error ContributionsClosed();
    error DeadlineNotReached();
    error NotOrganizer();
    error GoalNotReached();
    error GoalReached();
    error AlreadyWithdrawn();
    error NoContribution();

    event Contributed(address indexed payer, address indexed beneficiary, uint256 amount);
    event Refunded(address indexed contributor, uint256 amount);
    event Withdrawn(address indexed organizer, uint256 amount);

    IERC20 public token;
    address public organizer;
    uint256 public goal;
    uint256 public deadline;
    mapping(address => uint256) public contributions;
    /// @notice Historical accepted contributions; payouts never reduce this value.
    uint256 public totalRaised;
    bool public withdrawn;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        external
        initializer
    {
        if (token_ == address(0)) revert InvalidToken();
        if (organizer_ == address(0)) revert InvalidOrganizer();
        if (goal_ == 0) revert InvalidGoal();
        // forge-lint: disable-next-line(block-timestamp)
        if (deadline_ <= block.timestamp) revert InvalidDeadline();

        __ReentrancyGuard_init();
        token = IERC20(token_);
        organizer = organizer_;
        goal = goal_;
        deadline = deadline_;
    }

    function contribute(uint256 amount) external nonReentrant {
        _contribute(msg.sender, amount);
    }

    function withdraw() external nonReentrant {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < deadline) revert DeadlineNotReached();
        if (msg.sender != organizer) revert NotOrganizer();
        if (totalRaised < goal) revert GoalNotReached();
        if (withdrawn) revert AlreadyWithdrawn();

        withdrawn = true;
        // The event precedes the token interaction; every external caller is nonReentrant.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Withdrawn(organizer, totalRaised);
        token.safeTransfer(organizer, totalRaised);
    }

    function refund() external nonReentrant {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < deadline) revert DeadlineNotReached();
        if (totalRaised >= goal) revert GoalReached();
        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NoContribution();

        contributions[msg.sender] = 0;
        // The event precedes the token interaction; every external caller is nonReentrant.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Refunded(msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
    }

    function _contribute(address beneficiary, uint256 amount) internal {
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (amount == 0) revert InvalidAmount();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= deadline) revert ContributionsClosed();

        contributions[beneficiary] += amount;
        totalRaised += amount;
        // The event precedes the token interaction; every external caller is nonReentrant.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Contributed(msg.sender, beneficiary, amount);
        token.safeTransferFrom(msg.sender, address(this), amount);
    }
}
