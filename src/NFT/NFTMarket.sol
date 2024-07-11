// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// NFT合约
contract NFT {
    // 定义 Token 结构体，用于存储 NFT 信息
    struct Token {
        string name;        // NFT名称
        string description; // NFT描述信息
        address owner;      // NFT所有者地址
    }
    
    // 使用 mapping 存储每个 NFT 的信息
    mapping(uint256 => Token) private tokens;

    // 使用 mapping 存储每个地址所拥有的 NFT ID 列表
    mapping(address => uint256[]) private ownerTokens;

    // 定义NFT权限转移
    mapping (uint256 => address) private tokenApprovals;
        
    // 记录下一个可用的ID
    uint256 nextTokenId = 1;
    
    // 创建 NFT 函数，用于创建一个新的 NFT，并将其分配给调用者
    function mint(string memory _name, string memory _description) public returns(uint256){ 
        Token memory newNFT = Token(_name, _description, msg.sender);
        tokens[nextTokenId] = newNFT;
        ownerTokens[msg.sender].push(nextTokenId);
        nextTokenId++;
        return nextTokenId-1;
    }

    // 获取指定 NFT 的信息
    function getNFT(uint256 _tokenId) public view returns (string memory name, string memory description, address owner) {
        require(_tokenId >= 1 && _tokenId < nextTokenId, "Invalid token ID");
        Token storage token = tokens[_tokenId];
        name = token.name;
        description = token.description;
        owner = token.owner;
    }

    // 获取指定地址所拥有的所有 NFT ID
    function getTokensByOwner(address _owner) public view returns (uint256[] memory) {
        return ownerTokens[_owner];
    }

    // 转移指定 NFT 的所有权给目标地址
    function transfer(address _to, uint256 _tokenId) public {
        require(_to != address(0), "Invalid recipien");
        require(_tokenId >= 1 && _tokenId < nextTokenId, "Invalid TokenID");
        Token storage token = tokens[_tokenId];
        require(token.owner == msg.sender, "You don't own this token");
        
        // 将 NFT 的所有权转移给目标地址
        token.owner = _to;
        
        deleteById(msg.sender, _tokenId);
        ownerTokens[_to].push(_tokenId);
    }

    function deleteById(address account, uint256 _tokenId) internal {
        uint256[] storage ownerTokenList = ownerTokens[account];
        for (uint256 i = 0; i < ownerTokenList.length; i++) {
            if (ownerTokenList[i] == _tokenId) {
                // 将该 NFT ID 与数组最后一个元素互换位置，然后删除数组最后一个元素
                ownerTokenList[i] = ownerTokenList[ownerTokenList.length - 1];
                ownerTokenList.pop();
                break;
            }
        }
    }

    // 销毁NFT
    function burn(uint256 _tokenId) public {
        require(_tokenId >= 1 && _tokenId < nextTokenId, "Invalid TokenID");
        Token storage token = tokens[_tokenId];
        require(token.owner == msg.sender, "You don't own this token");
        
        deleteById(msg.sender, _tokenId);
        delete tokens[_tokenId];
    }

    // owner将指定NFT的所有权转移到目标地址
    function transferFrom(address _from, address _to, uint256 _tokenId) public {
        require(_to != address(0), "Invalid recipient");
        require(_tokenId >= 1 && _tokenId < nextTokenId, "Invalid token ID");
        Token storage token = tokens[_tokenId];
        address owner = token.owner;

        // 检查是否有权限操作
        require(msg.sender == owner || msg.sender == tokenApprovals[_tokenId]);

        // 更新NFT的所有人权限
        token.owner = _to;

        // 更新权限数组信息
        uint256[] storage fromTokenList = ownerTokens[_from];
        for (uint256 i = 0; i < fromTokenList.length; i++) {
            if (fromTokenList[i] == _tokenId) {
                // 挪动到数组尾部
                fromTokenList[i] = fromTokenList[fromTokenList.length - 1];
                fromTokenList.pop();
                break;
            }
        }

        //新owner新增NFT
        ownerTokens[_to].push(_tokenId);

        //删除原有的权限信息 
        delete tokenApprovals[_tokenId];
    }

    // 授权将NFT所有权转移到目标owner地址
    function approve(address _approved, uint256 _tokenId) public {
        require(_tokenId >= 1 && _tokenId < nextTokenId, "Invalid token ID");
        Token storage token = tokens[_tokenId];
        address owner = token.owner;

        // 检查是否有权限
        require(msg.sender == owner, "Not authorized");

        // 更新映射数据
        tokenApprovals[_tokenId] = _approved;
    }
 
    //查询指定tokenId对应的owner 
    function ownerOf(uint256 tokenId) public view returns(address) {
        return tokens[tokenId].owner;
    }
}

// NFT市场，可以买卖NFT
contract NFTMarketplace {
    struct Order {
        uint256 tokenId;
        address seller;
        uint256 price;
    }

    mapping(uint256 => Order) public tokenOrders;
    NFT nftContract;

    event NewOrder(uint256 indexed tokenId, address indexed seller, uint256 price);
    event OrderBought(uint256 indexed tokenId, address indexed buyer, uint256 price);
		event OrderCanceled(uint256 indexed tokenId);

    constructor(address _nftContractAddress) {
        nftContract = NFT(_nftContractAddress);
    }

    // 得到指定NFT ID的订单信息 
    function getOrder(uint256 _tokenId) public view returns (uint256 tokenId, address seller, uint256 price) {
        Order memory order = tokenOrders[_tokenId];
        return (order.tokenId, order.seller, order.price);
    }

    //将用户指定的NFT和想要售卖的价格，上架到交易市场的“货架”上
    function listNFT(uint256 _tokenId, uint256 _price) public {
        //判断调用者是否是NFT的持有者
        require(msg.sender == nftContract.ownerOf(_tokenId));
        require(_price > 0);

        //将NFT上架       
        nftContract.transferFrom(msg.sender, address(this), _tokenId);

        //生成预售的订单
        tokenOrders[_tokenId] = Order(_tokenId, msg.sender, _price);
        emit NewOrder(_tokenId, msg.sender, _price);
    }
    
    // 购买NFT
    function buyNFT(uint256 _tokenId) external payable {
        Order memory order = tokenOrders[_tokenId];

        //检查价格
        require(msg.value == order.price, "Incorrect price");
        
        //取走NFT
        nftContract.transfer(msg.sender, _tokenId);

        //付钱
        payable(order.seller).transfer(msg.value);

        delete tokenOrders[_tokenId];
        emit OrderBought(_tokenId, msg.sender, msg.value);
    }

    // 取消订单
    function cancelOrder(uint256 _tokenId) public {
        Order memory order = tokenOrders[_tokenId];
        require(msg.sender == order.seller, "You are not the seller");

        //取走tokenId
        nftContract.transfer(order.seller, _tokenId);

        delete tokenOrders[_tokenId];			
        emit OrderCanceled(_tokenId);
    }
}
