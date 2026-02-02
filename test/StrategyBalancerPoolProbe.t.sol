// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

interface IStrategyBalancerV3Like {
  function want() external view returns (address);
}

interface IBalancerPoolId {
  function getPoolId() external view returns (bytes32);
}

interface IBalancerVaultTokens {
  function getPoolTokens(
    bytes32 poolId
  )
    external
    view
    returns (address[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock);
}

contract StrategyBalancerPoolProbeTest is Test {
  // Beefy StrategyBalancerV3 proxy on Base (from BaseScan)
  address constant STRATEGY = 0x7F6579A877136d1Eb6b417743c035560446Dc092;

  // Canonical Balancer Vault on Base
  address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

  function setUp() public {
    string memory rpcUrl = "https://mainnet.base.org";
    try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
      rpcUrl = url;
    } catch {}
    vm.createSelectFork(rpcUrl);
  }

  function test_probe_strategy_balancer_pool() public view {
    // Read BPT (want) from strategy
    address bpt = IStrategyBalancerV3Like(STRATEGY).want();

    // Read poolId from pool contract
    bytes32 poolId = IBalancerPoolId(bpt).getPoolId();

    // Read pool tokens from Balancer Vault
    (address[] memory tokens, uint256[] memory balances, ) = IBalancerVaultTokens(BALANCER_VAULT)
      .getPoolTokens(poolId);

    console.log("Strategy:", STRATEGY);
    console.log("BPT (pool address):", bpt);
    console.logBytes32(poolId);
    console.log("Token count:", tokens.length);
    for (uint256 i = 0; i < tokens.length; i++) {
      console.log("token  ", tokens[i]);
      console.log("balance", balances[i]);
    }

    // Light sanity checks
    require(tokens.length >= 2, "expected at least 2 pool tokens");
  }
}









