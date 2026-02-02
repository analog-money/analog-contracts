// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Test strategy implementation based on StrategyPassiveManagerUniswap
// This is a wrapper that allows us to register it in StrategyFactory for testing
import {
    StrategyPassiveManagerUniswap
} from "beefy-zk/strategies/uniswap/StrategyPassiveManagerUniswap.sol";

/**
 * @title TestStrategyPassiveManagerUniswap
 * @notice Test strategy wrapper for StrategyPassiveManagerUniswap
 * @dev This is identical to StrategyPassiveManagerUniswap but allows us to register it separately
 *      in the StrategyFactory for testing purposes
 */
contract TestStrategyPassiveManagerUniswap is StrategyPassiveManagerUniswap {}






