// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./RandomNumberConsumer.sol"; 

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


contract WaveFlip is Ownable, ReentrancyGuard {
    address public treasury;
    address public constant burnAddress = address(0xdead);
    uint256 baseDivider = 1000;
    RandomNumberConsumer public randomNumberConsumer; // Reference to RandomNumberConsumer

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

    constructor(address _treasury) Ownable(msg.sender) {
        treasury = _treasury;
    }

    function createGame(
        address _baseToken,
        uint8 _burnFee,
        uint8 _treasuryFee,
        uint256 _minTokenAmount
    ) public onlyOwner {
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
        GamePool storage gamePool = gamePools[_poolId];
        require(_poolId < gamePools.length, "No pool");
        require(_xpAmount >= gamePool.minTokenAmount, "Amount is smaller than TicketPrice");
        require(gamePool.isActive, "Pool is not active");
        

        IERC20(gamePool.baseToken).transferFrom(msg.sender, address(this), _xpAmount);

        emit EnteredPool(_poolId, msg.sender, _xpAmount);

        drawGame(_poolId, _xpAmount);
    }

    function drawGame(uint256 _poolId, uint256 _xpAmount) internal {
        require(_poolId < gamePools.length, "No pool");
        
         // Request a random number from RandomNumberConsumer
        randomNumberConsumer.getRandomNumber();

        // Use the randomResult from RandomNumberConsumer
        uint256 result = randomNumberConsumer.randomResult();
        require(result > 0, "Random number not generated yet");

        _safeDraw(_poolId, result, _xpAmount);
    }

    function _safeDraw(uint256 _poolId, uint256 result, uint256 _xpAmount) internal {
        GamePool storage gamePool = gamePools[_poolId];
        uint256 _burnAmount = (_xpAmount * gamePool.burnFee) / baseDivider;
        uint256 _treasuryAmount = (_xpAmount * gamePool.treasuryFee) / baseDivider;
        uint256 _winnerAmount = _xpAmount * 2 - _burnAmount - _treasuryAmount;

        IERC20(gamePool.baseToken).transfer(burnAddress, _burnAmount);
        IERC20(gamePool.baseToken).transfer(treasury, _treasuryAmount);

        if (result % 2 == 0) { // User win!, got reward
            IERC20(gamePool.baseToken).transfer(msg.sender, _winnerAmount);
            gamePool.users.push(
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
            gamePool.totalXpAmount += _xpAmount;
        }

        emit DrawnGame(result);
        emit WinnerDrawn(_poolId, msg.sender, _winnerAmount);
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

    function setPoolData(
        uint256 _poolId,
        uint8 _burnFee,
        uint8 _treasuryFee,
        uint256 _minTokenAmount
    ) public onlyOwner {
        require(_poolId < gamePools.length, "No pool");
        GamePool storage prizePool = gamePools[_poolId];
        prizePool.burnFee = _burnFee;
        prizePool.treasuryFee = _treasuryFee;
        prizePool.minTokenAmount = _minTokenAmount;

        emit PoolDataUpdated(_poolId, _burnFee, _treasuryFee, _minTokenAmount);
    }

    function setRandomNumberConsumer(address _randomNumberConsumer) external onlyOwner {
        randomNumberConsumer = RandomNumberConsumer(_randomNumberConsumer);

        emit RandomNumberConsumerUpdated(_randomNumberConsumer);
    }
}