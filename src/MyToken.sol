// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
//import "openzeppelin-contracts/contracts-upgradeable/utils/AddressUpgradeable.sol";

/**
开发的token包含如下功能:
1、遵循ERC20协议;
2、可升级(待后续补充);
3、支持链下签名permit(待后续补充);
4、支持暂停功能;
5、支持货币发行量上限;
6、支持owner授权下的增发和销毁:
7、支持黑名单功能；上黑名单的用户禁止任何操作;
8、增发比例不能超过当前总量的1%；
9、增发后，至少需要再过一年后才能再进行下一次增发；
10、用户能销毁自己的代币，也可由授权人进行销毁；
*/

//权限控制
contract Ownable {
    address public owner;
    // 构造函数 将合约的第一个调用者的账户地址address，设置为owner
    constructor() {
        // 设置合约的拥有者为owner
        owner = msg.sender;
    }

    modifier onlyOwner() {
        //要求调用者地址必须是owner
        require(msg.sender == owner);
        _;
    }

    //允许当前owner转移控制权给其他人,新的owner也可以再次转移
    function transferOwnership(address newOwner) public onlyOwner {
        // 新owner不能是0地址
        if (newOwner != address(0)) {
            owner = newOwner;
        }
    }
}

//只有合约的Owner可以操作,既可以暂停合约,又可以重新启动合约
contract Pausable is Ownable {
    event Pause();
    event Unpause();

    // 定义一个是否暂停的变量，只有true/false两种状态
    bool public paused = false;

    // 用了whenNotPaused修饰符的方法，只能在合约没有暂停的时候，才能调用
    modifier whenNotPaused() {
        // 要求必须没有暂停
        require(!paused);
        _;
    }

    // 用了whenPaused修饰符的函数，只有合约暂停的时候，才能调用
    modifier whenPaused() {
        require(paused);
        _;
    }

    /**
      只有owner才有权限调用这个暂停函数，且只能在合约没暂停的时候调用。
      一旦执行这个函数，可以使整个合约暂停
    */
    function pause() onlyOwner whenNotPaused public {
        paused = true;
        emit Pause();
    }

    /**
      这个函数可以重新恢复运行，回到正常状态。
      只能owner在合约已暂停状态下调用    
    */
    function unpause() onlyOwner whenPaused public {
        paused = false;
        emit Unpause();
    }
}

/*
主程序
1、遵循ERC20协议、
2、可升级(待后续补充);
3、支持链下签名permit(待后续补充);
4、支持暂停合约功能;
5、支持货币发行量上限;
6、支持owner授权下的增发和销毁:
7、支持黑名单功能；上黑名单的用户禁止任何操作;
8、增发比例不能超过当前总量的1%；
9、增发后，至少需要再过一年后才能再进行下一次增发；
10、用户能销毁自己的代币，也可由授权人进行销毁；
*/
contract newToken is Pausable, ERC20 {    
    uint public ONE = 1e18;
    uint private factor = ONE;
    uint private lastMintTime; //上次铸造代币的时间
    uint256 private immutable mint_max_count = 1000000 * ONE; //可以铸造代币的数量上限
    
    //存储黑名单列表的mapping数据结构，value为true就表示该地址进入了黑名单
    // mapping的value默认值是false
    mapping (address => bool) public isBlackListed;

    // 日志
    event AddedBlackList(address _user);
    event RemovedBlackList(address _user);
    
    //初始化最大发行代币数量
    constructor() ERC20("Mytoken", "token") {
        require(mint_max_count > 0, "max token supply is 0");
        
        //铸造初始代币,数量为最大发行量的一半
        _mint(msg.sender, mint_max_count >> 2);

        //设置初始铸币时间
        lastMintTime = block.timestamp;
    }

    // 通过该方法可以获知user地址是否在黑名单里，external仅外部调用
    function getBlackListStatus(address _user) private view returns (bool) {
    //    可以获知这个地址是否在黑名单里，是则返回true
        return isBlackListed[_user];
    }

    // 增加某个地址进入黑名单列表，仅owner可调用
    function addBlackList(address _user) external onlyOwner {
        isBlackListed[_user] = true;
        // 写入日志
        emit AddedBlackList(_user);
    }

    // 把某用户地址从黑名单列表里移除，仅owner可调用
    function removeBlackList(address _user) external onlyOwner {
        // 改为false即可
        isBlackListed[_user] = false;
        // 写入日志
        emit RemovedBlackList(_user);
    }

    // 销毁黑名单里地址的钱，仅owner可以调用
    function destroyBlackFunds(address _blackListedUser) internal onlyOwner {
        // 需要本身是在黑名单里
        require(isBlackListed[_blackListedUser] == true, "user is not in blacklist!");

        uint dirtyFunds = super.balanceOf(_blackListedUser);   

        //销毁对应的代币
        _burn(_blackListedUser, dirtyFunds);
    }

    //重写内部update函数，限制0x0地址转账，限制黑名单地址转账, 支持pause功能
    function _update(address from, address to, uint256 value) internal virtual override whenNotPaused {
        //黑名单用户不能转账
        require( getBlackListStatus(from) == false && getBlackListStatus(to) == false, "from user is in blaccklist!");
        
        super._update(from, to, value);        
    }

    function totalSupply() public override view returns (uint256) {
        //黑名单用户禁止操作
        require(getBlackListStatus(msg.sender) == false, "current user is in blaccklist!");    
        
        return super.totalSupply() * factor /  ONE;
    }  

    function balanceOf(address account) public override view returns (uint256) {
        //黑名单用户禁止操作
        require(getBlackListStatus(account) == false, "account is in blaccklist!");

        return super.balanceOf(account) * factor /  ONE;
    }    

    // 
    function underBalance(uint256 amount) public view returns (uint256 b) {
        b = amount * ONE / factor;
    }

    //重写内部核心转账函数 
    function transfer(address to, uint256 value) public virtual override returns (bool) {
        uint under = underBalance(value);
        return super.transfer(to , under);
    }

    //重写内部核心转账函数
    function transferFrom(address from, address to, uint256 value) public virtual override returns (bool) {
        uint under = underBalance(value);
        return super.transferFrom(from, to, under);        
    }

    /**
     * 1. 增发数量不能超过发行上限；
       2. 增发比例不能超过当前总量的1%；
       3. 增发后，至少需要再过1年后才能再进行下一次增发；   
     */
    function mint(address account, uint256 amount) public {
        //增发后, 至少需要再过一年后才能再进行下一次增发
        require( block.timestamp - lastMintTime >= 365 days, "ERC20Token: mint time is error!");

        //增发数量不能超过设定的上限
        require( super.totalSupply() + amount <= mint_max_count, "ERC20Token: can not Exceeding the total count!");

        //增发比例不能超过当前总量的1%
        require( amount <= ((super.totalSupply() * factor) / (ONE * 100)) , "ERC20Token: count Exceeding the mint standard !");

        //铸造代币
        _mint(account, amount);
        
        //更新上次铸造时间
        lastMintTime = block.timestamp;
    }

    //销毁代币 
    function burn(uint256 amount) public {
        //黑名单用户禁止操作
        require( getBlackListStatus(msg.sender) == false, "user is in blacklist!");

        //销毁代币
        _burn(msg.sender, amount);
    }

    //委托其它用户销毁代币
    function burn_from(address _user, uint256 _amount) public {
        //黑名单用户禁止操作
        require( getBlackListStatus(_user) == false, "user is in blacklist!");

        //授权其他用户
        _spendAllowance(msg.sender, _user, _amount);
        
        //被授权用户销毁代币
        _burn(_user, _amount);
    }
}
