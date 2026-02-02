// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "../lib/forge-std/src/interfaces/IERC4626.sol";
import {AnalogCurveVault} from "../src/AnalogCurveVault.sol";

/**
 * @title AnalogCurveVaultForkTest
 * @notice Fork test wiring AnalogCurveVault against the live Curve/Yearn-style
 *         scrvUSD savings vault on Base.
 *
 * Run with:
 *   forge test --match-contract AnalogCurveVaultForkTest -vvv --fork-url $BASE_HTTP_RPC_URL
 */
contract AnalogCurveVaultForkTest is Test {
  // Curve scrvUSD asset token on Base (underlying ERC4626 asset())
  address constant SCRVUSD_ASSET = 0x5aB01ee6208596f2204B85bDFA39d34c2aDD98F6;

  // Curve / scrvUSD ERC4626-style vault on Base
  // (Yearn v3-based savings vault, ERC4626-compliant)
  address constant SCRVUSD_VAULT = 0x5979ccfb613b856fFE97C9A8b80a00cD22cd2666;

  // Example user / controller
  address constant USER = address(0x2222222222222222222222222222222222222222);

  AnalogCurveVault vault;
  IERC20 assetToken;
  IERC4626 underlying;

  function setUp() public {
    // Fork Base mainnet
    string memory rpcUrl = "https://mainnet.base.org";
    try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
      rpcUrl = url;
    } catch {}
    vm.createSelectFork(rpcUrl);

    vm.label(SCRVUSD_ASSET, "SCRVUSD_ASSET");
    vm.label(SCRVUSD_VAULT, "SCRVUSD_VAULT");
    vm.label(USER, "USER");

    assetToken = IERC20(SCRVUSD_ASSET);
    underlying = IERC4626(SCRVUSD_VAULT);

    // Deploy per-user AnalogCurveVault instance wired to scrvUSD asset + vault
    vault = new AnalogCurveVault(
      USER,
      SCRVUSD_ASSET,
      SCRVUSD_VAULT,
      "Analog Curve Vault",
      "aCurve"
    );

    vm.label(address(vault), "ANALOG_CURVE_VAULT");
  }

  function test_vault_wiring() public view {
    // Basic sanity checks on configuration
    assertEq(vault.owner(), USER, "owner should be USER");
    assertEq(vault.want(), SCRVUSD_ASSET, "want() should be scrvUSD asset");
    assertEq(vault.asset(), SCRVUSD_ASSET, "asset() should be scrvUSD asset");
    assertEq(vault.vault(), SCRVUSD_VAULT, "vault() should be wired to scrvUSD ERC4626 vault");
  }

  function test_deposit_and_withdraw_asset() public {
    uint256 depositAmount = 1_000e18; // 1000 scrvUSD (18 decimals)

    // Give USER some scrvUSD on the fork
    deal(SCRVUSD_ASSET, USER, depositAmount, true);

    uint256 userBefore = assetToken.balanceOf(USER);
    assertEq(userBefore, depositAmount, "user should start with scrvUSD");

    // Deposit into AnalogCurveVault
    vm.startPrank(USER);
    assetToken.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    // User should now hold shares and scrvUSD should sit in the vault (idle)
    uint256 shares = vault.balanceOf(USER);
    assertEq(shares, depositAmount, "shares should equal deposited scrvUSD");
    uint256 vaultBal = assetToken.balanceOf(address(vault));
    assertEq(vaultBal, depositAmount, "vault should hold deposited scrvUSD");

    // Withdraw back to scrvUSD (no interaction with underlying vault yet)
    vm.startPrank(USER);
    vault.withdraw(shares);
    vm.stopPrank();

    uint256 userAfter = assetToken.balanceOf(USER);
    uint256 vaultAfter = assetToken.balanceOf(address(vault));

    assertEq(userAfter, depositAmount, "user should get scrvUSD back on withdraw");
    assertEq(vaultAfter, 0, "vault should have no scrvUSD after withdraw");
  }

  function test_invest_and_divest_underlying_vault() public {
    uint256 depositAmount = 1_000e18; // 1000 scrvUSD

    // Give USER some scrvUSD and deposit into AnalogCurveVault
    deal(SCRVUSD_ASSET, USER, depositAmount, true);

    vm.startPrank(USER);
    assetToken.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    // Controller is initially USER (per constructor)
    assertEq(vault.controller(), USER, "controller should start as USER");

    // Invest idle scrvUSD into underlying vault as controller
    uint256 vaultBalBefore = assetToken.balanceOf(address(vault));
    assertEq(vaultBalBefore, depositAmount, "all scrvUSD should be idle in vault");

    uint256 underlyingSharesBefore = underlying.balanceOf(address(vault));

    vm.startPrank(USER);
    // amount = 0 -> invest full idle balance, minSharesOut = 0 for lenient test
    vault.invest(0, 0);
    vm.stopPrank();

    uint256 vaultBalAfterInvest = assetToken.balanceOf(address(vault));
    uint256 underlyingSharesAfter = underlying.balanceOf(address(vault));

    // After invest, scrvUSD in wrapper should decrease and we should hold some underlying shares
    assertLt(vaultBalAfterInvest, vaultBalBefore, "vault scrvUSD should decrease after invest");
    assertGt(
      underlyingSharesAfter,
      underlyingSharesBefore,
      "vault should hold underlying shares after invest"
    );

    // Now divest back to scrvUSD using all underlying shares
    uint256 scrvBeforeDivest = assetToken.balanceOf(address(vault));

    vm.startPrank(USER);
    vault.divest(0, 0); // shares=0 -> redeem full balance, minUsdcOut=0 for lenient test
    vm.stopPrank();

    uint256 scrvAfterDivest = assetToken.balanceOf(address(vault));
    uint256 underlyingSharesAfterDivest = underlying.balanceOf(address(vault));

    assertGt(scrvAfterDivest, scrvBeforeDivest, "vault scrvUSD should increase after divest");
    assertEq(
      underlyingSharesAfterDivest,
      0,
      "vault should have no underlying shares after full divest"
    );
  }
}









