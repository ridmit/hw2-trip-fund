// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Local test token only: unrestricted minting, no fees or rebasing.
contract TestToken is ERC20 {
    constructor() ERC20("Trip Token", "TRIP") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
