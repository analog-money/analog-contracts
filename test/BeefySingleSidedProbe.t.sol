// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal interface for the Beefy conc-liq vault we are probing.
interface IBeefyConcLiqVault {
  function deposit(uint256 amount0, uint256 amount1, uint256 minShares) external;
  function balanceOf(address) external view returns (uint256);
}

contract BeefySingleSidedProbeTest is Test {
  // Target vault and tokens on Base
  address constant VAULT = 0xA20382dC7C06E7e2850f1154e7ED1D06Aeb47a0A;
  address constant TOKEN0 = 0x4200000000000000000000000000000000000006; // WETH
  address constant TOKEN1 = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC

  IBeefyConcLiqVault vault = IBeefyConcLiqVault(VAULT);

  function setUp() public {
    string memory rpcUrl = vm.envOr("BASE_HTTP_RPC_URL", string("https://mainnet.base.org"));
    vm.createSelectFork(rpcUrl);
    // Fund this test contract with ETH for gas
    vm.deal(address(this), 10 ether);
  }

  /// @notice Try depositing only USDC (amount1) with amount0 = 0.
  function test_singleSided_usdc_only() public {
    uint256 amount1 = 50 * 1e6; // 50 USDC (6 decimals)

    // Fund and approve
    deal(TOKEN1, address(this), amount1);
    IERC20(TOKEN1).approve(VAULT, amount1);

    // Attempt deposit with amount0=0, amount1=50 USDC, minShares=0
    bool ok = _tryDeposit(0, amount1);
    emit log_named_string("single-sided USDC deposit", ok ? "succeeded" : "reverted");
    if (!ok) {
      fail("Single-sided USDC deposit reverted");
    }
  }

  /// @notice Try depositing only WETH (amount0) with amount1 = 0.
  function test_singleSided_weth_only() public {
    uint256 amount0 = 0.02 ether; // small WETH amount

    // Fund and approve
    deal(TOKEN0, address(this), amount0);
    IERC20(TOKEN0).approve(VAULT, amount0);

    bool ok = _tryDeposit(amount0, 0);
    emit log_named_string("single-sided WETH deposit", ok ? "succeeded" : "reverted");
    if (!ok) {
      fail("Single-sided WETH deposit reverted");
    }
  }

  /// @notice Try depositing both legs (non-zero) to see if balanced/non-zero passes.
  function test_dualSided_small() public {
    uint256 amount0 = 0.01 ether; // WETH
    uint256 amount1 = 50 * 1e6; // USDC

    deal(TOKEN0, address(this), amount0);
    deal(TOKEN1, address(this), amount1);
    IERC20(TOKEN0).approve(VAULT, amount0);
    IERC20(TOKEN1).approve(VAULT, amount1);

    // Use preview to get expected shares and pass as minShares with a 1% buffer
    (bool okPreview, bytes memory ret) = VAULT.call(
      abi.encodeWithSignature("previewDeposit(uint256,uint256)", amount0, amount1)
    );
    uint256 minShares = 0;
    if (okPreview && ret.length >= 32) {
      (uint256 shares, , , , ) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256));
      minShares = (shares * 99) / 100; // 1% slippage tolerance
      emit log_named_uint("preview shares", shares);
    } else {
      emit log("previewDeposit failed; using minShares=0");
    }

    bool ok = _tryDepositWithMin(amount0, amount1, minShares);
    emit log_named_string("dual-sided deposit", ok ? "succeeded" : "reverted");
    if (!ok) {
      fail("Dual-sided deposit reverted");
    }
  }

  function _tryDeposit(uint256 amt0, uint256 amt1) internal returns (bool) {
    try vault.deposit(amt0, amt1, 0) {
      return true;
    } catch {
      return false;
    }
  }

  function _tryDepositWithMin(
    uint256 amt0,
    uint256 amt1,
    uint256 minShares
  ) internal returns (bool) {
    try vault.deposit(amt0, amt1, minShares) {
      return true;
    } catch {
      return false;
    }
  }

  /// @notice Call deposit directly on the implementation (proxy target) to inspect revert.
  function test_impl_dualSided_small() public {
    address impl = 0x9818dF1Bdce8D0E79B982e2C3a93ac821b3c17e0;
    uint256 amount0 = 0.01 ether;
    uint256 amount1 = 50 * 1e6;

    deal(TOKEN0, address(this), amount0);
    deal(TOKEN1, address(this), amount1);
    IERC20(TOKEN0).approve(impl, amount0);
    IERC20(TOKEN1).approve(impl, amount1);

    (bool ok, ) = impl.call(
      abi.encodeWithSignature("deposit(uint256,uint256,uint256)", amount0, amount1, 0)
    );
    emit log_named_string("impl dual-sided deposit", ok ? "succeeded" : "reverted");
    if (!ok) {
      fail("Impl dual-sided deposit reverted");
    }
  }
}









