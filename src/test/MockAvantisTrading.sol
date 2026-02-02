// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAvantisTrading} from "../interfaces/IAvantisTrading.sol";

/**
 * @title MockAvantisTrading
 * @notice Mock implementation of Avantis trading contract for testing
 * @dev Simulates perpetual position opening/closing without off-chain components
 */
contract MockAvantisTrading is IAvantisTrading {
  using SafeERC20 for IERC20;

  // === STATE ===

  address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  
  // Storage: trader => pairIndex => positionIndex => Trade
  mapping(address => mapping(uint256 => mapping(uint256 => Trade))) private trades;
  
  // Storage: trader => pairIndex => positionIndex => TradeInfo
  mapping(address => mapping(uint256 => mapping(uint256 => TradeInfo))) private tradesInfo;
  
  // Track next order ID
  uint256 private nextOrderId;

  // === EVENTS ===

  event TradeOpened(
    address indexed trader,
    uint256 indexed pairIndex,
    uint256 indexed positionIndex,
    uint256 collateral,
    uint256 leverage,
    bool buy
  );

  event TradeClosed(
    address indexed trader,
    uint256 indexed pairIndex,
    uint256 indexed positionIndex,
    uint256 pnl
  );

  // === TRADE OPERATIONS ===

  /**
   * @notice Open a new trade (simulated)
   * @param t Trade struct with all trade parameters
   * @param _type Order type enum (0 = market, etc.) - ignored in mock
   * @param _slippageP Slippage percentage (basis points) - ignored in mock
   * @return orderId Order ID for tracking
   */
  function openTrade(
    Trade calldata t,
    uint8 _type,
    uint256 _slippageP
  ) external payable override returns (uint256 orderId) {
    require(t.trader != address(0), "Invalid trader");
    require(t.positionSizeUSDC > 0, "Invalid position size");
    require(t.leverage >= 1000, "Leverage too low"); // Min 1x (1000 in 1e3 format)

    // Transfer USDC collateral from trader to this contract
    // Note: In HedgeManager, the adapter approves USDC before calling this
    IERC20(USDC).safeTransferFrom(msg.sender, address(this), t.positionSizeUSDC);

    // Calculate open fee (6 bps = 0.06% per Avantis docs)
    uint256 notionalSize = (t.positionSizeUSDC * t.leverage) / 1000;
    uint256 openFee = (notionalSize * 600000) / 1e10; // 600000 = 6 bps in 1e10 format
    
    // Transfer open fee from trader
    IERC20(USDC).safeTransferFrom(msg.sender, address(this), openFee);

    // Store trade
    trades[t.trader][t.pairIndex][t.index] = Trade({
      trader: t.trader,
      pairIndex: t.pairIndex,
      index: t.index,
      initialPosToken: t.initialPosToken,
      positionSizeUSDC: t.positionSizeUSDC,
      openPrice: t.openPrice == 0 ? 300000000000 : t.openPrice, // Use 3000 USD as default if market order
      buy: t.buy,
      leverage: t.leverage,
      tp: t.tp,
      sl: t.sl,
      timestamp: block.timestamp
    });

    tradesInfo[t.trader][t.pairIndex][t.index] = TradeInfo({
      openInterestUSDC: notionalSize,
      tpLastUpdated: 0,
      slLastUpdated: 0,
      beingMarketClosed: false
    });

    emit TradeOpened(t.trader, t.pairIndex, t.index, t.positionSizeUSDC, t.leverage, t.buy);

    return nextOrderId++;
  }

  /**
   * @notice Close trade at market price (simulated)
   * @param _pairIndex Index of the trading pair
   * @param _index Position index
   * @param _amount Amount to close (0 = close entire position) - ignored in mock, always closes full position
   * @return orderId Order ID for tracking
   */
  function closeTradeMarket(
    uint256 _pairIndex,
    uint256 _index,
    uint256 _amount
  ) external payable override returns (uint256 orderId) {
    Trade storage trade = trades[msg.sender][_pairIndex][_index];
    require(trade.trader != address(0), "Trade not found");

    // Calculate close fee (6 bps = 0.06% per Avantis docs)
    uint256 notionalSize = (trade.positionSizeUSDC * trade.leverage) / 1000;
    uint256 closeFee = (notionalSize * 600000) / 1e10;

    // For simplicity, assume no P&L (would need current price oracle in real implementation)
    // Return collateral minus close fee
    uint256 returnAmount = trade.positionSizeUSDC > closeFee 
      ? trade.positionSizeUSDC - closeFee 
      : 0;

    if (returnAmount > 0) {
      IERC20(USDC).safeTransfer(msg.sender, returnAmount);
    }

    emit TradeClosed(msg.sender, _pairIndex, _index, 0);

    // Clear trade data
    delete trades[msg.sender][_pairIndex][_index];
    delete tradesInfo[msg.sender][_pairIndex][_index];

    return nextOrderId++;
  }

  /**
   * @notice Update take profit
   */
  function updateTp(uint256 pairIndex, uint256 index, uint256 newTp) external override {
    Trade storage trade = trades[msg.sender][pairIndex][index];
    require(trade.trader != address(0), "Trade not found");
    
    trade.tp = newTp;
    tradesInfo[msg.sender][pairIndex][index].tpLastUpdated = block.timestamp;
  }

  /**
   * @notice Update stop loss
   */
  function updateSl(uint256 pairIndex, uint256 index, uint256 newSl) external override {
    Trade storage trade = trades[msg.sender][pairIndex][index];
    require(trade.trader != address(0), "Trade not found");
    
    trade.sl = newSl;
    tradesInfo[msg.sender][pairIndex][index].slLastUpdated = block.timestamp;
  }

  // === VIEW FUNCTIONS ===

  /**
   * @notice Get open trade details
   */
  function openTrades(
    address trader,
    uint256 pairIndex,
    uint256 index
  ) external view override returns (Trade memory trade) {
    return trades[trader][pairIndex][index];
  }

  /**
   * @notice Get trade info (additional details)
   */
  function openTradesInfo(
    address trader,
    uint256 pairIndex,
    uint256 index
  ) external view override returns (TradeInfo memory info) {
    return tradesInfo[trader][pairIndex][index];
  }

  /**
   * @notice Check if trade exists
   */
  function hasOpenTrade(
    address trader,
    uint256 pairIndex,
    uint256 index
  ) external view override returns (bool exists) {
    return trades[trader][pairIndex][index].trader != address(0);
  }
}
