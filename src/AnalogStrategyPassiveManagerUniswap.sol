// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    StrategyPassiveManagerUniswap
} from "beefy-zk/strategies/uniswap/StrategyPassiveManagerUniswap.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IAnalogStrategyFactory {
    function latestImplementation(string calldata strategyName) external view returns (address);
}

/**
 * @title AnalogStrategyPassiveManagerUniswap
 * @notice UUPS Upgradeable version of Beefy's StrategyPassiveManagerUniswap
 */
contract AnalogStrategyPassiveManagerUniswap is StrategyPassiveManagerUniswap, UUPSUpgradeable {
    
    /**
     * @notice Authorize upgrade (UUPS pattern)
     * @dev Checks against the factory's latest implementation for this strategy name
     */
    function _authorizeUpgrade(address newImplementation) internal view override {
        // We assume the factory address is stored in the base contract's 'factory' variable
        address factoryLatest = IAnalogStrategyFactory(address(factory)).latestImplementation("StrategyPassiveManagerUniswap");
        require(newImplementation == factoryLatest, "Invalid implementation");
    }

    /**
     * @notice Helper to upgrade to the latest version signaled by the factory
     */
    function upgradeToLatest() external onlyOwner {
        address latest = IAnalogStrategyFactory(address(factory)).latestImplementation("StrategyPassiveManagerUniswap");
        require(latest != address(0), "No implementation signaled");
        
        _upgradeToAndCall(latest, new bytes(0), false);
    }
}
