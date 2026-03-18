// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseVault} from "./BaseVault.sol";
import {IStrategyConcLiq} from "beefy-zk/interfaces/beefy/IStrategyConcLiq.sol";
import {PoolSwapExecutor} from "./libraries/PoolSwapExecutor.sol";

interface IAnalogVaultFactory {
    function latestImplementation() external view returns (address);
    function strategyFactory() external view returns (address);
}

interface IStrategyFactory {
    function getImplementation(string calldata name) external view returns (address);
}

interface IUUPS {
    function upgradeToLatest() external;
    function getImplementation() external view returns (address);
}

interface IStrategyConfig {
  function setPositionWidth(int24 _width) external;
  function setDeviation(int56 _maxDeviation) external;
  function setTwapInterval(uint32 _interval) external;
}

interface IStrategyRewardPool {
  function setRewardPool(address _rewardPool) external;
}

/**
 * @title AnalogVault
 * @notice Non-hedged vault that delegates AMM management to StrategyPassiveManagerUniswap
 * @dev Token-agnostic: works with any X/USDC pool. Pool address and price come from strategy.
 *      Single implementation for all pool pairs (ETH/USDC, BTC/USDC, etc.).
 */
contract AnalogVault is BaseVault {
  using SafeERC20 for IERC20;

  // === STATE ===
  IStrategyConcLiq public strategy;
  address public factory;

  // === CONFIG STATE ===
  // changeType: 0=None, 1=PositionWidth, 2=Deviation, 3=TwapInterval
  struct PendingConfig {
    uint8 changeType;
    int256 value;
    bool isPending;
  }
  PendingConfig public pendingConfig;

  // === ERRORS ===
  error InvalidStrategy();
  error InvalidConfig();
  error ConfigPending();
  error NoConfig();
  error NotAuthorized();

  // === EVENTS ===
  event ConfigQueued(uint8 indexed changeType, int256 value);
  event ConfigExec(uint8 indexed changeType, int256 value);
  event WithdrawFromAMMFailed();

  // === CONSTRUCTOR ===
  constructor(address _usdc) BaseVault(_usdc) {}

  // === INITIALIZER ===

  /// @notice Initialize a new vault proxy
  function initialize(
    address _owner,
    address _controller,
    address _strategy
  ) external initializer {
    BaseVault.initialize(_owner, _controller);
    if (_strategy == address(0)) revert InvalidStrategy();
    strategy = IStrategyConcLiq(_strategy);
    factory = msg.sender;
  }

  // === VIEWS ===

  function wants() external view returns (address token0, address token1) {
    if (address(strategy) != address(0)) {
      return (strategy.lpToken0(), strategy.lpToken1());
    }
    return (address(0), address(0));
  }

  function balances() external view override returns (uint256 amount0, uint256 amount1) {
    return _balances();
  }

  function _balances() internal view returns (uint256 amount0, uint256 amount1) {
    (amount0, amount1) = strategy.balances();
    address token0 = strategy.lpToken0();
    address token1 = strategy.lpToken1();
    amount0 += IERC20(token0).balanceOf(address(this));
    amount1 += IERC20(token1).balanceOf(address(this));
  }

  /// @notice Total vault equity in USDC terms using pool spot price
  /// @dev strategy.price() returns price of token0 in token1, scaled by 1e36
  function getVaultEquity() public view override returns (uint256) {
    (uint256 amt0, uint256 amt1) = _balances();
    if (amt0 == 0 && amt1 == 0) return 0;
    uint256 price = strategy.price();
    if (price == 0) return 0;
    if (strategy.lpToken0() == USDC) {
      return amt0 + (amt1 * 1e36) / price;
    } else {
      return amt1 + (amt0 * price) / 1e36;
    }
  }

  // === AMM IMPLEMENTATION ===

  function _deployToAMM(uint256 usdcAmount) internal override returns (uint256 amount0, uint256 amount1) {
    address token0 = strategy.lpToken0();
    address token1 = strategy.lpToken1();
    address otherToken = token0 == USDC ? token1 : token0;
    uint256 otherBalance = IERC20(otherToken).balanceOf(address(this));
    uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
    if (usdcBalance > usdcAmount) usdcBalance = usdcAmount;

    if (token0 == USDC) { amount0 = usdcBalance; amount1 = otherBalance; }
    else { amount0 = otherBalance; amount1 = usdcBalance; }
    if (amount0 == 0 && amount1 == 0) return (0, 0);

    strategy.beforeAction();
    if (amount0 > 0) IERC20(token0).safeTransfer(address(strategy), amount0);
    if (amount1 > 0) IERC20(token1).safeTransfer(address(strategy), amount1);
    strategy.deposit();
  }

  function _withdrawFromAMM(uint256 usdcAmount) internal override returns (uint256 amount0, uint256 amount1) {
    strategy.beforeAction();
    (uint256 bal0, uint256 bal1) = strategy.balances();
    if (bal0 == 0 && bal1 == 0) return (0, 0);

    uint256 totalValue = _getAMMPositionValue();
    if (totalValue == 0) return (0, 0);
    if (usdcAmount > totalValue) usdcAmount = totalValue;

    uint256 withdraw0 = (bal0 * usdcAmount) / totalValue;
    uint256 withdraw1 = (bal1 * usdcAmount) / totalValue;

    address token0 = strategy.lpToken0();
    address token1 = strategy.lpToken1();
    uint256 bal0Before = IERC20(token0).balanceOf(address(this));
    uint256 bal1Before = IERC20(token1).balanceOf(address(this));
    strategy.withdraw(withdraw0, withdraw1);
    amount0 = IERC20(token0).balanceOf(address(this)) - bal0Before;
    amount1 = IERC20(token1).balanceOf(address(this)) - bal1Before;
  }

  function _calculateAMMDelta() internal view override returns (uint256) {
    (uint256 bal0, uint256 bal1) = strategy.balances();
    if (bal0 == 0 && bal1 == 0) return 0;
    // Return non-USDC token balance
    return strategy.lpToken0() == USDC ? bal1 : bal0;
  }

  function _rebalanceAMM() internal override {
    (uint256 bal0, uint256 bal1) = strategy.balances();
    if (bal0 == 0 && bal1 == 0) return;
    if (!strategy.isCalm()) return;

    strategy.beforeAction();
    address token0 = strategy.lpToken0();
    address token1 = strategy.lpToken1();
    uint256 b0 = IERC20(token0).balanceOf(address(this));
    uint256 b1 = IERC20(token1).balanceOf(address(this));

    try strategy.withdraw(bal0, bal1) {} catch { return; }
    uint256 r0 = IERC20(token0).balanceOf(address(this)) - b0;
    uint256 r1 = IERC20(token1).balanceOf(address(this)) - b1;
    if (r0 > 0) IERC20(token0).safeTransfer(address(strategy), r0);
    if (r1 > 0) IERC20(token1).safeTransfer(address(strategy), r1);
    strategy.deposit();
  }

  function _harvestFees() internal override returns (uint256 fees0, uint256 fees1) {
    strategy.beforeAction();
    strategy.deposit();
    return (0, 0);
  }

  function _withdrawAllFromAMM() internal override {
    (uint256 bal0, uint256 bal1) = strategy.balances();
    if (bal0 == 0 && bal1 == 0) return;
    strategy.beforeAction();
    try strategy.withdraw(bal0, bal1) {} catch {
      emit WithdrawFromAMMFailed();
    }
  }

  function _getAMMPositionValue() internal view override returns (uint256) {
    (uint256 bal0, uint256 bal1) = strategy.balances();
    if (bal0 == 0 && bal1 == 0) return 0;
    uint256 price = strategy.price();
    if (price == 0) return 0;
    if (strategy.lpToken0() == USDC) {
      return bal0 + (bal1 * 1e36) / price;
    } else {
      return bal1 + (bal0 * price) / 1e36;
    }
  }

  function _getUnclaimedFees() internal pure override returns (uint256) { return 0; }

  /// @notice Swap any non-USDC token held by the vault to USDC via the pool.
  function _swapAllToUSDC() internal override {
    address token0 = strategy.lpToken0();
    address otherToken = token0 == USDC ? strategy.lpToken1() : token0;
    uint256 balance = IERC20(otherToken).balanceOf(address(this));
    PoolSwapExecutor.swapExactIn(strategy.pool(), otherToken, balance);
  }

  /// @notice Uniswap V3 / Aerodrome Slipstream swap callback.
  function uniswapV3SwapCallback(
    int256 amount0Delta,
    int256 amount1Delta,
    bytes calldata
  ) external {
    PoolSwapExecutor.handleCallback(strategy.pool(), amount0Delta, amount1Delta);
  }

  // === VIEW OVERRIDES ===

  function getPendingStates() external view override returns (
    uint256 depositAmount,
    bool depositPending,
    uint256 withdrawalAmount,
    bool withdrawalPending,
    uint256 swapToken0,
    uint256 swapToken1,
    address swapRecipient,
    bool swapPending,
    uint256 deployAmount0,
    uint256 deployAmount1,
    bool deployPending,
    uint8 configType,
    int256 configValue,
    bool configPending
  ) {
    depositAmount = pending.depositAmount;
    depositPending = (pending.flags & 0x01) != 0;
    withdrawalAmount = pending.withdrawAmount;
    withdrawalPending = (pending.flags & 0x02) != 0;
    configType = pendingConfig.changeType;
    configValue = pendingConfig.value;
    configPending = pendingConfig.isPending;
  }

  // === CONFIGURATION MANAGEMENT ===

  function queueConfigChange(uint8 changeType, int256 value) external onlyOwner {
    if (changeType == 0) revert InvalidConfig();
    if (pendingConfig.isPending) revert ConfigPending();
    pendingConfig = PendingConfig(changeType, value, true);
    emit ConfigQueued(changeType, value);
  }

  function executeConfigChange() external onlyController {
    if (!pendingConfig.isPending) revert NoConfig();
    uint8 typ = pendingConfig.changeType;
    int256 val = pendingConfig.value;
    if (typ == 1 && !strategy.isCalm()) revert NotCalm();
    delete pendingConfig;
    IStrategyConfig cfg = IStrategyConfig(address(strategy));
    if (typ == 1) {
      if (val < type(int24).min || val > type(int24).max) revert InvalidConfig();
      cfg.setPositionWidth(int24(val));
    } else if (typ == 2) {
      if (val < type(int56).min || val > type(int56).max) revert InvalidConfig();
      cfg.setDeviation(int56(val));
    } else if (typ == 3) {
      if (val < 0 || uint256(val) > type(uint32).max) revert InvalidConfig();
      cfg.setTwapInterval(uint32(uint256(val)));
    }
    emit ConfigExec(typ, val);
  }

  // === STRATEGY ADMIN (controller-only) ===

  /// @notice Set the reward pool on the strategy. Required for Aerodrome strategies
  ///         where harvest() calls IRewardPool(rewardPool).notifyRewardAmount().
  ///         Without a valid reward pool, harvest reverts.
  function setStrategyRewardPool(address _rewardPool) external onlyController {
    IStrategyRewardPool(address(strategy)).setRewardPool(_rewardPool);
  }

  // === UPGRADE LOGIC ===

  function _authorizeUpgrade(address impl) internal view override {
    address latest = IAnalogVaultFactory(factory).latestImplementation();
    if (impl != latest || impl == address(0)) revert InvalidStrategy();
    if (msg.sender != owner()) revert NotAuthorized();
  }

  function upgradeToLatest() external onlyOwner {
    IAnalogVaultFactory fact = IAnalogVaultFactory(factory);
    address latestVault = fact.latestImplementation();
    if (latestVault != address(0) && latestVault != _getImplementation()) {
        _upgradeToAndCall(latestVault, new bytes(0), false);
    }
    try fact.strategyFactory() returns (address stratFactory) {
        if (stratFactory != address(0)) {
            try IStrategyFactory(stratFactory).getImplementation("StrategyPassiveManagerUniswap") returns (address) {
                try IUUPS(address(strategy)).upgradeToLatest() {} catch {}
            } catch {}
        }
    } catch {}
  }
}
