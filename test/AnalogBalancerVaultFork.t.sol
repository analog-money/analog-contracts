// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AnalogBalancerVault} from "../src/AnalogBalancerVault.sol";
import {SwapCall} from "../src/libraries/SwapExecutor.sol";

// Minimal subset of Balancer v3 Vault extension types used for introspection
struct TokenInfo {
  uint8 tokenType;
  address rateProvider;
  bool paysYieldFees;
}

interface IBalancerV3VaultExtension {
  function getPoolTokenInfo(
    address pool
  )
    external
    view
    returns (
      IERC20[] memory tokens,
      TokenInfo[] memory tokenInfo,
      uint256[] memory balancesRaw,
      uint256[] memory lastBalancesLiveScaled18
    );
}

/**
 * @title AnalogBalancerVaultForkTest
 * @notice Fork test wiring AnalogBalancerVault against a live Balancer Vault and real pool on Base.
 *
 * Run with:
 *   forge test --match-contract AnalogBalancerVaultForkTest -vvv --fork-url $BASE_HTTP_RPC_URL
 */
contract AnalogBalancerVaultForkTest is Test {
  // Base mainnet USDC
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

  // Balancer v3 Vault on Base for the referenced pool
  address constant BALANCER_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;

  // Balancer v3 Router on Base (trusted by the Vault)
  address constant BALANCER_ROUTER = 0x3f170631ed9821Ca51A59D996aB095162438DC10;

  // Pool address (also BPT token) for the referenced v3 StablePool
  address constant BALANCER_POOL = 0x7AB124EC4029316c2A42F713828ddf2a192B36db;

  // Pool token config discovered from the live Balancer v3 Vault
  address token0;
  address token1;
  uint256 poolBal0;
  uint256 poolBal1;

  // 1inch router on Base (for SwapExecutor; not exercised directly in this test)
  address constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

  address constant USER = address(0x2222222222222222222222222222222222222222);

  AnalogBalancerVault vault;

  function setUp() public {
    // Fork Base mainnet
    string memory rpcUrl = "https://mainnet.base.org";
    try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
      rpcUrl = url;
    } catch {}
    vm.createSelectFork(rpcUrl);

    vm.label(USDC, "USDC");
    vm.label(BALANCER_VAULT, "BALANCER_VAULT");
    vm.label(BALANCER_ROUTER, "BALANCER_ROUTER");
    vm.label(BALANCER_POOL, "BALANCER_POOL");
    vm.label(ONEINCH_ROUTER, "ONEINCH_ROUTER");
    vm.label(USER, "USER");

    // Discover actual pool tokens and raw balances from the live Balancer v3 Vault.
    (IERC20[] memory tokens, , uint256[] memory balancesRaw, ) = IBalancerV3VaultExtension(
      BALANCER_VAULT
    ).getPoolTokenInfo(BALANCER_POOL);
    require(tokens.length == 2, "expected 2-token pool");
    token0 = address(tokens[0]);
    token1 = address(tokens[1]);
    poolBal0 = balancesRaw[0];
    poolBal1 = balancesRaw[1];

    // Deploy per-user AnalogBalancerVault instance
    vault = new AnalogBalancerVault(
      USER,
      USDC,
      BALANCER_VAULT,
      BALANCER_ROUTER,
      BALANCER_POOL,
      token0,
      token1,
      ONEINCH_ROUTER,
      "Analog Balancer Vault",
      "aBAL"
    );

    vm.label(address(vault), "ANALOG_BALANCER_VAULT");
  }

  function test_vault_wiring() public view {
    // Basic sanity checks on configuration
    assertEq(vault.owner(), USER, "owner should be USER");
    assertEq(vault.want(), USDC, "want() should be USDC");
    (address t0, address t1) = vault.wants();
    assertEq(t0, token0, "token0 should match configured token0");
    assertEq(t1, token1, "token1 should match configured token1");
    assertEq(
      vault.balancerVault(),
      BALANCER_VAULT,
      "balancerVault should be wired to provided address"
    );
  }

  function test_deposit_and_withdraw_usdc() public {
    uint256 depositAmount = 1_000e6; // 1000 USDC

    // Give USER some USDC on the fork
    deal(USDC, USER, depositAmount, true);

    IERC20 usdc = IERC20(USDC);
    uint256 userBefore = usdc.balanceOf(USER);
    assertEq(userBefore, depositAmount, "user should start with USDC");

    // Deposit into AnalogBalancerVault
    vm.startPrank(USER);
    usdc.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    // User should now hold shares and USDC should sit in the vault
    uint256 shares = vault.balanceOf(USER);
    assertEq(shares, depositAmount, "shares should equal deposited USDC");
    uint256 vaultUsdc = usdc.balanceOf(address(vault));
    assertEq(vaultUsdc, depositAmount, "vault should hold deposited USDC");

    // Withdraw back to USDC (no Balancer interactions yet)
    vm.startPrank(USER);
    vault.withdraw(shares);
    vm.stopPrank();

    uint256 userAfter = usdc.balanceOf(USER);
    uint256 vaultAfter = usdc.balanceOf(address(vault));

    assertEq(userAfter, depositAmount, "user should get USDC back on withdraw");
    assertEq(vaultAfter, 0, "vault should have no USDC after withdraw");
  }

  function test_full_join_and_exit_real_balancer_pool() public {
    // Use a small proportional share of existing pool balances as input amounts.
    uint256 amount0 = poolBal0 / 1_000_000;
    uint256 amount1 = poolBal1 / 1_000_000;
    if (amount0 == 0) amount0 = 1;
    if (amount1 == 0) amount1 = 1;

    // Fund the vault directly with pool tokens to simulate pre-swapped balances.
    deal(token0, address(vault), amount0, true);
    deal(token1, address(vault), amount1, true);

    // Controller is initialized to owner (USER), so we prank as USER.
    vm.startPrank(USER);

    // Invest into Balancer v3 pool using the live Vault.
    SwapCall[] memory noSwaps = new SwapCall[](0);
    vault.invest(noSwaps, 0, 0, 0);

    vm.stopPrank();

    uint256 bptBalance = IERC20(BALANCER_POOL).balanceOf(address(vault));
    assertGt(bptBalance, 0, "vault should hold BPT after invest");

    // Now divest the entire BPT position back to pool tokens.
    uint256[] memory minAmountsOut = new uint256[](2);

    vm.prank(USER);
    vault.divest(bptBalance, minAmountsOut, noSwaps);

    uint256 bal0After = IERC20(token0).balanceOf(address(vault));
    uint256 bal1After = IERC20(token1).balanceOf(address(vault));

    assertGt(bal0After, 0, "vault should hold token0 after divest");
    assertGt(bal1After, 0, "vault should hold token1 after divest");
  }
}









