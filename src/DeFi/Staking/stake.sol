// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
质押需求：
1. 支持活期和定期，定期要有个可配置的最短时间，最长时间则为1年；
2. 奖励按秒计算（rewardsPerSecond），每秒的奖励是分配给所有质押者的；
3. 计算奖励时,定期质押的有加权,质押时间为1年的加权2.5倍,质押最短时间的加权1.1倍,中间的则根据时间平均增加权重,从[1.1,2.5]之间
*/

contract stake_new is Ownable, Pausable {
    //质押token地址
    IERC20 _stakeToken;
    //质押奖励token地址
    IERC20 _rewardToken;

    //每分钟产出奖励数量
    uint256 _rewardPerMin;
    //每份额累计总奖励
    uint256 _addUpRewardPerShare;
    //总挖矿奖励数量
    uint256 _totalReward;
    //累计总份额
    uint256 _totalShares;

    //累计虚拟总分额
    uint256 _totalVirtualShares;

    //最近一次（如果没有最近一次则是首次）挖矿区块时间，秒
    uint256 _lastBlockTime;
    //最近一次（如果没有最近一次则是首次）每份额累计奖励
    uint256 _lastAddUpRewardPerShareAll;

    //某地址的活期质押份额
    mapping(address => uint256) private _flexibleShares;

    //某地址的定期质押份额
    mapping(address => uint256) private _lockShares;

    //某地址的虚拟质押份额
    mapping(address => uint256) private _virtualShares;

    //某地址已经提现的奖励
    mapping(address => uint256) private _withdrawdReward;
    //某地址上一次关联的每份额累计已产出奖励
    mapping(address => uint256) private _lastAddUpRewardPerShare;
    //某地址最近一次关联的累计已产出总奖励
    mapping(address => uint256) private _lastAddUpReward;

    uint256 private _totalSupply; // 总存款
    uint256 private _virtualTotalSupply; // 虚拟总存款  固定存款*权重 + 活期存款; 

    mapping(address => uint256) private _balances; // 用户真实余额信息
    mapping(address => uint256) private _virtualBalances; // 用户虚拟余额信息 = 固定存款*权重 + 活期存款, 用于计算收益

    mapping(uint256 => uint256) private _depositRate; // 用户存款利率信息，活期利率key为1，表示1天,定期利率key为7-365，表示7-365天

    struct _depositInfo { // 存款信息
        uint256 amount;   //存款数额 
        uint256 endTime;  //到期时间
        uint256 lockDays;  //存款天数
    }

    mapping(address => uint256) _flexibleDepositInfos;  //活期存款信息

    mapping(address => bytes32[]) _userLockDepositIds;  //通过地址来查询用户拥有哪些定期存款
    mapping(bytes32 => _depositInfo) _lockDepositsInfos;  //定期存款信息     

    //构造函数
    constructor(address stakeTokenAddr, address rewardTokenAddr, uint256 rewardPerMin) Ownable(msg.sender) {
        _stakeToken = IERC20(stakeTokenAddr);
        _rewardToken = IERC20(rewardTokenAddr);
        _rewardPerMin = rewardPerMin; //每分钟的奖励
    }

    /*
      初始化用户定期存款利率(7-365天),最短存款时间7天，利率 
      设计函数 y = kx + b;
      1.1 = 7*x + b
      2.5 = 353*x + b ，从而计算出k和b;
      然后导入y=kx + b, 计算出每一种定期天数对应的利率
    */
    function setFixedDepositsTime() internal {
        _depositRate[7] = 1.1 * 10000;
        _depositRate[8] = 1.2 * 10000;
        /*
        ..............................
        */
        _depositRate[365] = 2.5 * 10000;
    }

    //活期质押,【外部调用/所有人/不需要支付/读写状态】
    /// @notice 1. msg.sender转入本合约_amount数量的质押token
    /// @notice 4. 记录此时msg.sender已经产出的总奖励
    /// @notice 2. 增加msg.sender等量的质押份额
    /// @notice 3. 计算此时每份额累计总产出奖励
    function stakeFlexibleDeposit(uint256 amount) external whenNotPaused {
        //活期额度转账给合约
        _stakeToken.transferFrom(msg.sender, address(this), amount); 

        //更新单份额累计收益
        uint256 currenTotalRewardPerShare = getRewardPerShare();

        //更新用户累计收益
        _lastAddUpReward[msg.sender] += (currenTotalRewardPerShare - _lastAddUpRewardPerShare[msg.sender]) * _virtualShares[msg.sender];

        //用户活期份额增加
        _flexibleShares[msg.sender] += amount;

        //用户虚拟份额增加()
        _virtualShares[msg.sender] += amount;

        //更新全局数据 
        updateTotalShare(amount, amount, 1);

        //更新用户单份额累计收益 
        _lastAddUpRewardPerShare[msg.sender] = currenTotalRewardPerShare;
    }

    //解除活期质押，提取token,【外部调用/所有人/不需要支付/读写状态】
    /// @notice 1. _amount必须<=已经质押的份额
    /// @notice 4. 记录此时msg.sender已经产出的总奖励
    function unStakeFlexibleDeposit(uint256 amount) external whenNotPaused {
        //用户活期质押额度要够
        require(amount <= _flexibleShares[msg.sender], "UNSTAKE_AMOUNT_MUST_LESS_SHARES");

        //合约金额转账给用户
        _stakeToken.transferFrom(address(this), msg.sender, amount); 

        //更新单份额累计收益
        uint256 currenTotalRewardPerShare = getRewardPerShare();
        _lastAddUpReward[msg.sender] +=  (currenTotalRewardPerShare - _lastAddUpRewardPerShare[msg.sender]) * _virtualShares[msg.sender];
        
        _flexibleShares[msg.sender] -= amount;
        _virtualShares[msg.sender] -= amount;

        updateTotalShare(amount, amount, 2);
        _lastAddUpRewardPerShare[msg.sender] = currenTotalRewardPerShare;
    }

    //质押定期存款
    function stakeLockDeposit(uint256 amount, uint16 lockDays) external whenNotPaused {
        // 存款数量>0
        require(amount > 0, "stake amount error");
        // 存款时间>7  
        require(lockDays >= 7 && lockDays <= 365, "stake amount error");

        // 转账额度到合约
        _stakeToken.transferFrom(msg.sender, address(this), amount); 

        // 更新单份额累计收益
        uint256 currenTotalRewardPerShare = getRewardPerShare();

        // 计算最新的累计收益
        _lastAddUpReward[msg.sender] += (currenTotalRewardPerShare - _lastAddUpRewardPerShare[msg.sender]) * _virtualShares[msg.sender];        

        //用户账户额度增加
        _lockShares[msg.sender] += amount;
        
        //用户虚拟账户额度增加                1.1-2.5之间的数字，即权重
        uint256 virtualMmount = amount * (_depositRate[lockDays] / 100000);
        _virtualShares[msg.sender] += virtualMmount;

        //更新全局数据
        updateTotalShare(amount, virtualMmount, 1);

        //更新每份额累计已产出奖励
        _lastAddUpRewardPerShare[msg.sender] = currenTotalRewardPerShare;

        //进行加密并生成存折ID
        bytes32 lockedId = keccak256(abi.encode(msg.sender, block.number));

        //生成存折信息
        _depositInfo memory info = _depositInfo(
            amount,
            lockDays,
            block.timestamp + lockDays * 1 days
        );       

        // 记录存款信息
        _lockDepositsInfos[lockedId] = info;

        // 用户增加一笔存款id信息
        _userLockDepositIds[msg.sender].push(lockedId);                
    }

    //解除定期质押，提取token
    //1、该笔定期存款额度要够
    //2、该笔定期存款要到期
    function unStakeLockDeposit(uint256 amount, bytes32 depositId) external whenNotPaused {
        //存款余额要够
        _depositInfo memory info = _lockDepositsInfos[depositId];

        //余额额度要够
        require(amount <= info.amount, "amount is not enough!");

        //定期存款要到期才能取出
        require(block.timestamp > info.endTime, "lock time");

        // 合约token转移到用户 
        _stakeToken.transferFrom(address(this), msg.sender, amount); 

        // 
        uint256 currenTotalRewardPerShare = getRewardPerShare();
        
        //更新用户累计收益
        _lastAddUpReward[msg.sender] +=  (currenTotalRewardPerShare - _lastAddUpRewardPerShare[msg.sender]) * _virtualShares[msg.sender];
        
        //用户定期账户额度减少 
        _lockShares[msg.sender] -= amount;
        //用户账户虚拟额度减少                    1.1-2.5之间的数字，即权重  
        uint256 virtualMmount = amount * (_depositRate[info.lockDays] / 100000);
        //账户虚拟额度减少
        _virtualShares[msg.sender] -= virtualMmount;

        //更新全局数据 
        updateTotalShare(amount, virtualMmount, 2);

        //更新每份额累计已产出奖励
        _lastAddUpRewardPerShare[msg.sender] = currenTotalRewardPerShare;         
    }

    //更新质押份额,【内部调用/合约创建者/不需要支付】
    // @param amount 更新的数量
    // @param type 1增加，其他 减少
    // @notice 每次更新份额之前，先计算之前的份额累计奖励
    function updateTotalShare(uint256 amount, uint256 virtualAmount, uint256 operType) internal onlyOwner {
        //更新单份额累计收益  
        _lastAddUpRewardPerShareAll = getRewardPerShare();
        //更新最新收益时间 
        _lastBlockTime = block.timestamp;
        if (operType == 1) {
            // 实际总分额
            _totalShares += amount;
            // 虚拟总分额
            _totalVirtualShares += virtualAmount;
        } else {
            // 实际总分额
            _totalShares -= amount;
            // 虚拟总分额
            _totalVirtualShares -= virtualAmount;
        }
    }

    //获取截至当前每份额累计产出,【内部调用/合约创建者/不需要支付/只读】
    // @notice 1.(当前区块时间戳-具体当前最近一次计算的时间戳)*每分钟产出奖励/60秒/总份额  + 距离当前最近一次计算的时候的每份额累计奖励 = 当前每份额累计奖励 
    // @notice 2. 更新最近一次计算每份额累计奖励的时间和数量 
    function getRewardPerShare() internal onlyOwner view returns(uint256) {  
        // return (block.timestamp - _lastBlockTime) * _rewardPerMin / 60 / _totalShares + _lastAddUpRewardPerShareAll;
        return (block.timestamp - _lastBlockTime) * _rewardPerMin / 60 / _totalVirtualShares + _lastAddUpRewardPerShareAll;
    }

    //计算累计奖励,【内部调用/合约创建者/不需要支付/只读】
    // @notice 仅供内部调用，统一计算规则
    function getAddupReward(address userAddress) internal onlyOwner view returns(uint256) {
        // return _lastAddUpReward[userAddress] +  ((getRewardPerShare() - _lastAddUpRewardPerShare[userAddress]) * _shares[userAddress]);
        return _lastAddUpReward[userAddress] +  ((getRewardPerShare() - _lastAddUpRewardPerShare[userAddress]) * _virtualShares[userAddress]);
    }

    //计算可提现奖励,【内部调用/合约创建者/不需要支付/只读】
    /// @notice 仅供内部调用，统一计算规则
    function getWithdrawdReward(address userAddress) internal onlyOwner view returns(uint256) {
        // return _lastAddUpReward[userAddress] + ((getRewardPerShare() - _lastAddUpRewardPerShare[userAddress]) * _shares[userAddress]) - _withdrawdReward[userAddress];
        return _lastAddUpReward[userAddress] + ((getRewardPerShare() - _lastAddUpRewardPerShare[userAddress]) * _virtualShares[userAddress]) - _withdrawdReward[userAddress];
    }

    //提现收益,【外部调用/所有人/不需要支付/读写】
    /// @notice 1. 计算截至到当前的累计获得奖励
    /// @notice 2. _amount必须<=(累计获得奖励-已提现奖励)
    /// @notice 3. 提现，提现需要先增加数据，再进行提现操作
    function withdraw(uint256 amount) external {
        //用户收益余额要足够
        require(amount <= getWithdrawdReward(msg.sender), "WITHDRAW_AMOUNT_LESS_ADDUPREWARD");
        //更新用户收益记录
        _withdrawdReward[msg.sender] += amount;
        //转账收益 
        _rewardToken.transferFrom(address(this), msg.sender, amount); 
    }

    //获取可提现奖励，【外部调用/所有人/不需要支付】
    function withdrawReword() external view returns(uint256) {
        return getWithdrawdReward(msg.sender);
    }

    //获取已提现奖励，【外部调用/所有人/不需要支付】
    function hadWithdrawdReword() external view returns(uint256) {
        return _withdrawdReward[msg.sender];
    }

    //获取累计奖励，【外部调用/所有人/不需要支付】
    function addUpReward() external view returns(uint256) {
        return getAddupReward(msg.sender);
    }

    //获取用户活期质押份额,【外部调用/所有人/不需要支付/只读】
    function getflexibleShare() external view returns(uint256) {
        return _flexibleShares[msg.sender];
    }

    //获取用户定期质押份额,【外部调用/所有人/不需要支付/只读】
    function getLockShare() external view returns(uint256) {
        return _lockShares[msg.sender];
    }

    //获取用户总质押份额,【外部调用/所有人/不需要支付/只读】
    function getTotalShare() external view returns(uint256) {
        return _flexibleShares[msg.sender] + _lockShares[msg.sender];
    }    
}
