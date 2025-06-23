// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// REENTRANCY GUARD
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}


contract WavePrizePool is ReentrancyGuard, VRFConsumerBaseV2Plus {
    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(uint256 requestId, uint256[] randomWords);

    struct RequestStatus {
        bool fulfilled; // whether the request has been successfully fulfilled
        bool exists; // whether a requestId exists
        uint256[] randomWords;
    }
    mapping(uint256 => RequestStatus)
        public s_requests; /* requestId --> requestStatus */

    // Your subscription ID.
    uint256 public s_subscriptionId;

    // Past request IDs.
    uint256[] public requestIds;
    uint256 public lastRequestId;

    // The gas lane to use, which specifies the maximum gas price to bump to.
    // For a list of available gas lanes on each network,
    // see https://docs.chain.link/vrf/v2-5/supported-networks
    bytes32 public keyHash =
        0x8596b430971ac45bdf6088665b9ad8e8630c9d5049ab54b14dff711bee7c0e26;

    // Depends on the number of requested values that you want sent to the
    // fulfillRandomWords() function. Storing each word costs about 20,000 gas,
    // so 100,000 is a safe default for this example contract. Test and adjust
    // this limit based on the network that you select, the size of the request,
    // and the processing of the callback request in the fulfillRandomWords()
    // function.
    uint32 public callbackGasLimit = 100000;

    // The default is 3, but you can set this higher.
    uint16 public requestConfirmations = 3;

    // For this example, retrieve 2 random values in one request.
    // Cannot exceed VRFCoordinatorV2_5.MAX_NUM_WORDS.
    uint32 public numWords = 1;
    uint public lastDrawnNumber;

    address public treasury;
    address public constant burnAddress = address(0xdead);
    uint256 baseDivider = 1000;

    struct User {
        address user;
        uint256 xpAmount;
        uint256 betTime;
        uint256 rewardAmount;
        uint40 poolId;
    }

    struct PrizePool {
        address baseToken;
        uint40 poolId;
        uint8 burnFee;
        uint8 treasuryFee;
        uint256 totalXpAmount;
        User winner;
        User[] users;
        uint256 limitAmount;
        uint256 ticketPrice;
        uint256 limitTime;
        uint256 startTime;
        bool isActive;
    }

    PrizePool[] prizePools;
    uint40 lastPoolId;
    mapping(address => User[]) public userHistory;
    mapping(uint256 => uint256) public requestIdToPoolId;

    // Events
    event PoolCreated(uint256 poolId, address baseToken, uint256 limitAmount, uint256 ticketPrice);
    event EnteredPool(uint256 poolId, address user, uint256 xpAmount);
    event PoolEnded(uint256 poolId);
    event WinnerDrawn(uint256 poolId, address winner, uint256 rewardAmount);
    event TreasuryUpdated(address newTreasury);
    event RandomNumberConsumerUpdated(address newReferee);
    event PoolDataUpdated(uint256 poolId, uint8 burnFee, uint8 treasuryFee, uint256 limitAmount, uint256 ticketPrice);
    event PoolDrawRequested(uint256 requestId, uint256 poolId);

    constructor(address _treasury, uint256 subscriptionId)  
        VRFConsumerBaseV2Plus(0xDA3b641D438362C440Ac5458c57e00a712b66700)
    {
        treasury = _treasury;
        s_subscriptionId = subscriptionId;

    }

    function createPool(
        address _baseToken,
        uint8 _burnFee,
        uint8 _treasuryFee,
        uint256 _limitAmount,
        uint256 _limitTime,
        uint256 _ticketPrice
    ) public onlyOwner {
        require(_burnFee + _treasuryFee <= baseDivider, "Invalid fee configuration");
        prizePools.push();
        PrizePool storage prizePool = prizePools[prizePools.length - 1];
        prizePool.baseToken = _baseToken;
        prizePool.poolId = lastPoolId;
        prizePool.burnFee = _burnFee;
        prizePool.treasuryFee = _treasuryFee;
        prizePool.limitAmount = _limitAmount;
        prizePool.limitTime = _limitTime;
        prizePool.ticketPrice = _ticketPrice;
        prizePool.startTime = block.timestamp;
        prizePool.isActive = true;
        lastPoolId++;

        emit PoolCreated(prizePool.poolId, _baseToken, _limitAmount, _ticketPrice);
    }

    function enterPool(uint40 _poolId, uint256 _xpAmount) public nonReentrant {
        require(_poolId < prizePools.length, "No pool");
        PrizePool storage prizePool = prizePools[_poolId];
        require(_xpAmount >= prizePool.ticketPrice, "Amount is smaller than TicketPrice");
        require(prizePool.isActive, "Pool is not active");

        prizePool.users.push(
            User({
                user: msg.sender,
                xpAmount: _xpAmount,
                betTime: block.timestamp,
                poolId: _poolId,
                rewardAmount: 0
            })
        );

        userHistory[msg.sender].push( 
            User({
                user: msg.sender,
                xpAmount: _xpAmount,
                betTime: block.timestamp,
                poolId: _poolId,
                rewardAmount: 0
            })
        );
        prizePool.totalXpAmount += _xpAmount;

        require(IERC20(prizePool.baseToken).transferFrom(msg.sender, address(this), _xpAmount), "EnterPool Token Transfer Failed");

        emit EnteredPool(_poolId, msg.sender, _xpAmount);

        if ((prizePool.totalXpAmount >= prizePool.limitAmount) || ((block.timestamp >= prizePool.startTime + prizePool.limitTime) && prizePool.limitTime != 0)) {
            uint256 requestId = requestRandomWords(true);
            requestIdToPoolId[requestId] = _poolId;
        }
    }

    function _safeDraw(uint256 _poolId) internal {
        PrizePool storage prizePool = prizePools[_poolId];
        uint result = lastDrawnNumber % prizePool.users.length;
        prizePool.isActive = false;
        prizePool.winner = prizePool.users[result];
        uint256 _burnAmount = (prizePool.totalXpAmount * prizePool.burnFee) / baseDivider;
        uint256 _treasuryAmount = (prizePool.totalXpAmount * prizePool.treasuryFee) / baseDivider;
        uint256 _winnerAmount = prizePool.totalXpAmount - _burnAmount - _treasuryAmount;
        
        prizePool.winner.rewardAmount = _winnerAmount;
        prizePool.users[result].rewardAmount = _winnerAmount;

        require(IERC20(prizePool.baseToken).transfer(prizePool.winner.user, _winnerAmount), "Winner Reward Transfer Failed");
        require(IERC20(prizePool.baseToken).transfer(burnAddress, _burnAmount), "Burn Transfer Failed");
        require(IERC20(prizePool.baseToken).transfer(treasury, _treasuryAmount), "Treasury Transfer Failed");

        emit WinnerDrawn(_poolId, prizePool.winner.user, _winnerAmount);
        emit PoolEnded(_poolId);
    }


    function requestRandomWords( bool enableNativePayment) internal returns (uint256 requestId) {
        // Will revert if subscription is not set and funded.
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({
                        nativePayment: enableNativePayment
                    })
                )
            })
        );
        s_requests[requestId] = RequestStatus({
            randomWords: new uint256[](0),
            exists: true,
            fulfilled: false
        });
        requestIds.push(requestId);
        lastRequestId = requestId;
        emit RequestSent(requestId, numWords);
        return requestId;
    }

    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] calldata _randomWords
    ) internal override {
        require(s_requests[_requestId].exists, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;
        lastDrawnNumber = _randomWords[0]; 
        emit RequestFulfilled(_requestId, _randomWords);

        uint256 _poolId = requestIdToPoolId[_requestId];
        _safeDraw(_poolId);
    }

    function getRequestStatus(
        uint256 _requestId
    ) external view returns (bool fulfilled, uint256[] memory randomWords) {
        require(s_requests[_requestId].exists, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.fulfilled, request.randomWords);
    }

    function getPoolInfo(uint256 _poolId) public view returns (
        address baseToken,
        uint8 burnFee,
        uint8 treasuryFee,
        uint256 totalXpAmount,  // Total bet amount of pool
        User memory winner, 	// Winner
        User[] memory users,    // List of users
        uint256 limitAmount,
        uint256 limitTime,
        uint256 ticketPrice,
        uint256 startTime, 
        bool isActive
    ) 
    {
        PrizePool storage prizePool = prizePools[_poolId];
        return (
            prizePool.baseToken, 
            prizePool.burnFee, 
            prizePool.treasuryFee, 
            prizePool.totalXpAmount, 
            prizePool.winner, 
            prizePool.users, 
            prizePool.limitAmount, 
            prizePool.limitTime,
            prizePool.ticketPrice, 
            prizePool.startTime, 
            prizePool.isActive
        );
    }
    
    function getUserHistory(address _user) public view returns (User[] memory history) {
        history = userHistory[_user];
    }

    function setTreasury(address _treasury) public onlyOwner {
        require(_treasury != address(0xdead)); // not dead contract
        treasury = _treasury;

        emit TreasuryUpdated(_treasury);
    }

    function setPoolData(
        uint256 _poolId,
        uint8 _burnFee,
        uint8 _treasuryFee,
        uint256 _limitAmount,
        uint256 _limitTime,
        uint256 _ticketPrice
    ) public onlyOwner {
        require(_poolId < prizePools.length, "No pool");
        require(_burnFee + _treasuryFee <= baseDivider, "Invalid fee configuration");

        PrizePool storage prizePool = prizePools[_poolId];
        prizePool.burnFee = _burnFee;
        prizePool.treasuryFee = _treasuryFee;
        prizePool.limitAmount = _limitAmount;
        prizePool.ticketPrice = _ticketPrice;
        prizePool.limitTime = _limitTime;

        emit PoolDataUpdated(_poolId, _burnFee, _treasuryFee, _limitAmount, _ticketPrice);
    }

}