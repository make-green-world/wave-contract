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


contract WavePrizePool is Ownable, ReentrancyGuard {
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
    uint40 public lastPoolId;

    // Events
    event PoolCreated(uint256 poolId, address baseToken, uint256 limitAmount, uint256 ticketPrice);
    event EnteredPool(uint256 poolId, address user, uint256 xpAmount);
    event PoolEnded(uint256 poolId);
    event WinnerDrawn(uint256 poolId, address winner, uint256 rewardAmount);
    event TreasuryUpdated(address newTreasury);
    event RandomNumberConsumerUpdated(address newReferee);
    event PoolDataUpdated(uint256 poolId, uint8 burnFee, uint8 treasuryFee, uint256 limitAmount, uint256 ticketPrice);

    constructor(address _treasury) Ownable(msg.sender) {
        treasury = _treasury;
    }

    function createPool(
        address _baseToken,
        uint8 _burnFee,
        uint8 _treasuryFee,
        uint256 _limitAmount,
        uint256 _limitTime,
        uint256 _ticketPrice
    ) public onlyOwner {
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

    function enterPool(uint40 _poolId, uint256 _xpAmount) public {
        PrizePool storage prizePool = prizePools[_poolId];
        require(_poolId < prizePools.length, "No pool");
        require(_xpAmount >= prizePool.ticketPrice, "Amount is smaller than TicketPrice");
        require(prizePool.isActive, "Pool is not active");

        prizePool.users.push(
            User({
                user: msg.sender,
                xpAmount: _xpAmount,
                betTime: block.timestamp,
                rewardAmount: 0
            })
        );
        prizePool.totalXpAmount += _xpAmount;

        IERC20(prizePool.baseToken).transferFrom(msg.sender, address(this), _xpAmount);

        emit EnteredPool(_poolId, msg.sender, _xpAmount);

        if ((prizePool.totalXpAmount >= prizePool.limitAmount) || ((block.timestamp >= prizePool.startTime + prizePool.limitTime) && prizePool.limitTime != 0)) {
            drawWinner(_poolId);
        }
    }

    function drawWinner(uint256 _poolId) public {
        PrizePool storage prizePool = prizePools[_poolId];
        require(_poolId < prizePools.length, "No pool");
        require((prizePool.totalXpAmount >= prizePool.limitAmount) || ((block.timestamp >= prizePool.startTime + prizePool.limitTime) && prizePool.limitTime != 0), "Drawing is not allowed");
        
         // Request a random number from RandomNumberConsumer
        randomNumberConsumer.getRandomNumber();

        // Use the randomResult from RandomNumberConsumer
        uint256 result = randomNumberConsumer.randomResult();
        require(result > 0, "Random number not generated yet");

        _safeDraw(_poolId, result % prizePool.users.length + 1);
    }

    function _safeDraw(uint256 _poolId, uint256 result) internal {
        PrizePool storage prizePool = prizePools[_poolId];
        prizePool.isActive = false;
        prizePool.winner = prizePool.users[result - 1];
        uint256 _burnAmount = (prizePool.totalXpAmount * prizePool.burnFee) / baseDivider;
        uint256 _treasuryAmount = (prizePool.totalXpAmount * prizePool.treasuryFee) / baseDivider;
        uint256 _winnerAmount = prizePool.totalXpAmount - _burnAmount - _treasuryAmount;
        prizePool.winner.rewardAmount = _winnerAmount;

        IERC20(prizePool.baseToken).transfer(prizePool.winner.user, _winnerAmount);
        IERC20(prizePool.baseToken).transfer(burnAddress, _burnAmount);
        IERC20(prizePool.baseToken).transfer(treasury, _treasuryAmount);

        emit WinnerDrawn(_poolId, prizePool.winner.user, _winnerAmount);
        emit PoolEnded(_poolId);
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
    
    function getUserHistory(address _user) public view returns (
        uint256[] memory xpAmount,
        uint256[] memory betTime,
        uint256[] memory rewardAmount
    ) {
        uint256 ticketCount = 0;
        for (uint40 i = 0; i < prizePools.length; i++) {
            for (uint40 j = 0; j < prizePools[i].users.length; j++) {
                if (prizePools[i].users[j].user == _user) {
                    ticketCount++;
                }
            }
        }

        xpAmount = new uint256[](ticketCount);
        betTime = new uint256[](ticketCount);
        rewardAmount = new uint256[](ticketCount);

        uint40 index = 0;
        for (uint40 i = 0; i < prizePools.length; i++) {
            for (uint40 j = 0; j < prizePools[i].users.length; j++) {
                if (prizePools[i].users[j].user == _user) {
                    xpAmount[index] = prizePools[i].users[j].xpAmount;
                    betTime[index] = prizePools[i].users[j].betTime;
                    rewardAmount[index] = prizePools[i].users[j].rewardAmount;
                    index++;
                }
            }
        }
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
        PrizePool storage prizePool = prizePools[_poolId];
        prizePool.burnFee = _burnFee;
        prizePool.treasuryFee = _treasuryFee;
        prizePool.limitAmount = _limitAmount;
        prizePool.ticketPrice = _ticketPrice;
        prizePool.limitTime = _limitTime;

        emit PoolDataUpdated(_poolId, _burnFee, _treasuryFee, _limitAmount, _ticketPrice);
    }

    function setRandomNumberConsumer(address _randomNumberConsumer) external onlyOwner {
        randomNumberConsumer = RandomNumberConsumer(_randomNumberConsumer);

        emit RandomNumberConsumerUpdated(_randomNumberConsumer);
    }
}