// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
  IERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {
  ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
  ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {
  OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
  PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IHedgedVault} from "./interfaces/IHedgedVault.sol";

/**
 * @title BaseVault
 * @notice Abstract base for 2-step deposit/withdraw AMM vaults (UUPS upgradeable)
 * @dev Non-hedged base. BaseHedgedVault (premium) extends this to add hedge management.
 *
 *      Storage layout includes 5 reserved slots (_reserved) between minDeposit and
 *      pending for hedge-layer storage compatibility with deployed UUPS proxies.
 *      BaseHedgedVault uses _reserved[0] for hedgeAdapter and _reserved[1..4] for
 *      AMMPosition fields. Non-hedged vaults leave them at zero.
 */
abstract contract BaseVault is
  IHedgedVault,
  ERC20Upgradeable,
  ReentrancyGuardUpgradeable,
  OwnableUpgradeable,
  UUPSUpgradeable,
  PausableUpgradeable
{
  using SafeERC20 for IERC20;

  // === IMMUTABLES ===
  address public immutable USDC;
  address public immutable WETH;

  // === CONFIGURATION ===
  address public override controller;
  uint256 public override maxTotalAssets;
  uint256 public override minDeposit;

  // === RESERVED SLOTS (hedge-layer storage) ===
  /// @dev Reserved for BaseHedgedVault. Layout:
  ///   [0] = hedgeAdapter address
  ///   [1] = AMMPosition.liquidity
  ///   [2] = AMMPosition.tickLower + tickUpper (packed)
  ///   [3] = AMMPosition.feesEarned0
  ///   [4] = AMMPosition.feesEarned1
  /// Non-hedged vaults leave these as zero.
  uint256[5] internal _reserved;

  // === PENDING OPERATIONS ===
  PendingOps internal pending;

  // === STATE FLAGS ===
  bool public override emergencyExitTriggered;

  // === MODIFIERS ===
  modifier onlyController() {
    if (msg.sender != controller) revert OnlyController();
    _;
  }

  // === CONSTRUCTOR ===
  constructor(address _usdc, address _weth) {
    USDC = _usdc;
    WETH = _weth;
  }

  // === INITIALIZER ===
  function initialize(
    address _owner,
    address _controller,
    string memory _name,
    string memory _symbol
  ) internal {
    __ERC20_init(_name, _symbol);
    __Ownable_init();
    _transferOwnership(_owner);
    __ReentrancyGuard_init();
    __UUPSUpgradeable_init();
    __Pausable_init();

    controller = _controller;
    maxTotalAssets = type(uint256).max;
    minDeposit = 10e6; // 10 USDC

    emit ControllerUpdated(address(0), _controller);
  }

  // === USER FUNCTIONS ===

  /**
   * @notice Register a deposit of USDC
   * @dev Initiates 2-step process (queues deposit)
   * @param assets Amount of USDC to deposit
   */
  function deposit(
    uint256 assets
  ) public whenNotPaused nonReentrant {
    if (msg.sender != owner()) revert InvalidOperation();
    if (pending.flags != 0) revert InvalidOperation();
    if (assets < minDeposit) revert BelowMin();
    if (getVaultEquity() + assets > maxTotalAssets) revert ExceedsMax();
    if (emergencyExitTriggered) revert InvalidOperation();

    // Transfer assets from msg.sender to vault
    IERC20(USDC).safeTransferFrom(msg.sender, address(this), assets);

    pending = PendingOps({
      depositAmount: uint128(assets),
      withdrawShares: 0,
      withdrawRecipient: address(0),
      flags: 0x01
    });

    emit DepositQueued(owner(), assets);
  }

  /**
   * @notice Legacy deposit register function
   * @dev Wraps deposit()
   */
  function depositRegister(uint256 amount) external override {
    deposit(amount);
  }

  /**
   * @notice Execute pending deposit (step 2 of 2, controller only)
   */
  function depositExecute() external virtual override onlyController nonReentrant {
    if ((pending.flags & 0x01) == 0) revert InvalidOperation();

    uint256 amount = pending.depositAmount;
    address user = owner();

    // Deploy USDC to AMM
    _deployToAMM(amount);

    // Mint shares
    uint256 supply = totalSupply();
    uint256 currentTotal = getVaultEquity();
    uint256 total = currentTotal > amount ? currentTotal - amount : 0;
    uint256 shares = amount;
    if (supply > 0 && total > 0) {
      shares = (amount * supply) / total;
    }
    _mint(user, shares);

    delete pending;

    emit DepositExecuted(user, amount, shares);
  }

  /**
   * @notice Cancel pending deposit
   */
  function depositCancel() external override nonReentrant {
    if ((pending.flags & 0x01) == 0) revert InvalidOperation();

    uint256 amount = pending.depositAmount;
    address user = owner();
    if (msg.sender != user) revert InvalidOperation();

    delete pending;
    // Transfer back USDC
    IERC20(USDC).safeTransfer(user, amount);

    emit DepositCancelled(user);
  }

  /**
   * @notice Register a withdrawal
   * @dev Accepts USDC amount. Single-owner vault — no share conversion needed.
   */
  function withdraw(
    uint256 assets
  ) public whenNotPaused nonReentrant {
    if (msg.sender != owner()) revert InvalidOperation();
    if (pending.flags != 0) revert InvalidOperation();
    if (emergencyExitTriggered) revert InvalidOperation();

    uint256 total = getVaultEquity();
    if (total == 0) revert InvalidOperation();
    if (assets > total) assets = total;

    pending = PendingOps({
      depositAmount: 0,
      withdrawShares: uint128(assets), // stores USDC amount
      withdrawRecipient: msg.sender,
      flags: 0x02
    });

    emit WithdrawQueued(msg.sender, assets, msg.sender);
  }

  /**
   * @notice Legacy withdraw register function (Deprecated)
   */
  function withdrawRegister(uint256, address) external override {
    revert();
  }

  /**
   * @notice Execute pending withdrawal (step 2 of 2, controller only)
   * @param minAmountOut Minimum USDC expected after withdrawal and swap
   */
  function withdrawExecute(uint256 minAmountOut) external virtual override onlyController nonReentrant {
    if ((pending.flags & 0x02) == 0) revert InvalidOperation();

    address recipient = pending.withdrawRecipient;
    address user = owner();

    // 1. Requested USDC amount
    uint256 expectedAmount = uint256(pending.withdrawShares);

    // 2. Burn proportional shares if any exist
    uint256 supply = totalSupply();
    if (supply > 0) {
      uint256 totalEquity = getVaultEquity();
      uint256 sharesToBurn = totalEquity > 0
        ? (expectedAmount * supply + totalEquity - 1) / totalEquity
        : supply;
      uint256 userBal = balanceOf(user);
      if (sharesToBurn > userBal) sharesToBurn = userBal;
      if (sharesToBurn > 0) _burn(user, sharesToBurn);
    }

    // 3. Use idle balance first
    uint256 usdcIdleBefore = IERC20(USDC).balanceOf(address(this));
    uint256 neededFromAMM = expectedAmount > usdcIdleBefore ? expectedAmount - usdcIdleBefore : 0;

    // 4. Withdraw from AMM only if needed
    if (neededFromAMM > 0) {
      _withdrawFromAMM(neededFromAMM);
    }

    // 5. Swap any non-USDC tokens back to USDC via underlying pool
    _swapAllToUSDC();

    // 6. Verify results and handle slippage
    uint256 totalUsdcAvailable = IERC20(USDC).balanceOf(address(this));
    if (totalUsdcAvailable < minAmountOut) revert InsufficientBalance();

    // 7. Transfer ALL available USDC to recipient
    if (totalUsdcAvailable > 0) {
      IERC20(USDC).safeTransfer(recipient, totalUsdcAvailable);
    }

    // 8. Clear pending
    delete pending;

    emit WithdrawExecuted(user, expectedAmount, totalUsdcAvailable, recipient);
  }

  /**
   * @notice Cancel pending withdrawal
   */
  function withdrawCancel() external override nonReentrant {
    if ((pending.flags & 0x02) == 0) revert InvalidOperation();

    address user = owner();
    if (msg.sender != user) revert InvalidOperation();

    delete pending;

    emit WithdrawCancelled(user);
  }

  // === CONTROLLER FUNCTIONS ===

  /**
   * @notice Rebalance AMM position when out of range
   * @dev Controller only
   */
  function rebalanceAMM() external virtual override onlyController nonReentrant {
    _rebalanceAMM();
    emit AMMRebalanced(0, 0, 0, 0, block.timestamp);
  }

  /**
   * @notice Harvest fees from AMM position
   * @dev Controller only
   * @return fees0 Fees collected in token0
   * @return fees1 Fees collected in token1
   */
  function harvest()
    external
    override
    onlyController
    nonReentrant
    returns (uint256 fees0, uint256 fees1)
  {
    (fees0, fees1) = _harvestFees();
    emit FeesHarvested(fees0, fees1, block.timestamp);
  }

  /**
   * @notice No-op for non-hedged vaults. Overridden by BaseHedgedVault.
   */
  function adjustHedge(uint256) external virtual override onlyController {}

  /**
   * @notice No-op for non-hedged vaults. Overridden by BaseHedgedVault.
   */
  function accrueMarginFees() external virtual override onlyController {}

  // === OWNER FUNCTIONS ===

  /**
   * @notice Emergency exit - close all positions and return to USDC
   * @dev Owner only, irreversible
   */
  function emergencyExit() external virtual override onlyOwner {
    emergencyExitTriggered = true;
    _pause();

    // Withdraw from AMM
    _withdrawAllFromAMM();

    // Swap all to USDC if needed (protocol-specific)
    _swapAllToUSDC();

    uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));

    emit EmergencyExit(usdcBalance, block.timestamp);
  }

  /**
   * @notice Pause deposits and withdrawals
   * @param _paused True to pause, false to unpause
   */
  function setPaused(bool _paused) external override onlyOwner {
    if (_paused) {
      _pause();
    } else {
      _unpause();
    }
    emit Paused(_paused);
  }

  /**
   * @notice Update controller address
   * @param _controller New controller address
   */
  function setController(address _controller) external override onlyOwner {
    if (_controller == address(0)) revert InvalidAddress();
    address oldController = controller;
    controller = _controller;
    emit ControllerUpdated(oldController, _controller);
  }

  /**
   * @notice Update max TVL cap
   * @param _maxTotalAssets New max TVL
   */
  function setMaxTotalAssets(uint256 _maxTotalAssets) external override onlyOwner {
    maxTotalAssets = _maxTotalAssets;
  }

  /**
   * @notice Update minimum deposit amount
   * @param _minDeposit New minimum deposit
   */
  function setMinDeposit(uint256 _minDeposit) external override onlyOwner {
    if (_minDeposit == 0) revert InvalidAmount();
    minDeposit = _minDeposit;
  }

  // === VIEW FUNCTIONS ===

  /**
   * @notice No-op for non-hedged vaults. Overridden by BaseHedgedVault.
   */
  function getCurrentHedge() external view virtual override returns (HedgePosition memory) {
    return HedgePosition(false, 0, 0, 0, 0, 0);
  }

  /**
   * @notice Get current AMM position details
   * @dev Strategy manages positions internally; returns simplified view
   */
  function getCurrentAMM() external pure override returns (AMMPosition memory) {
    return AMMPosition(0, 0, 0, 0, 0);
  }

  /**
   * @notice Get pending operations
   */
  function getPendingStates() external view virtual override returns (
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
    withdrawalAmount = pending.withdrawShares;
    withdrawalPending = (pending.flags & 0x02) != 0;
  }

  /**
   * @notice Calculate current ETH delta from AMM position
   */
  function calculateAMMDelta() external view override returns (uint256 deltaETH) {
    return _calculateAMMDelta();
  }

  /**
   * @notice Get vault pause status
   */
  function isPaused() external view override returns (bool) {
    return paused();
  }

  // === INTERNAL ===

  /**
   * @notice Get current ETH price
   * @dev Override in child contracts to use specific oracle
   * @return price ETH price in USD (1e18)
   */
  function _getETHPrice() internal view virtual returns (uint256 price) {
    return 3500e18; // Placeholder
  }

  /**
   * @notice Get total equity of the vault in USDC terms
   * @dev Must be implemented by child to correctly calculate value from balances
   */
  function getVaultEquity() public view virtual returns (uint256);

  // === ABSTRACT FUNCTIONS (Must be implemented by children) ===

  /**
   * @notice Get underlying balances of the AMM/Strategy
   */
  function balances() external view virtual returns (uint256 amount0, uint256 amount1);

  /**
   * @notice Deploy USDC to AMM
   */
  function _deployToAMM(
    uint256 usdcAmount
  ) internal virtual returns (uint256 amount0, uint256 amount1);

  /**
   * @notice Withdraw from AMM
   */
  function _withdrawFromAMM(
    uint256 usdcAmount
  ) internal virtual returns (uint256 amount0, uint256 amount1);

  /**
   * @notice Calculate current ETH delta from AMM position
   */
  function _calculateAMMDelta() internal view virtual returns (uint256 deltaETH);

  /**
   * @notice Rebalance AMM position
   */
  function _rebalanceAMM() internal virtual;

  /**
   * @notice Harvest fees from AMM
   */
  function _harvestFees() internal virtual returns (uint256 fees0, uint256 fees1);

  /**
   * @notice Withdraw all liquidity from AMM
   */
  function _withdrawAllFromAMM() internal virtual;

  /**
   * @notice Get AMM position value in USDC
   */
  function _getAMMPositionValue() internal view virtual returns (uint256 value);

  /**
   * @notice Get unclaimed fees in USDC
   */
  function _getUnclaimedFees() internal view virtual returns (uint256 fees);

  /**
   * @notice Swap all tokens to USDC (for emergency exit)
   */
  function _swapAllToUSDC() internal virtual;

  // === UUPS UPGRADE ===

  function _authorizeUpgrade(address /*newImplementation*/) internal view virtual override {
    if (msg.sender != owner() && msg.sender != controller) {
      revert();
    }
  }

  /**
   * @notice Get current implementation address
   * @return Implementation address
   */
  function getImplementation() external view returns (address) {
    return _getImplementation();
  }
}
