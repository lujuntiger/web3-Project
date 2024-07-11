// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// import "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
// import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";


interface IRewardToken is IERC20 {
    function mint(address recipient, uint256 amount) external;
}

//质押合约
contract StakingSystem { 
    IERC721 public stakedNFT;  //要质押的NFT
    IRewardToken public rewardsToken; //实现奖励代币的发放
    //质押时间单位(以秒为单位)
    uint256 private immutable stakingTime = 3600 * 1e9; //默认为1小时，可以修改

    struct Staker { //存储关于质押者的信息 
      uint256[] tokenIds; //存储该质押者质押的所有NFT ID
      mapping(uint256 => uint256) lockPeriod; //将每个NFT ID映射到其锁定期结束的时间戳
      uint256 pendingRewards;      //记录每个质押者待领取的奖励数量
      uint256 totalRewardsClaimed; //记录每个质押者已领取的奖励总额
    }
    mapping(address => Staker) public stakers; //将每个质押者的地址（address类型）映射到一个Staker结构体实例
    mapping(uint256 => address) public tokenOwner; //将每个NFT ID映射到当前拥有该NFT的质押者的地址

    event StakedSuccess(address owner, uint256 tokenId); //质押成功 
    event RewardsClaimed(address indexed user, uint256 reward); //计算收益
    event UnstakedSuccess(address owner, uint256 tokenId); //解除质押成功事件

    constructor(IERC721 _stakedNFT, IRewardToken _rewardToken) {
	    stakedNFT = _stakedNFT;
        rewardsToken = _rewardToken;
    }

    //抵押函数: 用于处理NFT的质押逻辑	
    //参数：_tokenId（质押NFT的ID）
    function stake(uint256 _tokenId) public {
	    // 验证msg.sender是否为 _tokenId指定的NFT的所有者。如果不是，则报错。
	    require(stakedNFT.ownerOf(_tokenId) == msg.sender, "user must be the owner of the token");

        // 获取 msg.sender 对应的质押者数据，并将其存储在名为 staker 的 storage 变量中
	    Staker storage staker = stakers[msg.sender];

        // 将 _tokenId 添加到质押者 staker 的 tokenIds 数组中
	    staker.tokenIds.push(_tokenId);

        // 设置质押的NFT的锁定开始时间。将 block.timestamp 存储到staker的 lockPeriod 映射对应的 _tokenId 键中
	    staker.lockPeriod[_tokenId] = block.timestamp;

        //更新tokenOwner映射，为质押的 NFT 设置当前用户（msg.sender）作为新的所有者
	    tokenOwner[_tokenId] = msg.sender;

        //批准合约操作质押的NFT
	    stakedNFT.approve(address(this), _tokenId);

        //执行 NFT 从质押者到合约的安全转移
	    stakedNFT.safeTransferFrom(msg.sender, address(this), _tokenId);

        //记录质押操作的日志
	    emit StakedSuccess(msg.sender, _tokenId);
    }

    //计算奖励  根据用户质押的 NFT 及其质押时长来计算相应的奖励
    function calculateReward(address user) public {
        // 获取user对应的质押者数据，并将其存储在名为staker的storage变量中
        Staker storage staker = stakers[user];

        // 获取指定质押者 staker 的所有质押NFT ID列表
	    uint256[] storage ids = staker.tokenIds;

        // 遍历指定质押者的所有质押 NFT ID 列表			
	    for (uint256 i = 0; i < ids.length; i++) {
            // 需要满足的条件包括：NFT已被质押（锁定期大于0)，且质押时间已经结束（当前时间超过锁定期加质押时间)
	        if (staker.lockPeriod[ids[i]] > 0 && block.timestamp > staker.lockPeriod[ids[i]] + stakingTime)
	        {
                uint256 stakedPeriod = (block.timestamp - staker.lockPeriod[ids[i]]) / stakingTime;
                staker.pendingRewards += 10e18 * stakedPeriod;

                uint256 remainingTime = (block.timestamp - staker.lockPeriod[ids[i]]) % stakingTime;
                staker.lockPeriod[ids[i]] = block.timestamp + remainingTime;
	        }
       }
    }

    //质押者一次性领取所有待领奖励
    function claimAllRewards() public {
        //为调用者（msg.sender）计算当前的累积奖励
	    calculateReward(msg.sender);
	    
        //获取待领取奖励代币的总金额
        uint256 rewardAmount = stakers[msg.sender].pendingRewards;

        //更新调用者的总领取奖励金额
	    stakers[msg.sender].totalRewardsClaimed += rewardAmount;

        //重置调用者的待领取奖励金额
	    stakers[msg.sender].pendingRewards = 0;

        //铸造对应的代币
	    rewardsToken.mint(msg.sender, rewardAmount);

	    emit RewardsClaimed(msg.sender, rewardAmount);
    }

    //解除对 NFT 的质押	
    function unstake(uint256 _tokenId) public {
        require(tokenOwner[_tokenId] == msg.sender,
            "user must be the owner of the staked nft");

        //计算当前的累积奖励
	    calculateReward(msg.sender);

	    Staker storage staker = stakers[msg.sender];

	    require( staker.pendingRewards <= 0, "Claim your rewards first");
	    staker.lockPeriod[_tokenId] = 0;

	    if (staker.tokenIds.length > 0) {
            //找到对应的NFT ID并删除 
            for (uint256 i = 0; i < staker.tokenIds.length; i++) {
                if (staker.tokenIds[i] == _tokenId) {
                    if (staker.tokenIds.length > 1) {
                        staker.tokenIds[i] = staker.tokenIds[staker.tokenIds.length - 1];   
                    }
                    staker.tokenIds.pop();
                    break;
                }
            }
        }

	    //将解除质押的NFT还给所有者
	    stakedNFT.safeTransferFrom(address(this), msg.sender, _tokenId);

        //记录解除日志日志
	    emit UnstakedSuccess(msg.sender, _tokenId);
    }
}
