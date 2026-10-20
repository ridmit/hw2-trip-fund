// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TripFund} from "./TripFund.sol";

/// @notice Adds sponsored contributions without changing V1 storage.
/// @dev No new state or parents: the V1 initializer is inherited and must not be rerun.
/// @custom:oz-upgrades-unsafe-allow missing-initializer
/// @custom:oz-upgrades-from TripFund
contract TripFundV2 is TripFund {
    /// @notice The caller pays; the beneficiary receives the contribution and refund rights.
    function contributeFor(address beneficiary, uint256 amount) external nonReentrant {
        _contribute(beneficiary, amount);
    }
}
