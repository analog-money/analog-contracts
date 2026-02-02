// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockHarvestVault is ERC20, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public assetToken;
    uint256 public sharePrice; // Scaled by 1e18. Start with 1e18.

    constructor(address _asset) ERC20("Mock Harvest", "mfHARVEST") {
        assetToken = IERC20(_asset);
        sharePrice = 1e18; // 1.0 Share Price
        _transferOwnership(msg.sender);
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    // Mock implementation of assetsOf
    // assets = shares * sharePrice / 1e18
    function assetsOf(address user) external view returns (uint256) {
        return (balanceOf(user) * sharePrice) / 1e18;
    }
    
    function deposit(uint256 assets, address receiver) external returns (uint256) {
        assetToken.safeTransferFrom(msg.sender, address(this), assets);
        // Mint shares based on current price
        // shares = assets * 1e18 / sharePrice
        uint256 shares = (assets * 1e18) / sharePrice;
        _mint(receiver, shares);
        return shares;
    }
    
    // Simulate Profit: Increase share price
    // e.g. increase by 10% -> sharePrice = sharePrice * 110 / 100
    // Input is in BPS (10000 = 100%)
    function simulateProfit(uint256 percentageBps) external {
        sharePrice = (sharePrice * (10000 + percentageBps)) / 10000;
    }
}

contract MockToken is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 100000000 * 1e18);
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
