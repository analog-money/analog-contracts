// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/**
 * @title MockChainlinkFeed
 * @notice Mock Chainlink price feed for testing
 */
contract MockChainlinkFeed is AggregatorV3Interface {
  uint8 public constant override decimals = 8;
  string public constant override description = "ETH / USD";
  uint256 public constant override version = 1;

  int256 public price; // Price in 8 decimals (e.g., 3500e8 = $3500)

  constructor(int256 _initialPrice) {
    price = _initialPrice;
  }

  function setPrice(int256 _price) external {
    price = _price;
  }

  function getRoundData(
    uint80 _roundId
  )
    external
    view
    override
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    )
  {
    return (_roundId, price, block.timestamp, block.timestamp, _roundId);
  }

  function latestRoundData()
    external
    view
    override
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    )
  {
    return (1, price, block.timestamp, block.timestamp, 1);
  }
}




