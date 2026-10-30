// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Routr
/// @notice A fixed-supply ERC-20 with 18 decimals, minted entirely to its deployer.
/// @dev When deployed through a factory, the factory receives the entire supply.
/// There are no administrative powers or external mint/burn entry points.
contract Routr is ERC20 {
    /// @notice One billion ROUTR, expressed in the token's smallest units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("Routr", "ROUTR") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
