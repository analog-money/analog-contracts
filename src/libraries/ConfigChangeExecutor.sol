// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IStrategyConfig {
    function setPositionWidth(int24 _width) external;
    function setDeviation(int56 _maxDeviation) external;
    function setTwapInterval(uint32 _interval) external;
}

library ConfigChangeExecutor {
    enum ConfigChangeType { None, PositionWidth, Deviation, TwapInterval }

    error Invalid();

    /// @notice Execute a queued config change on the strategy
    /// @param strategy Address of the strategy contract
    /// @param changeType Type of config change
    /// @param value Value for the config change
    function executeChange(
        address strategy,
        ConfigChangeType changeType,
        int256 value
    ) internal {
        if (changeType == ConfigChangeType.PositionWidth) {
            IStrategyConfig(strategy).setPositionWidth(int24(value));
        } else if (changeType == ConfigChangeType.Deviation) {
            IStrategyConfig(strategy).setDeviation(int56(value));
        } else if (changeType == ConfigChangeType.TwapInterval) {
            IStrategyConfig(strategy).setTwapInterval(uint32(uint256(value)));
        } else {
            revert Invalid();
        }
    }
}
