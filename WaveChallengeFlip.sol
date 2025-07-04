// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

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
    function getRandomNumber(uint256 _gameId, uint256 _xpAmount) external virtual;
}

contract WaveChallengeFlip is ReentrancyGuard, VRFConsumerBaseV2Plus, Pausable {
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

    struct User {
        address userAddress;
        uint256 xpAmount;
        uint256 betTime;   
        uint256 rewardAmount;
        uint40 challengeId;
        bool isCreator;
    }

    struct Challenge {
        uint40 challengeId;
        uint40 gameId;
        User creator;
        User challenger;
        bool isActive;
        bool result; // true = creator wins, false = challenger wins
        uint256 createTime;
        uint256 drawTime;
        uint256 xpAmount;
    }

    struct GamePool {
        address baseToken;
        uint40 gameId;
        uint8 burnFee;
        uint8 treasuryFee;
        uint256 totalXpAmount;
        uint256 minTokenAmount;
        Challenge[] challenges;
        bool isActive;
    }

    GamePool[] gamePools;
    Challenge[] challenges;

    mapping(address => User[]) public userHistory;
    mapping(uint256 => Challenge) public pendingChallenges;

    uint40 public lastGameId;
    uint40 public lastChallengeId;
    uint40[] public activeChallengeIds;

    // Events
    event GameCreated(uint256 gameId, address baseToken, uint256 minTokenAmount);
    event ChallengeCreated(uint256 challengeId, address creator, uint256 xpAmount);
    event EnteredChallenge(uint256 gameId, address user, uint256 xpAmount);
    event PoolEnded(uint256 gameId);
    event DrawnChallenge(uint256 result);
    event WinnerDrawn(uint256 challengeId, address winner, uint256 rewardAmount);
    event TreasuryUpdated(address newTreasury);
    event RandomNumberConsumerUpdated(address newReferee);
    event GameDataUpdated(uint256 gameId, uint8 burnFee, uint8 treasuryFee, uint256 limitAmount);
    event ChallengeDrawRequested(uint256 requestId, uint256 challengeId);

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
        gamePool.gameId = lastGameId;
        gamePool.burnFee = _burnFee;
        gamePool.treasuryFee = _treasuryFee;
        gamePool.minTokenAmount = _minTokenAmount;
        gamePool.isActive = true;
        lastGameId++;

        emit GameCreated(gamePool.gameId, _baseToken, _minTokenAmount);
    }

    function createChallenge(uint40 _gameId, uint256 _xpAmount) public nonReentrant whenNotPaused {
        require(_gameId < gamePools.length, "No pool");
        GamePool storage gamePool = gamePools[_gameId];
        require(_xpAmount >= gamePool.minTokenAmount, "Amount is smaller than TicketPrice");
        require(gamePool.isActive, "Pool is not active");

        challenges.push();
        Challenge storage challenge = challenges[challenges.length - 1];
        challenge.challengeId = lastChallengeId;
        challenge.gameId = _gameId;
        challenge.xpAmount = _xpAmount;
        challenge.creator = User({
            userAddress: msg.sender,
            xpAmount: _xpAmount,
            betTime: block.timestamp,
            rewardAmount: 0,
            challengeId: lastChallengeId,
            isCreator: true
        });
        challenge.isActive = true;
        challenge.createTime = block.timestamp;
        lastChallengeId++;

        activeChallengeIds.push(lastChallengeId);

        require(IERC20(gamePool.baseToken).transferFrom(msg.sender, address(this), _xpAmount), "Challenge Creator Token Transfer Failed");

        emit ChallengeCreated(challenge.challengeId, msg.sender, _xpAmount);
    }

    function enterChallenge(uint40 _challengeId, uint256 _xpAmount) public nonReentrant whenNotPaused {
        require(_challengeId < challenges.length, "No challenge");
        Challenge storage challenge = challenges[_challengeId];
        GamePool storage gamePool = gamePools[challenge.gameId];
        require(challenge.isActive, "Challenge is not active");
        require(challenges[_challengeId].creator.userAddress != msg.sender, "You cannot challenge yourself");
        require(_xpAmount >= challenge.xpAmount, "Amount is smaller than XpAmount");

        challenge.challenger = User({
            userAddress: msg.sender,
            xpAmount: _xpAmount,
            betTime: block.timestamp,
            rewardAmount: 0,
            challengeId: _challengeId,
            isCreator: false
        });

        for (uint i=0; activeChallengeIds.length > i; i++) {
            if (activeChallengeIds[i] == _challengeId) {
                delete activeChallengeIds[i];
                break;
            }
        }

        require(IERC20(gamePool.baseToken).transferFrom(msg.sender, address(this), _xpAmount), "Challenger Token Transfer Failed");
        emit EnteredChallenge(_challengeId, msg.sender, _xpAmount);

        uint256 requestId = requestRandomWords(false);
        pendingChallenges[requestId] = challenge;

        emit ChallengeDrawRequested(requestId, _challengeId);
    }


    function _safeDraw(uint40 _gameId, uint40 _challengeId, uint256 _xpAmount) internal {
        uint result = latestRandomWord;

        Challenge storage challenge = challenges[_challengeId];
        GamePool storage gamePool = gamePools[_gameId];
        uint256 _burnAmount = (_xpAmount * gamePool.burnFee) / baseDivider;
        uint256 _treasuryAmount = (_xpAmount * gamePool.treasuryFee) / baseDivider;
        uint256 _winnerAmount = _xpAmount * 2 - _burnAmount - _treasuryAmount;

        require(IERC20(gamePool.baseToken).transfer(burnAddress, _burnAmount), "Burn Transfer Failed");
        require(IERC20(gamePool.baseToken).transfer(treasury, _treasuryAmount), "Treasury Transfer Failed");

        if (result % 2 == 0) { // Creator win!, got reward
            
            challenge.creator.rewardAmount = _winnerAmount;

            require(IERC20(gamePool.baseToken).transfer(challenge.creator.userAddress, _winnerAmount), "Creator Win! Reward Transfer Failed");

            userHistory[challenge.creator.userAddress].push(challenge.creator);
            gamePool.totalXpAmount += _xpAmount;

            emit WinnerDrawn(_challengeId, challenge.creator.userAddress, _winnerAmount);

        } else { // Challenger win!, got reward

            challenge.challenger.rewardAmount = _winnerAmount;

            require(IERC20(gamePool.baseToken).transfer(challenge.challenger.userAddress, _winnerAmount), "Challenger Win! Reward Transfer Failed");

            userHistory[challenge.challenger.userAddress].push(challenge.challenger);
            gamePool.totalXpAmount += _xpAmount;
        }

        challenge.result = true;
        challenge.isActive = false;
        challenge.drawTime = block.timestamp;
        gamePool.challenges.push(challenge);        
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

        Challenge memory challenge = pendingChallenges[_requestId];
        _safeDraw(challenge.gameId, challenge.challengeId, challenge.xpAmount);
        delete pendingChallenges[_requestId];
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
 
    function getGameInfo(uint256 _gameId) public view returns (
        address baseToken,
        uint8 burnFee,
        uint8 treasuryFee,
        uint256 totalXpAmount,  // Total bet amount of pool
        Challenge[] memory challengeList,    // List of challenges in this game
        uint256 minTokenAmount,
        bool isActive
    ) 
    {
        GamePool storage gamePool = gamePools[_gameId];
        return (
            gamePool.baseToken, 
            gamePool.burnFee, 
            gamePool.treasuryFee, 
            gamePool.totalXpAmount, 
            gamePool.challenges, 
            gamePool.minTokenAmount, 
            gamePool.isActive
        );
    }

    function getChallengeInfo(uint256 _challengeId) public view returns (
        uint40 gameId,
        User memory creator,
        User memory challenger,
        bool isActive,
        bool result, // true = creator wins, false = challenger wins
        uint256 createTime,
        uint256 drawTime,
        uint256 xpAmount
    ) {
        Challenge storage challenge = challenges[_challengeId];
        return (
            challenge.gameId,
            challenge.creator,
            challenge.challenger,
            challenge.isActive,
            challenge.result,
            challenge.createTime,
            challenge.drawTime,
            challenge.xpAmount
        );
    }
    
    function getUserHistory(address _user) public view returns (User[] memory history) {
        history = userHistory[_user];
    }

    function getActiveGameIds() public view returns (uint40[] memory) {
        uint40 activeCount = 0;
        for (uint40 i = 0; i < gamePools.length; i++) {
            if (gamePools[i].isActive) {
                activeCount++;
            }
        }

        uint40[] memory activeGameIds = new uint40[](activeCount);
        uint40 index = 0;
        for (uint40 i = 0; i < gamePools.length; i++) {
            if (gamePools[i].isActive) {
                activeGameIds[index] = i;
                index++;
            }
        }
        return activeGameIds;
    }

    function setTreasury(address _treasury) public onlyOwner {
        require(_treasury != address(0xdead)); // not dead contract
        treasury = _treasury;

        emit TreasuryUpdated(_treasury);
    }

    function setGameData(
        uint256 _gameId,
        uint8 _burnFee,
        uint8 _treasuryFee,
        uint256 _minTokenAmount
    ) public onlyOwner {
        require(_gameId < gamePools.length, "No pool");
        require(_burnFee + _treasuryFee <= baseDivider, "Invalid fee configuration");
        GamePool storage prizePool = gamePools[_gameId];
        prizePool.burnFee = _burnFee;
        prizePool.treasuryFee = _treasuryFee;
        prizePool.minTokenAmount = _minTokenAmount;

        emit GameDataUpdated(_gameId, _burnFee, _treasuryFee, _minTokenAmount);
    }
}