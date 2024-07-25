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
    uint256 public rewardRate = 0;   //奖励利率
    uint256 public rewardsDuration = 365 days; //默认质押时间   	

    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userLockTime;  //用户的定期存款时间  	    	
    mapping(address => uint256) public userRewardPerTokenPaid; //用户每个token的平均收益
    mapping(address => uint256) public rewards;  //用户收益    	

    uint256 private _totalSupply; // 总存款
    mapping(address => uint256) private _balances; //用户余额

    //事件
    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    
    //构造函数
    constructor(
        address _owner,
        address _rewardsDistribution,
        address _rewardsToken,
        address _stakingToken
    ) public {
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
    }

    //设置用户定期存款时间
    function setFixedDepositsTime(uint lockTimeDays) external view {
        require(lockTimeDays >= 1 days && lockTimeDays <= 365 days, "invalid days");
	    userLockTime[msg.sender] = lockTimeDays;
    }	

    //总存款 
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    //当前账户的余额	
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    //得到最后一个奖励时间  	
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    //计算每个token的收益	
    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
            );
    }

    //计算用户赚的钱, 可以按照活期计算，也可以按照定期计算
    function earned(address account, uint mode) public view returns (uint256) {
	if (mode == 1) { //计算活期存款收益
	    return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);	
	}
	else { //计算定期存款收益
	    //定期质押的有加权,质押时间为1年的加权2.5倍,质押最短时间的加权1.1倍,中间的则根据时间平均增加权重,从[1.1,2.5]之间
            uint256 value = _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);

	    //计算对应的收益权重
	    uint256 DayWards = ((2.5 - 1.1) * userLockTime[msg.sender] * value) / 365;   	 

	    //最短1.1倍 + 存款时间对应的收益
	    return (userLockTime[msg.sender] * 11) / 10 + DayWards;   		
	}
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    //质押
    function stake(uint256 amount, uint mode) external updateReward(msg.sender, mode) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    //用户取款 	
    function withdraw(uint256 amount, uint mode) public nonReentrant updateReward(msg.sender, mode) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }    	

    //计算奖励
    function getReward(uint mode) public updateReward(msg.sender, mode) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    //用户销户 	
    function exit() external {
	withdraw(_balances[msg.sender]);
        getReward(0); //计算活期收益
	getReward(1); //计算定期收益
    }    

    //mode为1是活期存款，mode为2是定期存款 
    modifier updateReward(address account, uint mode) {
	// mode为1是活期存款, mode为2是定期存款
	require(mode == 1 || mode == 2, "mode error!!!"); 
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
	        rewards[account] = earned(account, mode);
	        userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
	_;
    }
}
