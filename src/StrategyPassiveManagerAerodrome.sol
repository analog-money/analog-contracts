// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Re-export StrategyPassiveManagerVelodrome from beefy-zk as our Aerodrome strategy.
// Aerodrome is a Velodrome fork on Base — same contracts, same interfaces.
import {
    StrategyPassiveManagerVelodrome
} from "beefy-zk/strategies/velodrome/StrategyPassiveManagerVelodrome.sol";

/**
 * @title StrategyPassiveManagerAerodrome
 * @notice Aerodrome (Velodrome-fork) passive CL position manager.
 *
 * This is a direct re-export of beefy-zk's StrategyPassiveManagerVelodrome.
 * Key differences from the Uniswap variant:
 * - Positions tracked as NFTs staked in Aerodrome CLGauge
 * - Harvest claims AERO rewards from gauge, charges fees, forwards to RewardPool
 * - Initialize takes (pool, quoter, nftManager, gauge, rewardPool, output, width, paths[], commonAddresses)
 */
contract StrategyPassiveManagerAerodrome is StrategyPassiveManagerVelodrome {}
