// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC721 {
    function transferFrom(address _from, address _to, uint256 _nftId) external; 
}

//荷兰拍卖NFT合约
contract DutchAuction {
    uint256 private constant DURATION = 7 days; //锁定期
    address payable public immutable seller; //拍卖者
    uint256 public immutable startingPrice; //起拍价格
    uint256 public immutable startAt; //起始时间
    uint256 public immutable expiresAt; //过期时间
    uint256 public immutable discountRate; //折扣率
    IERC721 public immutable nft; // NFT
    uint256 public immutable nftId; //对应的id
    		
    constructor(
        uint256 _startingPrice, //起始时间
        uint256 _discountRate, //折扣时间
        address _nft, //NFT
        uint256 _nftId //NFT ID
    ) {
        seller = payable(msg.sender);
        startingPrice = _startingPrice;
        startAt = block.timestamp; //设置当前时间 
        expiresAt = block.timestamp + DURATION; //过期时间
        discountRate = _discountRate;
  
        require(
            _startingPrice >= _discountRate * DURATION, "starting price < min"
        );

        nft = IERC721(_nft);
        nftId = _nftId;
    }
    
    //获取当前拍卖价格
    function getPrice() public view returns (uint256) {
        uint256 timeElapsed = block.timestamp - startAt; //计算拍卖开始已经经过了多长时间

        uint256 discount = discountRate * timeElapsed;  //计算价格已经下降了多少

        return startingPrice - discount; //返回目前价格
    }
   
    //购买NFT
    function buy() external payable {
	      require(block.timestamp < expiresAt, "auction expired"); //检查拍卖是否已经过期

        uint256 price = getPrice();  //获取当前的拍卖价格

	      require(msg.value >= price, "ETH < price");  // 检查是否足够支付当前的拍卖价格

	      nft.transferFrom(seller, msg.sender, nftId); // 将NFT从卖家转移到买家

	      uint256 refund = msg.value - price; // 计算余额  

	      if (refund > 0) {  //检查是否有退款需要处理.如果有,则使用transfer函数将退款发送给买家
            payable(msg.sender).transfer(refund); //
        }
        selfdestruct(seller); //销毁合约，并将剩余的以太币发送给卖家地址 
    }
}
