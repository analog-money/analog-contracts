// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    StrategyPassiveManagerUniswap as BeefyStrategy
} from "beefy-zk/strategies/uniswap/StrategyPassiveManagerUniswap.sol";

/**
 * @notice Analog override of Beefy's StrategyPassiveManagerUniswap.
 *
 * Changes from upstream:
 * - moveTicks() removes the onlyRebalancers modifier so that the vault (owner)
 *   can call it directly without being registered in the StrategyFactory's
 *   rebalancers mapping. This keeps the system non-custodial: each vault can
 *   rebalance its own strategy without depending on a factory admin.
 *   The onlyCalmPeriods check is preserved.
 */
contract StrategyPassiveManagerUniswap is BeefyStrategy {
    /// @notice Override moveTicks to remove onlyRebalancers (factory dependency).
    /// The vault (strategy owner) calls this via rebalanceAMM(). Auth is enforced
    /// by the vault's onlyController modifier — no factory lookup needed.
    function moveTicks() external virtual override onlyCalmPeriods {
        _moveTicks();
    }
}
