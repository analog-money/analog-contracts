// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
  IERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/**
 * @title IHedgedVault
 * @notice Interface for perpetual-hedged AMM vaults
 * @dev Replaced ERC4626 with simple Vault Ops
 */
interface IHedgedVault is IERC20Upgradeable {
  // === STRUCTS ===

  struct HedgePosition {
    bool isOpen;
    uint256 sizeUSD; // Notional size in USD (1e6)
    uint256 collateralUSD; // Collateral posted (1e6)
    uint256 entryPrice; // Entry price (1e18)
    uint256 openedAt; // Timestamp
    uint256 marginFeesAccrued; // Accumulated margin fees (1e6)
  }

  struct AMMPosition {
    uint256 liquidity; // Current liquidity
    int24 tickLower;
    int24 tickUpper;
    uint256 feesEarned0; // Accumulated fees token0
    uint256 feesEarned1; // Accumulated fees token1
  }

  struct PendingOps {
    uint128 depositAmount;
    uint128 withdrawShares;
    address withdrawRecipient;
    uint8 flags; // Bitfield: bit0=deposit, bit1=withdraw
  }

  // === EVENTS ===

  event DepositQueued(address indexed user, uint256 amount);
  event DepositCancelled(address indexed user);
  event DepositExecuted(address indexed user, uint256 assets, uint256 shares);

  event WithdrawQueued(address indexed user, uint256 shares, address indexed recipient);
  event WithdrawCancelled(address indexed user);
  event WithdrawExecuted(address indexed user, uint256 shares, uint256 assets, address indexed recipient);

  event HedgeOpened(uint256 sizeUSD, uint256 entryPrice, uint256 timestamp);
  event HedgeClosed(uint256 sizeUSD, uint256 exitPrice, int256 pnl, uint256 timestamp);
  event HedgeAdjusted(uint256 oldSize, uint256 newSize, uint256 timestamp);

  event AMMRebalanced(
    int24 oldTickLower,
    int24 oldTickUpper,
    int24 newTickLower,
    int24 newTickUpper,
    uint256 timestamp
  );
  event FeesHarvested(uint256 fees0, uint256 fees1, uint256 timestamp);

  event EmergencyExit(uint256 usdcRecovered, uint256 timestamp);
  event Paused(bool paused);
  event ControllerUpdated(address indexed oldController, address indexed newController);

  // === ERRORS ===

  error OnlyOwner();
  error OnlyController();
  error OnlyFactory();
  error VaultPaused();
  error NotPaused();
  error ExceedsMax();
  error BelowMin();
  error InvalidOperation();
  error HedgeAlreadyOpen();
  error NoHedgeOpen();
  error InsufficientBalance();
  error InvalidAddress();
  error InvalidAmount();
  error SlippageExceeded();
  error NotCalm();

  // === USER FUNCTIONS ===

  /**
   * @notice Register deposit request
   * @param assets Amount of USDC to deposit
   */
  function deposit(uint256 assets) external;

  /**
   * @notice Register withdraw request
   * @param assets Amount of USDC to withdraw
   */
  function withdraw(uint256 assets) external;

  /**
   * @notice Legacy deposit register function (Deprecated)
   */
  function depositRegister(uint256 amount) external;

  /**
   * @notice Execute pending deposit (step 2 of 2, controller only)
   * @dev Deploys to AMM and adjusts hedge.
   */
  function depositExecute() external;

  /**
   * @notice Cancel pending deposit
   */
  function depositCancel() external;

  /**
   * @notice Legacy withdraw register function (Deprecated)
   */
  function withdrawRegister(uint256 shares, address recipient) external;

  /**
   * @notice Execute pending withdrawal (step 2 of 2, controller only)
   * @dev Withdraws from AMM, swaps via underlying pool, and sends USDC to recipient.
   * @param minAmountOut Minimum USDC expected after withdrawal and swap
   */
  function withdrawExecute(uint256 minAmountOut) external;

  /**
   * @notice Cancel pending withdrawal
   */
  function withdrawCancel() external;

  // === CONTROLLER FUNCTIONS ===

  /**
   * @notice Rebalance AMM position when out of range
   * @dev Controller only
   */
  function rebalanceAMM() external;

  /**
   * @notice Harvest fees from AMM position
   * @dev Controller only
   * @return fees0 Fees collected in token0
   * @return fees1 Fees collected in token1
   */
  function harvest() external returns (uint256 fees0, uint256 fees1);

  /**
   * @notice Manually adjust hedge position
   * @dev Controller only, use with caution
   * @param targetDeltaETH Target ETH delta to hedge
   */
  function adjustHedge(uint256 targetDeltaETH) external;

  /**
   * @notice Accrue margin fees for open hedge
   * @dev Controller only, called periodically
   */
  function accrueMarginFees() external;

  // === OWNER FUNCTIONS ===

  /**
   * @notice Emergency exit - close all positions and return to USDC
   * @dev Owner only, irreversible
   */
  function emergencyExit() external;

  /**
   * @notice Pause deposits and withdrawals
   * @param _paused True to pause, false to unpause
   */
  function setPaused(bool _paused) external;

  /**
   * @notice Update controller address
   * @param _controller New controller address
   */
  function setController(address _controller) external;

  /**
   * @notice Update max TVL cap
   * @param _maxTotalAssets New max TVL
   */
  function setMaxTotalAssets(uint256 _maxTotalAssets) external;

  /**
   * @notice Update minimum deposit amount
   * @param _minDeposit New minimum deposit
   */
  function setMinDeposit(uint256 _minDeposit) external;

  // === VIEW FUNCTIONS ===

  /**
   * @notice Get current hedge position details
   */
  function getCurrentHedge() external view returns (HedgePosition memory);

  /**
   * @notice Get current AMM position details
   */
  function getCurrentAMM() external view returns (AMMPosition memory);

  /**
   * @notice Get pending operations
   */
  function getPendingStates() external view returns (
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
  );

  /**
   * @notice Calculate current ETH delta from AMM position
   */
  function calculateAMMDelta() external view returns (uint256 deltaETH);

  /**
   * @notice Get vault pause status
   */
  function isPaused() external view returns (bool);

  /**
   * @notice Get controller address
   */
  function controller() external view returns (address);

  /**
   * @notice Get minimum deposit amount
   */
  function minDeposit() external view returns (uint256);

  /**
   * @notice Get maximum total assets (TVL cap)
   */
  function maxTotalAssets() external view returns (uint256);

  /**
   * @notice Check if emergency exit was triggered
   */
  function emergencyExitTriggered() external view returns (bool);

  /**
   * @notice Get underlying balances
   */
  function balances() external view returns (uint256 amount0, uint256 amount1);
}
