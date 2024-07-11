// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

//收益农场模块
//import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

//利率计算组件
library LoanLibrary {
    //计算存款收益
    function calculateDepositInterest(
        uint256 amount,
        uint256 interestRate,
        uint256 period
    ) external pure returns (uint256) {
        uint256 reward = (amount * period) / interestRate;
        return reward;
    }

    //计算锁定期收益 本金+利息  	
    function calculateLockedInterest(
        uint256 amount,
        uint256 interestRate,
        uint256 coefficient
    ) external pure returns (uint256) {
        uint256 interest = (amount * interestRate) / coefficient;
        return amount + interest;
    }
}

contract Treasury {
    IERC20 public lpToken;
    address public system;
    modifier onlySystem() {
        require(msg.sender == system);
        _;
    }

    constructor(address _token) {
        lpToken = IERC20(_token);
        system = msg.sender;
    }

    function withdrawTo(address to, uint256 amount) external onlySystem {
        lpToken.transfer(to, amount);
    }
}

//Yield Farming收益农场合约
contract LoanSystem {
    struct lockedInfo { // 存款信息
        address user;         //存款人 - 标记存款者
        uint256 lockedAmount; //存款数额 - 作为存款数额的凭证 
        uint256 startBlock;   //存款开始时间 - 作为锁定期的计算标识
        uint256 interestRate; //利率 - 作为这笔存款利率的计算标识
    }
    uint256 constant INTEREST_COEFFICIENT = 10 ** 8;  //利率系数   
    uint256 public immutable interestUnLockedRate; //表示区块利率 
    uint256 public immutable interestLockedRate;   //表示定期利率	
    uint256 public immutable lockDuration; //定期锁定时间 

    IERC20 public lpToken;
    Treasury public treasury;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public lastRewardBlock;
    mapping(address => bytes32[]) userLockedIds; //通过地址来查询用户拥有哪些存折
    mapping(bytes32 => lockedInfo) lockedInfos;  //存折信息

    //定义事件日志
    event Deposit(address indexed account, uint256 amount);
    event Withdraw(address indexed account, uint256 amount);
    event DepositWithLock(address indexed account, bytes32 indexed lockedId, uint256 lockedAmount);
    event WithdrawLocked(address indexed account, bytes32 indexed lockedId, uint256 totalAmount);
    event Reward(address indexed account, uint256 interest);

    constructor(
        address _lpToken,
        uint256 _lockDuration,
        uint256 _lockedRate,
        uint256 _unlockedRate
    ) {
        lpToken = IERC20(_lpToken);
        treasury = new Treasury(_lpToken);
        lockDuration = _lockDuration;

        interestLockedRate = _lockedRate;  //固定期利率
        interestUnLockedRate = _unlockedRate; //区块利率
    }

    //存入指定数量的代币并计算收益 	
    function deposit(uint256 amount) external {
        //计算收益
        reward(msg.sender);
        
        //转移代币到合约
	    lpToken.transferFrom(msg.sender, address(treasury), amount);
        balanceOf[msg.sender] += amount;

        emit Deposit(msg.sender, amount);
    }

    // 取出指定数量的代币并计算收益 	
    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount);
        //计算收益
        reward(msg.sender);

        lastRewardBlock[msg.sender] = block.number;
        balanceOf[msg.sender] -= amount;

        //返回代币
        treasury.withdrawTo(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    // 计算收益
    // interest 利率
    function reward(address account) public returns (uint256 interest) {
        require(msg.sender == account || msg.sender == address(this));

        //目前账户上的代币
        uint256 balance = balanceOf[account];

        //计算经历了多少个区块
        uint256 period = block.number - lastRewardBlock[account];

        // 计算存款利息
        interest = LoanLibrary.calculateDepositInterest(
            balance,
            interestUnLockedRate,
            period
        );
        //用户接收利息
        treasury.withdrawTo(account, interest);

        //更新区块收益ID
        lastRewardBlock[msg.sender] = block.number;
        emit Reward(account, interest);
    }

    // 固定期存款收益
    function depositWithLock(
        uint256 lockedAmount
    ) external returns (bytes32 lockedId) {
        //转移用户代币到合约
        lpToken.transferFrom(msg.sender, address(treasury), lockedAmount);

        //生成存折信息
        lockedInfo memory info = lockedInfo(
            msg.sender,
            lockedAmount,
            block.number,
            interestLockedRate
        );

        //进行加密并生成存折ID
        lockedId = keccak256(abi.encode(msg.sender, block.number));
        lockedInfos[lockedId] = info;

        //用户增加一笔存款信息
        userLockedIds[msg.sender].push(lockedId);

        emit DepositWithLock(msg.sender, lockedId, lockedAmount);
    }

    // 存款代币到期取回 	
    function withdrawLocked(bytes32 lockedId) external {
        lockedInfo memory info = lockedInfos[lockedId];
        require(msg.sender == info.user);
        require(block.number >= info.startBlock + lockDuration);

        //计算本金和利息 
        uint256 totalAmount = LoanLibrary.calculateLockedInterest(
            info.lockedAmount,
            info.interestRate,
            INTEREST_COEFFICIENT
        );
        
        //本金和利息返还给用户
        treasury.withdrawTo(msg.sender, totalAmount);
        emit WithdrawLocked(msg.sender, lockedId, totalAmount);
    }
}
