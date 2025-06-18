// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import {VRFConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBase.sol";

/**
 * THIS IS AN EXAMPLE CONTRACT THAT USES HARDCODED VALUES FOR CLARITY.
 * THIS IS AN EXAMPLE CONTRACT THAT USES UN-AUDITED CODE.
 * DO NOT USE THIS CODE IN PRODUCTION.
 */

/**
 * Request testnet LINK and ETH here: https://faucets.chain.link/
 * Find information on LINK Token Contracts and get the latest ETH and LINK faucets here: https://docs.chain.link/docs/link-token-contracts/
 */

contract RandomNumberConsumer is VRFConsumerBase {
    event RequestFulfilled(bytes32 requestId, uint256 randomness);

    bytes32 internal keyHash;
    uint256 internal fee;
    uint256 public randomResult;

    /**
     * Constructor inherits VRFConsumerBase
     *
     * Network: BSC Testnet
     * Chainlink VRF Coordinator address: 0xDA3b641D438362C440Ac5458c57e00a712b66700
     * LINK token address: 0x84b9B910527Ad5C03A9Ca831909E21e236EA7b06
     * Key Hash: 0x8596b430971ac45bdf6088665b9ad8e8630c9d5049ab54b14dff711bee7c0e26
     */
    constructor()
        VRFConsumerBase(
            0xDA3b641D438362C440Ac5458c57e00a712b66700, // VRF Coordinator
            0x84b9B910527Ad5C03A9Ca831909E21e236EA7b06 // LINK Token
        )
    {
        keyHash = 0x8596b430971ac45bdf6088665b9ad8e8630c9d5049ab54b14dff711bee7c0e26;
        fee = 0.1 * 10 ** 18; // 0.1 LINK (Varies by network)
    }

    /**
     * Requests randomness
     */
    function getRandomNumber() public returns (bytes32 requestId) {
        require(
            LINK.balanceOf(address(this)) >= fee,
            "Not enough LINK - fill contract with faucet"
        );
        return requestRandomness(keyHash, fee);
    }

    /**
     * Callback function used by VRF Coordinator
     */
    function fulfillRandomness(
        bytes32 requestId,
        uint256 randomness
    ) internal override {
        randomResult = randomness;
        emit RequestFulfilled(requestId, randomness);
    }

    // function withdrawLink() external {} - Implement a withdraw function to avoid locking your LINK in the contract
}
