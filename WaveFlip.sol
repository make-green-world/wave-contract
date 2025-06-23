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

abstract contract RandomNumberConsumer {
    function getRandomNumber(uint256 _poolId, uint256 _xpAmount) external virtual;
}

contract WaveFlip is ReentrancyGuard, VRFConsumerBaseV2Plus {
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
    uint public latestRandomWord;

    address public treasury;
    address public constant burnAddress = address(0xdead);
    uint256 baseDivider = 1000;    

    mapping(uint256 => GameData) public pendingGames;
    struct GameData {
        uint256 poolId;
        uint256 xpAmount;
        address player;
    }

    struct User {
        address user;
        uint256 xpAmount;
        uint256 betTime;
        uint256 rewardAmount;
    }

    struct GamePool {
        address baseToken;
        uint40 poolId;
        uint8 burnFee;
        uint8 treasuryFee;
        uint256 totalXpAmount;
        uint256 minTokenAmount;
        User[] users;
        bool isActive;
    }

    GamePool[] gamePools;
    mapping(address => User[]) public userHistory;
    uint40 lastPoolId;

    // Events
    event GameCreated(uint256 poolId, address baseToken, uint256 minTokenAmount);
    event EnteredPool(uint256 poolId, address user, uint256 xpAmount);
    event PoolEnded(uint256 poolId);
    event DrawnGame(uint256 result);
    event WinnerDrawn(uint256 poolId, address winner, uint256 rewardAmount);
    event TreasuryUpdated(address newTreasury);
    event RandomNumberConsumerUpdated(address newReferee);
    event PoolDataUpdated(uint256 poolId, uint8 burnFee, uint8 treasuryFee, uint256 limitAmount);
    event PoolDrawRequested(uint256 requestId, uint256 poolId);

    constructor(address _treasury, uint256 subscriptionId) VRFConsumerBaseV2Plus(0xDA3b641D438362C440Ac5458c57e00a712b66700) {
        treasury = _treasury;
        s_subscriptionId = subscriptionId;
    }

    function createGame(
        address _baseToken,
        uint8 _burnFee,
        uint8 _treasuryFee,
        uint256 _minTokenAmount
    ) public onlyOwner {
        require(_burnFee + _treasuryFee <= baseDivider, "Invalid fee configuration");
        gamePools.push();
        GamePool storage gamePool = gamePools[gamePools.length - 1];
        gamePool.baseToken = _baseToken;
        gamePool.poolId = lastPoolId;
        gamePool.burnFee = _burnFee;
        gamePool.treasuryFee = _treasuryFee;
        gamePool.minTokenAmount = _minTokenAmount;
        gamePool.isActive = true;
        lastPoolId++;

        emit GameCreated(gamePool.poolId, _baseToken, _minTokenAmount);
    }

    function enterGame(uint40 _poolId, uint256 _xpAmount) public nonReentrant {
        require(_poolId < gamePools.length, "No pool");
        GamePool storage gamePool = gamePools[_poolId];
        require(_xpAmount >= gamePool.minTokenAmount, "Amount is smaller than TicketPrice");
        require(gamePool.isActive, "Pool is not active");
        

        require(IERC20(gamePool.baseToken).transferFrom(msg.sender, address(this), _xpAmount), "Enter Game Token Transfer Failed");

        emit EnteredPool(_poolId, msg.sender, _xpAmount);

        uint256 requestId = requestRandomWords(false);
        pendingGames[requestId] = GameData(_poolId, _xpAmount, msg.sender);

        emit PoolDrawRequested(requestId, _poolId);
    }


    function _safeDraw(uint256 _poolId, uint256 _xpAmount) internal {
        requestRandomWords(false);
        uint result = latestRandomWord;

        GamePool storage gamePool = gamePools[_poolId];
        uint256 _burnAmount = (_xpAmount * gamePool.burnFee) / baseDivider;
        uint256 _treasuryAmount = (_xpAmount * gamePool.treasuryFee) / baseDivider;
        uint256 _winnerAmount = _xpAmount * 2 - _burnAmount - _treasuryAmount;

        require(IERC20(gamePool.baseToken).transfer(burnAddress, _burnAmount), "Burn Transfer Failed");
        require(IERC20(gamePool.baseToken).transfer(treasury, _treasuryAmount), "Treasury Transfer Failed");

        if (result % 2 == 0) { // User win!, got reward
            require(IERC20(gamePool.baseToken).transfer(msg.sender, _winnerAmount), "Winner Reward Transfer Failed");
            gamePool.users.push(
                User({
                    user: msg.sender,
                    xpAmount: _xpAmount,
                    betTime: block.timestamp,
                    rewardAmount: _winnerAmount
                })
            );
            userHistory[msg.sender].push(
                User({
                    user: msg.sender,
                    xpAmount: _xpAmount,
                    betTime: block.timestamp,
                    rewardAmount: _winnerAmount
                })
            );
            gamePool.totalXpAmount += _xpAmount;
        } else {
            gamePool.users.push(
                User({
                    user: msg.sender,
                    xpAmount: _xpAmount,
                    betTime: block.timestamp,
                    rewardAmount: 0
                })
            );
            userHistory[msg.sender].push(
                User({
                    user: msg.sender,
                    xpAmount: _xpAmount,
                    betTime: block.timestamp,
                    rewardAmount: 0
                })
            );
            gamePool.totalXpAmount += _xpAmount;
        }

        emit DrawnGame(result);
        emit WinnerDrawn(_poolId, msg.sender, _winnerAmount);
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
        latestRandomWord = _randomWords[0]; 
        emit RequestFulfilled(_requestId, _randomWords);

        GameData memory game = pendingGames[_requestId];
        _safeDraw(game.poolId, game.xpAmount);
        delete pendingGames[_requestId];
    }

    function getRequestStatus(
        uint256 _requestId
    ) external view returns (bool fulfilled, uint256[] memory randomWords) {
        require(s_requests[_requestId].exists, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.fulfilled, request.randomWords);
    }
    function withdraw(address _token, uint256 amount) public onlyOwner {
        require(IERC20(_token).balanceOf(address(this)) > amount, "Balance is not enough");
        IERC20(_token).transfer(msg.sender, amount);

    }
 
    function getGameInfo(uint256 _poolId) public view returns (
        address baseToken,
        uint8 burnFee,
        uint8 treasuryFee,
        uint256 totalXpAmount,  // Total bet amount of pool
        User[] memory users,    // List of users
        uint256 minTokenAmount,
        bool isActive
    ) 
    {
        GamePool storage gamePool = gamePools[_poolId];
        return (
            gamePool.baseToken, 
            gamePool.burnFee, 
            gamePool.treasuryFee, 
            gamePool.totalXpAmount, 
            gamePool.users, 
            gamePool.minTokenAmount, 
            gamePool.isActive
        );
    }
    
    function getUserHistory(address _user) public view returns (
        uint256[] memory xpAmount,
        uint256[] memory betTime,
        uint256[] memory rewardAmount
    ) {
        uint256 ticketCount = 0;
        for (uint40 i = 0; i < gamePools.length; i++) {
            for (uint40 j = 0; j < gamePools[i].users.length; j++) {
                if (gamePools[i].users[j].user == _user) {
                    ticketCount++;
                }
            }
        }

        xpAmount = new uint256[](ticketCount);
        betTime = new uint256[](ticketCount);
        rewardAmount = new uint256[](ticketCount);

        uint40 index = 0;
        for (uint40 i = 0; i < gamePools.length; i++) {
            for (uint40 j = 0; j < gamePools[i].users.length; j++) {
                if (gamePools[i].users[j].user == _user) {
                    xpAmount[index] = gamePools[i].users[j].xpAmount;
                    betTime[index] = gamePools[i].users[j].betTime;
                    rewardAmount[index] = gamePools[i].users[j].rewardAmount;
                    index++;
                }
            }
        }
    }

    function getActivePoolIds() public view returns (uint256[] memory) {
        uint256 activeCount = 0;
        for (uint40 i = 0; i < gamePools.length; i++) {
            if (gamePools[i].isActive) {
                activeCount++;
            }
        }

        uint256[] memory activePoolIds = new uint256[](activeCount);
        uint40 index = 0;
        for (uint40 i = 0; i < gamePools.length; i++) {
            if (gamePools[i].isActive) {
                activePoolIds[index] = i;
                index++;
            }
        }
        return activePoolIds;
    }

    function setTreasury(address _treasury) public onlyOwner {
        require(_treasury != address(0xdead)); // not dead contract
        treasury = _treasury;

        emit TreasuryUpdated(_treasury);
    }

    function setGameData(
        uint256 _poolId,
        uint8 _burnFee,
        uint8 _treasuryFee,
        uint256 _minTokenAmount
    ) public onlyOwner {
        require(_poolId < gamePools.length, "No pool");
        require(_burnFee + _treasuryFee <= baseDivider, "Invalid fee configuration");
        GamePool storage prizePool = gamePools[_poolId];
        prizePool.burnFee = _burnFee;
        prizePool.treasuryFee = _treasuryFee;
        prizePool.minTokenAmount = _minTokenAmount;

        emit PoolDataUpdated(_poolId, _burnFee, _treasuryFee, _minTokenAmount);
    }

}