// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IWETH.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Callee.sol";
import "./interfaces/ICEther.sol";
import "./interfaces/ICERC20.sol";
import "./interfaces/IComptroller.sol";
import "./libraries/TransferHelper.sol";
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

//  is IUniswapV2Callee,Initializable, Ownable 
contract TradingAccount {
    address public owner;
    address public weth;
    address public usdt;
    address public uniswapV2Pair;
    address public cETH;
    address public cUSDT;
    address public comptroller;
    address public priceFeed;
    uint256 public lastOrderId;    
    //mapping(uint256 => LimitOrder) public override getLimitOrder;

    struct TempParams {
        bool isOpen;
        bool isLong;
        uint256 openSize;
        uint256 borrowedAmount;
        uint256 cTokenMinted;
        uint256 cTokenRedeemed;
        uint256 underlyingRedeemed;
        uint256 repayAmount;
    }
    TempParams private tempParams;
    uint256 public lastCEthBalance;
    uint256 public lastCUsdtBalance;

    // 存入ETH、USDT
    event Deposit(bool flag, uint256 depositAmount, uint256 cEthAmountGet);
    // 取款ETH、USDT
    event Withdraw(bool flag, uint256 cUsdtAmount, uint256 usdtAmount);
    // 开多
    event OpenLong(uint256 ethSize, uint256 cEthAmountGet, uint256 borrowedAmount);
    // 开空
    event OpenShort(uint256 usdtSize, uint256 cUsdtAmountGet, uint256 borrowedAmount);
    // 平多
    event CloseLong(uint256 redeemedCToken, uint256 underlyingRedeemed, uint256 repayAmount, bool flag);
    // 平空
    event CloseShort(uint256 redeemedCToken, uint256 underlyingRedeemed, uint256 repayAmount, bool flag);
    
    function initialize(
        address owner_,
        address weth_,
        address usdt_,
        address uniswapV2Pair_,
        address cETH_,
        address cUSDT_,
        address comptroller_,
        address priceFeed_
    ) external {
        owner = owner_;
        weth = weth_;
        usdt = usdt_;
        uniswapV2Pair = uniswapV2Pair_;
        cETH = cETH_;
        cUSDT = cUSDT_;
        comptroller = comptroller_;
        priceFeed = priceFeed_;
        address[] memory cTokens = new address[](2);
        cTokens[0] = cETH;
        cTokens[1] = cUSDT;
        IComptroller(comptroller).enterMarkets(cTokens);
    }

    // 存入ETH
    function depositETH() external payable {
        uint256 depositAmount = msg.value;
        ICEther(cETH).mint{value: depositAmount}();
        uint256 cEthBalance = IERC20(cETH).balanceOf(address(this));
        uint256 cEthAmountGet = cEthBalance - lastCEthBalance;
        lastCEthBalance = cEthBalance;
        emit Deposit(true, depositAmount, cEthAmountGet);
    }

    // 存入USDT 
    function depositUSDT(uint256 amount) external { //onlyOwner {
        TransferHelper.safeTransferFrom(usdt, msg.sender, address(this), amount);
        IERC20(usdt).approve(cUSDT, amount);
        require(ICERC20(cUSDT).mint(amount) == 0, "mint error");
        uint256 cUsdtBalance = IERC20(cUSDT).balanceOf(address(this));
        uint256 cUsdtAmountGet = cUsdtBalance - lastCUsdtBalance;
        lastCEthBalance = cUsdtBalance;
        emit Deposit(false, amount, cUsdtAmountGet);
    }

    // 提现ETH
    function withdrawETH(uint256 cEthAmount, uint256 ethAmount) external { //onlyOwner {
        require((cEthAmount > 0 && ethAmount == 0) || (cEthAmount == 0 && ethAmount > 0),
            "one must be zero, one must be gt 0");

        if (cEthAmount > 0) {
            require(ICEther(cETH).redeem(cEthAmount) == 0, "redeem error");
        } else {
            require(ICEther(cETH).redeemUnderlying(ethAmount) == 0, "redeem error");
        }

        uint256 cTokenBalanceNew = IERC20(cETH).balanceOf(address(this));
        cEthAmount = lastCEthBalance - cTokenBalanceNew;
        lastCEthBalance = cTokenBalanceNew;
        ethAmount = address(this).balance;

        TransferHelper.safeTransferETH(msg.sender, address(this).balance);
        emit Withdraw(true, cEthAmount, ethAmount);
    }

    // 提现USDT
    function withdrawUSDT(uint256 cUsdtAmount, uint256 usdtAmount) external {
        require(
            (cUsdtAmount > 0 && usdtAmount == 0) ||
                (cUsdtAmount == 0 && usdtAmount > 0),
            "one must be zero, one must be gt 0"
        );

        if (cUsdtAmount > 0) {
            require(ICERC20(cUSDT).redeem(cUsdtAmount) == 0, "redeem error");
        } else {
            require(ICERC20(cUSDT).redeemUnderlying(usdtAmount) == 0, "redeem error");
        }

        uint256 cTokenBalanceNew = IERC20(cUSDT).balanceOf(address(this));
        cUsdtAmount = lastCUsdtBalance - cTokenBalanceNew;
        lastCUsdtBalance = cTokenBalanceNew;
        usdtAmount = IERC20(usdt).balanceOf(address(this));

        TransferHelper.safeTransfer(usdt, msg.sender, usdtAmount);
        emit Withdraw(false, cUsdtAmount, usdtAmount);
    }

    // 开多，即看涨 ETH
    function openLong(uint256 ethSize) external {
        address token0 = IUniswapV2Pair(uniswapV2Pair).token0();
        uint256 amount0Out;
        uint256 amount1Out;
        if (token0 == weth) {
            amount0Out = ethSize;
        } else {
            amount1Out = ethSize;
        }

        tempParams = TempParams(true, true, ethSize, 0, 0, 0, 0, 0);
        IUniswapV2Pair(uniswapV2Pair).swap(
            amount0Out,
            amount1Out,
            address(this),
            "0x1234"
        );
        uint256 cEthBalance = IERC20(cETH).balanceOf(address(this));
        uint256 cEthAmountGet = cEthBalance - lastCEthBalance;
        lastCEthBalance = cEthBalance;
        emit OpenLong(ethSize, cEthAmountGet, tempParams.borrowedAmount);        
        delete tempParams;
    }

    // 开空，即看跌 ETH
    function openShort(uint256 usdtSize) external {
        address token0 = IUniswapV2Pair(uniswapV2Pair).token0();
        uint256 amount0Out;
        uint256 amount1Out;
        
        if (token0 == usdt) {
            amount0Out = usdtSize;
        } else {
            amount1Out = usdtSize;
        }
        
        tempParams = TempParams(true, false, usdtSize, 0, 0, 0, 0, 0);
        IUniswapV2Pair(uniswapV2Pair).swap(
            amount0Out,
            amount1Out,
            address(this),
            "0x1234"
        );
        
        uint256 cUsdtBalance = IERC20(cUSDT).balanceOf(address(this));
        uint256 cUsdtAmountGet = cUsdtBalance - lastCUsdtBalance;
        lastCUsdtBalance = cUsdtBalance;
        emit OpenShort(usdtSize, cUsdtAmountGet, tempParams.borrowedAmount);
        delete tempParams;
    }

    // 平多
    function closeLong(uint256 usdtAmount, bool closeAll) external returns (uint256 repayAmount)
    {
        uint256 borrowBalance = ICERC20(cUSDT).borrowBalanceStored(
            address(this)
        );
        repayAmount = closeAll ? borrowBalance : usdtAmount;

        address token0 = IUniswapV2Pair(uniswapV2Pair).token0();
        uint256 amount0Out;
        uint256 amount1Out;
        if (token0 == usdt) {
            amount0Out = repayAmount;
        } else {
            amount1Out = repayAmount;
        }
        tempParams = TempParams(false, true, 0, 0, 0, 0, 0, repayAmount);
        IUniswapV2Pair(uniswapV2Pair).swap(
            amount0Out,
            amount1Out,
            address(this),
            "0x1234"
        );
        uint256 cTokenBalanceNew = IERC20(cETH).balanceOf(address(this));
        uint256 redeemedCToken = lastCEthBalance - cTokenBalanceNew;
        lastCEthBalance = cTokenBalanceNew;

        emit CloseLong(redeemedCToken, tempParams.underlyingRedeemed,
            repayAmount, closeAll);        
        delete tempParams;
    }

    // 平空
    function closeShort(uint256 ethAmount, bool closeAll)
        external returns (uint256 repayAmount)
    {
        uint256 borrowBalance = ICEther(cETH).borrowBalanceStored(
            address(this)
        );
        repayAmount = closeAll ? borrowBalance : ethAmount;

        address token0 = IUniswapV2Pair(uniswapV2Pair).token0();
        uint256 amount0Out;
        uint256 amount1Out;
        
        if (token0 == weth) {
            amount0Out = repayAmount;
        } else {
            amount1Out = repayAmount;
        }

        tempParams = TempParams(false, true, 0, 0, 0, 0, 0, repayAmount);
        IUniswapV2Pair(uniswapV2Pair).swap(
            amount0Out,
            amount1Out,
            address(this),
            "0x1234"
        );
        
        uint256 cTokenBalanceNew = IERC20(cUSDT).balanceOf(address(this));
        uint256 redeemedCToken = lastCUsdtBalance - cTokenBalanceNew;
        lastCUsdtBalance = cTokenBalanceNew;       

        emit CloseShort(redeemedCToken, tempParams.underlyingRedeemed, repayAmount, closeAll);
        delete tempParams;
    }   

    //uniswapV2的回调函数    
    function uniswapV2Call(uint256 amount0, uint256 amount1) external {
        require(msg.sender == uniswapV2Pair, "only uniswapV2Pair");

        address token0 = IUniswapV2Pair(uniswapV2Pair).token0();
        address token1 = IUniswapV2Pair(uniswapV2Pair).token1();
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(uniswapV2Pair)
            .getReserves();

        address tokenOutput;
        uint256 reserveIn;
        uint256 reserveOut;
        uint256 amountOut;

        if (amount0 > 0) {
            tokenOutput = token0;
            reserveIn = reserve1;
            reserveOut = reserve0;
            amountOut = amount0;
        } else {
            tokenOutput = token1;
            reserveIn = reserve0;
            reserveOut = reserve1;
            amountOut = amount1;
        }
        
        uint256 amountIn = _getAmountIn(amountOut, reserveIn, reserveOut);

        if (tempParams.isOpen) {
            tempParams.borrowedAmount = amountIn;
            if (tempParams.isLong) {
                IWETH(weth).withdraw(amountOut);
                ICEther(cETH).mint{value: amountOut}();
                require(ICERC20(cUSDT).borrow(amountIn) == 0, "borrow error");
                TransferHelper.safeTransfer(usdt, uniswapV2Pair, amountIn);
            } else {
                TransferHelper.safeApprove(usdt, cUSDT, amountOut);
                require(ICERC20(cUSDT).mint(amountOut) == 0, "mint error");
                require(ICEther(cETH).borrow(amountIn) == 0, "borrow error");
                IWETH(weth).deposit{value: amountIn}();
                TransferHelper.safeTransfer(weth, uniswapV2Pair, amountIn);
            }
        } else {
            tempParams.underlyingRedeemed = amountIn;
            if (tempParams.isLong) {
                TransferHelper.safeApprove(usdt, cUSDT, amountOut);
                require(
                    ICERC20(cUSDT).repayBorrow(amountOut) == 0,
                    "repay error"
                );
                require(
                    ICEther(cETH).redeemUnderlying(amountIn) == 0,
                    "redeem error"
                );
                IWETH(weth).deposit{value: amountIn}();
                TransferHelper.safeTransfer(weth, uniswapV2Pair, amountIn);
            } else {
                ICEther(cETH).repayBorrow{value: amountOut}();
                require(
                    ICERC20(cUSDT).redeemUnderlying(amountIn) == 0,
                    "redeem error"
                );
                
                TransferHelper.safeTransfer(usdt, uniswapV2Pair, amountIn);
            }
        }
    }    

    // 指定数量的代币，最多能兑换出另外一种代币的数量, 交易费千分之3
    function _getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        
        uint amountInWithFee = amountIn * 997;
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = reserveIn * 1000 + amountInWithFee;
        
        amountOut = numerator / denominator;
    }

    // 要兑换出指定数量的代币，需要另外一种代币的数量, 交易费千分之3
    function _getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) internal pure returns (uint amountIn) {
        require(amountOut > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");

        uint numerator = reserveIn * amountOut * 1000;
        uint denominator = (reserveOut - amountOut) * 997;
        
        amountIn = numerator / denominator + 1;
    }
}
