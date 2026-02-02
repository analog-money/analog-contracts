// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

interface IStrategyPassiveManagerUniswap {
    function pool() external view returns (address);
    function twapInterval() external view returns (uint32);
    function maxTickDeviation() external view returns (int56);
    function positionWidth() external view returns (int24);
    function owner() external view returns (address);
    function _tickDistance() external view returns (int24);
    function setPositionWidth(int24 _width) external;
}

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function observe(
        uint32[] calldata secondsAgos
    )
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        );
}

/**
 * Check if a deployed strategy is "calm" enough to accept config updates
 *
 * The NotCalm() error occurs when:
 * - Current pool tick deviates too far from TWAP tick (based on maxTickDeviation setting)
 *
 * To test with your deployment:
 * forge test --match-test test_check_calm --fork-url https://mainnet.base.org -vvv
 */
contract CheckStrategyCalm is Test {
    // Replace with your deployed strategy address
    // This is the strategyAddress from deployment configJson, NOT the vault address
    address constant STRATEGY_ADDRESS = address(0); // TODO: Set your strategy address here

    function test_check_calm() public view {
        if (STRATEGY_ADDRESS == address(0)) {
            console.log(
                "WARNING: STRATEGY_ADDRESS not set. Please update the test with your deployed strategy address."
            );
            return;
        }

        IStrategyPassiveManagerUniswap strategy = IStrategyPassiveManagerUniswap(
                STRATEGY_ADDRESS
            );

        // Get strategy parameters
        address poolAddress = strategy.pool();
        uint32 twapInterval = strategy.twapInterval();
        int56 maxTickDeviation = strategy.maxTickDeviation();
        int24 positionWidth = strategy.positionWidth();
        address owner = strategy.owner();

        console.log("=== Strategy Configuration ===");
        console.log("Strategy Address:", STRATEGY_ADDRESS);
        console.log("Pool Address:", poolAddress);
        console.log("Owner:", owner);
        console.log("TWAP Interval:", twapInterval);
        console.log("Max Tick Deviation:", vm.toString(maxTickDeviation));
        console.log("Position Width:", vm.toString(positionWidth));
        console.log("");

        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        // Get current tick
        (, int24 currentTick, , , , , ) = pool.slot0();
        console.log("=== Pool State ===");
        console.log("Current Tick:", vm.toString(currentTick));

        // Get TWAP tick
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapInterval;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);
        int56 twapTick = (tickCumulatives[1] - tickCumulatives[0]) /
            int56(uint56(twapInterval));
        console.log("TWAP Tick:", vm.toString(twapTick));

        // Calculate deviation
        int56 deviation = int56(currentTick) - twapTick;
        if (deviation < 0) deviation = -deviation;

        console.log("");
        console.log("=== Calm Check ===");
        console.log("Current Deviation:", vm.toString(deviation));
        console.log("Max Allowed Deviation:", vm.toString(maxTickDeviation));

        if (deviation <= maxTickDeviation) {
            console.log("SUCCESS: Pool is CALM - Config updates will succeed");
        } else {
            console.log(
                "FAIL: Pool is NOT CALM - Config updates will revert with NotCalm()"
            );
            console.log("");
            console.log("Solutions:");
            console.log(
                "1. Wait for pool to stabilize (price deviation to decrease)"
            );
            console.log(
                "2. Increase maxTickDeviation (requires owner to call setDeviation first when calm)"
            );
            console.log("3. Monitor pool and retry during stable periods");
        }
    }

    /**
     * Test attempting an update on a non-calm pool
     * This will demonstrate the revert
     */
    function test_update_during_non_calm_reverts() public {
        if (STRATEGY_ADDRESS == address(0)) {
            vm.skip(true);
            return;
        }

        IStrategyPassiveManagerUniswap strategy = IStrategyPassiveManagerUniswap(
                STRATEGY_ADDRESS
            );
        address owner = strategy.owner();

        vm.startPrank(owner);

        // This will revert if pool is not calm
        vm.expectRevert(); // Expect NotCalm() or other error
        strategy.setPositionWidth(50);

        vm.stopPrank();
    }
}
