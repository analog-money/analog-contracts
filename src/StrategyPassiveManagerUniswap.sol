// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Re-export StrategyPassiveManagerUniswap from beefy-zk for compilation
import {
    StrategyPassiveManagerUniswap
} from "beefy-zk/strategies/uniswap/StrategyPassiveManagerUniswap.sol";

/**
 * @notice NOTE: The Beefy StrategyPassiveManagerUniswap contract's initialize() function
 * does NOT set ownership to msg.sender. The owner will be address(0) after initialization.
 *
 * The server code MUST set ownership after initializing the strategy by calling transferOwnership().
 *
 * Since initialize() is not virtual, we cannot override it to set ownership automatically.
 * The deployment service should check and set ownership after strategy initialization.
 */
