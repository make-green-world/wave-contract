// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Wave is ERC20, Ownable {
    uint256 initialSupply = 100000000;
    constructor() Ownable(msg.sender) ERC20("Wave", "WAVE") {
        _mint(msg.sender, initialSupply * (10 ** decimals()));
    }
}