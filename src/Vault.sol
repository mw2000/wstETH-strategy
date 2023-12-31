// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';

// Interfaces for Lido and Compound
interface ILido {
    function submit(address _referral) external payable returns (uint256);
}

interface IWstEth {
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function unwrap(uint256 _wstETHAmount) external returns (uint256);
}

interface ICompound {
    function mint() external payable;
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow() external payable;
}

interface CTokenInterface {
    function getAccountSnapshot(address account) external view returns (uint, uint, uint, uint);
}

interface IWEth {
    function withdraw(uint wad) external;
}


contract Vault is ERC4626 {
    uint256 public leverageRatio;
    address public manager;
    ILido public lido;
    ICompound public compound;
    IWstEth public wstEth;
    IWEth public wEth;
    address public uniswapRouterAddress;
    address public cEthAddress;

    constructor(
        address _wstEthAddress, 
        uint256 _leverageRatio,
        address _manager,
        address _lidoAddress,
        address _compoundAddress,
        address _cEthAddress,
        address _uniswapRouterAddress,
        address _wEthAddress
    ) 
        ERC4626(IERC20(_wstEthAddress))
        ERC20("Vault", "VLT") 
    {
        leverageRatio = _leverageRatio;
        manager = _manager;
        lido = ILido(_lidoAddress);
        compound = ICompound(_compoundAddress);
        wstEth = IWstEth(_wstEthAddress);
        cEthAddress = _cEthAddress;
        uniswapRouterAddress = _uniswapRouterAddress;
        wEth = IWEth(_wEthAddress);
    }

    function setManager(address _manager) public {
        require(msg.sender == manager, "Only existing manager can set a new manager");
        manager = _manager;
    }

    function setLeverageRatio(uint256 _leverageRatio) public {
        require(msg.sender == manager, "Only  manager can set leverage ratio");
        leverageRatio = _leverageRatio;
    }

    function harvest() public {
        require(msg.sender == manager, "Only manager can call harvest function");

        uint256 currentBorrowed = getCurrentBorrowedAmount();

        // Calculate the target leverage
        uint256 totalAssets = IERC20(address(wstEth)).balanceOf(address(this)); // total wstETH in the vault
        uint256 targetBorrowed = (totalAssets * leverageRatio) / 100;

        if (currentBorrowed < targetBorrowed) {
            // Increase leverage
            uint256 amountToBorrow = targetBorrowed - currentBorrowed;
            
            // Borrow ETH from Compound
            compound.borrow(amountToBorrow);

            // Convert borrowed ETH to wstETH via Lido
            // Assuming Lido's `submit` returns stETH
            uint256 stETHAmount = lido.submit{value: amountToBorrow}(address(0));
            // WST eth is wrapped
            wstEth.wrap(stETHAmount);
            // Now you have increased your wstETH holdings, thus increasing leverage
        } else if (currentBorrowed > targetBorrowed) {
            // Decrease leverage
            uint256 amountToRepay = currentBorrowed - targetBorrowed;

            // Trade wstETH to ETH on uniswap
            uint256 ethAmount = convertWstEthToEth(amountToRepay);

            // Repay ETH loan to Compound
            compound.repayBorrow{value: ethAmount}();
        }
    }


    function convertWstEthToEth(uint256 wstEthAmount) private returns (uint256) {
        ISwapRouter uniswapRouter = ISwapRouter(uniswapRouterAddress);

        // Approve the Uniswap Router to spend wstEth
        IERC20(address(wstEth)).approve(uniswapRouterAddress, wstEthAmount);

        // Set up the parameters for the swap
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(wstEth),
            tokenOut: address(wEth),
            fee: 3000, 
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: wstEthAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        // Execute the swap
        uint256 amountOut = uniswapRouter.exactInputSingle(params);
        convertWethToEth(amountOut);
        return amountOut;
    }


    function getCurrentBorrowedAmount() private view returns (uint256) {
        CTokenInterface cEth = CTokenInterface(cEthAddress);
        (, uint256 cTokenBalance, uint256 borrowBalance, uint256 exchangeRateMantissa) = cEth.getAccountSnapshot(address(this));
        return borrowBalance;
    }

    function convertWethToEth(uint256 wethAmount) private {
        // Approve the WETH contract to spend WETH
        IERC20(address(wEth)).approve(address(wEth), wethAmount);

        // Convert WETH to ETH
        wEth.withdraw(wethAmount);
    }

    receive() external payable {}
}


