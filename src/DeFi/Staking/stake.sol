// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/* import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/utils/Pausable.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol"; */

/*
质押需求：
1. 支持活期和定期，定期要有个可配置的最短时间，最长时间则为1年；
2. 奖励按秒计算（rewardsPerSecond），每秒的奖励是分配给所有质押者的；
3. 计算奖励时,定期质押的有加权,质押时间为1年的加权2.5倍,质押最短时间的加权1.1倍,中间的则根据时间平均增加权重,从[1.1,2.5]之间
*/

contract StakingRewards is ReentrancyGuard, Pausable {
    using Math for uint256;

    IERC20 public rewardsToken; //奖励token 
    IERC20 public stakingToken; //质押token 
    uint256 public periodFinish = 0; //阶段结束时间
    uint256 public rewardRate = 5000;   //活期利率
    uint256 public rewardsDuration = 99999999 days; //默认奖励时间   	

    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid; //用户每个token的平均收益
    mapping(address => uint256) public rewards;  //用户收益    	

    uint256 private _totalSupply; // 总存款
    uint256 private _virtualTotalSupply; // 虚拟总存款  固定存款*权重 + 活期存款; 

    mapping(address => uint256) private _balances; // 用户真实余额信息
    mapping(address => uint256) private _virtualBalances; // 用户虚拟余额信息 = 固定存款*权重 + 活期存款, 用于计算收益

    mapping(uint16 => uint16) private _depositRate; // 用户存款利率信息，活期利率key为1，表示1天,定期利率key为7-365，表示7-365天

    struct _depositInfo { // 存款信息
        uint256 amount;     //存款数额 
        uint256 lockDays;   //存款天数
        uint256 endTime;  //到期时间
    }

    mapping(address => uint256) _flexibleDepositInfos;  //活期存款信息

    mapping(address => bytes32[]) _userLockDepositIds;  //通过地址来查询用户拥有哪些定期存款
    mapping(bytes32 => _depositInfo) _LockDepositsInfos;  //定期存款信息       

    //事件日志
    //质押活期存款
    event StakeFlexibleDeposit(uint256 amount);
    //用户活期取款 	
    event WithDrawFlexibleDeposit(uint256 amount);
    //质押定期存款
    event StakeLockDeposit(uint256 amount, uint16 lockDays);
    //用户固定期取款 
    event WithDrawLockDeposit(uint256 amount, uint16 depositId);
    //更新奖励周期 
    event RewardsDurationUpdated(uint rewardsDuration);
    //奖励用户
    event RewardPaid(address account, uint256 reward);

    //构造函数
    constructor(
        address _rewardsToken,
        address _stakingToken
    ) public {
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);

        //初始化活期利率和定期存款利率
        setFixedDepositsTime();
    }

    /*
      初始化用户定期存款利率(7-365天),最短存款时间7天，利率 
      设计函数 y = kx + b;
      1.1 = 7*x + b
      2.5 = 353*x + b ，从而计算出k和b;
      然后导入y=kx + b, 计算出每一种定期天数对应的利率
    */
    function setFixedDepositsTime() internal view {
        _depositRate[7] = 1.1 * 10000;
        _depositRate[8] = 1.2 * 10000;
        /*
        ..............................
        */
        _depositRate[365] = 2.5 * 10000;
    }	

    // 总存款
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    // 虚拟总存款,仅在内部使用
    function virtualTotalSupply() internal view returns (uint256) {
        return _virtualTotalSupply;
    }

    // 当前账户的余额	
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    // 获取奖励的最新时间  	
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    //计算每个token的收益,固定收益的利率要按照 活期利率 * 权重计算	
    function rewardPerToken() public view returns (uint256) {
        if (_virtualTotalSupply == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored.add(
            ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / _virtualTotalSupply);
        }
    }

    // 计算用户赚的钱, 
    function earned(address account, uint mode) public view returns (uint256) {
        //计算活期存款收益
        return _virtualBalances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);    
    }

    // 计算奖励
    function getRewardForDuration() external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    //质押活期存款
    function stakeFlexibleDeposit(uint256 amount) external updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        
        _totalSupply = _totalSupply.add(amount);
        _virtualTotalSupply = _virtualTotalSupply.add(amount); 
        
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        _virtualBalances[msg.sender] = _virtualBalances[msg.sender].add(amount);

        // mapping(address => uint256) _flexibleDepositInfos;  //活期存款信息
        //用户增加一笔存款信息
        _flexibleDepositInfos[msg.sender] =  _flexibleDepositInfos[msg.sender].add(amount);

        //转账到合约
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);       

        //质押活期存款
        emit StakeFlexibleDeposit(amount);        
    }

    //用户活期取款 	
    function withDrawFlexibleDeposit(uint256 amount) public updateReward(msg.sender) {
        //mapping(address => uint256) _flexibleDepositInfos;  //活期存款信息

        require(amount > 0, "Cannot withdraw 0");

        //余额额度要够
        require(amount <= _flexibleDepositInfos[msg.sender], "amount is not enough");

        _totalSupply = _totalSupply.sub(amount);
        _virtualTotalSupply = _virtualTotalSupply.sub(amount); 

        _flexibleDepositInfos[msg.sender] = _flexibleDepositInfos[msg.sender].sub(amount);        

        _balances[msg.sender] = _balances[msg.sender].sub(amount);

        stakingToken.safeTransfer(msg.sender, amount);        

        //计算利息
        getReward();

        //用户活期取款 	
        emit WithDrawFlexibleDeposit(amount);        
    }

    //质押定期存款
    function stakeLockDeposit(uint256 amount, uint16 lockDays) external updateReward(msg.sender) {
        require(amount >= 7 && amount <= 365, "stake amount error");

        // mapping(address => bytes32[]) _userLockDepositIds;   //通过地址来查询用户拥有哪些定期存款
        // mapping(bytes32 => _depositInfo) _LockDepositsInfos; //定期存款信息      

        //进行加密并生成存折ID
        bytes32 lockedId = keccak256(abi.encode(msg.sender, block.number));

        //生成存折信息
        _depositInfo memory info = _depositInfo(
            amount,
            lockDays,
            block.timestamp + lockDays * 1 days
        );       

        // 记录存款信息
        _LockDepositsInfos[lockedId] = info;

        // 用户增加一笔存款信息
        _userLockDepositIds[msg.sender].push(lockedId);
        
        // 池子总存款数  
        _totalSupply = _totalSupply.add(amount);

        uint256 virtualMmount = amount * _depositRate[lockDays];  
        // 定期存款需要计算权重
        _virtualTotalSupply = _virtualTotalSupply.add(virtualMmount);

        _balances[msg.sender] = _balances[msg.sender].add(amount);
        _virtualBalances[msg.sender] = _virtualBalances[msg.sender].add(virtualMmount);

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // 质押定期存款
        emit StakeLockDeposit(amount, lockDays);        
    }   

    //取出定期存款
    //1、该笔定期存款额度要够
    //2、该笔定期存款要到期
    function withDrawLockDeposit(uint256 amount, uint16 depositId) external {
        // mapping(address => bytes32[]) _userDepositIds; //通过地址来查询用户拥有哪些定期存款
        // mapping(bytes32 => _depositInfo) _fixedDepositsInfos;  //定期存款信息

        /* 
            struct _depositInfo { // 存款信息
                uint256 amount;     //存款数额 
                uint256 lockDays;   //存款天数
                uint256 endTime;  //到期时间
            } 
        */
        
        //存款余额要够
        _depositInfo memory info = _LockDepositsInfos[msg.sender][depositId];

        //余额额度要够
        require(amount <= info.amount, "amount is not enough!");

        //定期存款要到期才能取出
        require(block.timestamp > info.endTime);

        //更新相关收益
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        
        if (msg.sender != address(0)) {
	        rewards[msg.sender] = earned(msg.sender);
	        userRewardPerTokenPaid[msg.sender] = rewardPerTokenStored;
        }        

        // 池子实际总额度减少
        _totalSupply = _totalSupply.sub(amount);        

        // 个人实际总额度减少
        _balances[msg.sender] = _balances[msg.sender].sub(amount);

        uint256 virtualMmount = amount * _depositRate[info.lockDays];

        // 池子虚拟总额度减少
        _virtualTotalSupply = _virtualTotalSupply.sub(virtualMmount);        

        // 个人虚拟总额度减少
        _virtualBalances[msg.sender] = _virtualBalances[msg.sender].sub(virtualMmount);

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        //计算利息
        getReward();
        
        //用户固定期取款 
        emit WithDrawLockDeposit(amount, depositId); 
    }

    //转移利息给用户
    function getReward() public updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);

            //记录日志
            emit RewardPaid(msg.sender, reward);
        }
    }

    // 设置奖励时间,只有owner才有权限
    function setRewardsDuration(uint256 _rewardsDuration) external {
        require(block.timestamp > periodFinish,
            "Previous rewards period must be complete before changing the duration for the new period"
        );
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    //用户销户，需要所有的定期存款全部到期，才能销户 	
    function accountCancel() external updateReward(msg.sender) {
    /*    struct _depositInfo { // 存款信息
            uint256 amount;     //存款数额 
            uint256 lockDays;   //存款天数
            uint256 endTime;  //到期时间
        }

        mapping(address => uint256) _flexibleDepositInfos;  //活期存款信息
        
        mapping(address => bytes32[]) _userLockDepositIds;  //通过地址来查询用户拥有哪些定期存款
        mapping(bytes32 => _depositInfo) _LockDepositsInfos;  //定期存款信息
    */

        require(msg.sender != address(0), "address must not be 0!");

        uint flag = 0;
        uint256 now_time = block.timestamp;

        uint length = _userLockDepositIds[msg.sender].length;
        for (uint i = 0; i < length; i++) {
            if (_userLockDepositIds[msg.sender][i].endTime > now_time) {
                flag = 1;
                break;
            }
        }
        
        //还有没到期的定期存款
        if (flag == 1) return;

        //先取出活期存款
        uint256 amount = _flexibleDepositInfos[msg.sender];  

        _totalSupply = _totalSupply.sub(amount);
        _virtualTotalSupply = _virtualTotalSupply.sub(amount);
        
        stakingToken.safeTransfer(msg.sender, amount);
        // 删除活期存款信息
        delete _flexibleDepositInfos(msg.sender);       

        // mapping(address => bytes32[]) _userLockDepositIds;  //通过地址来查询用户拥有哪些定期存款
        // mapping(bytes32 => _depositInfo) _LockDepositsInfos;  //定期存款信息

        //再取出定期存款
        for (uint i = 0; i < length; i++) {             
            stakingToken.safeTransfer(msg.sender, _userLockDepositIds[msg.sender][i].amount);

            //删除定期存款信息
            delete _LockDepositsInfos(_userLockDepositIds[msg.sender][i]); 
        }

        //删除用户存款信息
        delete _userLockDepositIds[msg.sender];

        //用户在合约的存款
        _balances[msg.sender] = 0;
        _virtualBalances[msg.sender] = 0;

        getReward(); //获取利息收益	    
    }    

    //更新用户收益 
    modifier updateReward(address account) {
	    rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
	        rewards[account] = earned(account);
	        userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
	    _;
    }
}
