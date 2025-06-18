// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;


// CONTEXT
abstract contract Context 
{
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        this;
        return msg.data;
    }
}

// OWNABLE
abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);


    constructor() {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }


    function owner() public view virtual returns (address) {
        return _owner;
    }

    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }


    modifier onlyOwner() {
        require(owner() == _msgSender(), "Caller is not the owner");
        _;
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "New owner can not be the ZERO address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

// REENTRANCY GUARD
abstract contract ReentrancyGuard 
{
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


// Lottery INTERFACE
abstract contract WaveLottery
{
    function draw(uint256 poolId, uint256 result) external virtual;
}


abstract contract WaveController
{
     function resolve(uint256 id, uint256 length) external virtual; 
}


contract WaveReferee is ReentrancyGuard, Ownable 
{
    
    // Lottery Contract
    WaveLottery internal lotteryContract;

    // WaveController
    WaveController internal controllerContract;
  
    constructor(address _lotteryAddress) 
    {
        lotteryContract = WaveLottery(_lotteryAddress);
    }


    modifier onlyLotteryContract() 
    {
        require(msg.sender == address(lotteryContract), "Only game contract allowed");
        _;
    }
    
    modifier onlyControllerContract() 
    {
        require(msg.sender == address(controllerContract), "Only controller contract allowed");
        _;
    }

    function setWaveController(address _controllerAddress) external onlyOwner 
    {
        controllerContract = WaveController(_controllerAddress);
    }

    function setWaveLottery(address _lotteryAddress) external onlyOwner 
    {
        lotteryContract = WaveLottery(_lotteryAddress);
    }
    
    // -------------------------
    // START ----------------
    //--------------------------
    function resolve(uint256 id, uint256 length) external onlyLotteryContract
    {
        controllerContract.resolve(id, length);
    }

    // -------------------------
    // FALLBACK ----------------
    //--------------------------
    function draw(uint256 id, uint256 result) external onlyControllerContract
    {
        lotteryContract.draw(id, result);
    }
    
}