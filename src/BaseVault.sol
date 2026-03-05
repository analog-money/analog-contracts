// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
 * @notice Abstract base for single-owner 2-step deposit/withdraw AMM vaults (UUPS upgradeable)
 * @dev No ERC20 — vaults are user-bound, shares are not tradable.
 *      Token-agnostic: only needs USDC as the base currency.
 */
abstract contract BaseVault is
  IHedgedVault,
  Initializable,
  ReentrancyGuardUpgradeable,
  OwnableUpgradeable,
  UUPSUpgradeable,
  PausableUpgradeable
{
  using SafeERC20 for IERC20;

  // === IMMUTABLES ===
  address public immutable USDC;

  // === CONFIGURATION ===
  address public override controller;
  uint256 public override maxTotalAssets;
  uint256 public override minDeposit;

  // === SHARE ACCOUNTING (single owner, not tradable) ===
  uint256 public totalShares;

  // === RESERVED SLOTS (hedge-layer storage) ===
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
  constructor(address _usdc) {
    USDC = _usdc;
  }

  // === INITIALIZER ===
  function initialize(
    address _owner,
    address _controller
  ) internal {
    if (_owner == address(0)) revert InvalidAddress();
    if (_controller == address(0)) revert InvalidAddress();

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

  function deposit(
    uint256 assets
  ) public whenNotPaused nonReentrant {
    if (msg.sender != owner()) revert InvalidOperation();
    if (pending.flags != 0) revert InvalidOperation();
    if (assets < minDeposit) revert BelowMin();
    if (getVaultEquity() + assets > maxTotalAssets) revert ExceedsMax();
    if (emergencyExitTriggered) revert InvalidOperation();

    IERC20(USDC).safeTransferFrom(msg.sender, address(this), assets);

    pending = PendingOps({
      depositAmount: uint128(assets),
      withdrawAmount: 0,
      withdrawRecipient: address(0),
      flags: 0x01
    });

    emit DepositQueued(owner(), assets);
  }

  function depositRegister(uint256 amount) external override {
    deposit(amount);
  }

  function depositExecute() external virtual override onlyController nonReentrant {
    if ((pending.flags & 0x01) == 0) revert InvalidOperation();

    uint256 amount = pending.depositAmount;
    address user = owner();

    _deployToAMM(amount);

    uint256 supply = totalShares;
    uint256 currentTotal = getVaultEquity();
    uint256 total = currentTotal > amount ? currentTotal - amount : 0;
    uint256 shares = amount;
    if (supply > 0 && total > 0) {
      shares = (amount * supply) / total;
    }
    totalShares += shares;

    delete pending;

    emit DepositExecuted(user, amount, shares);
  }

  function depositCancel() external override nonReentrant {
    if ((pending.flags & 0x01) == 0) revert InvalidOperation();

    uint256 amount = pending.depositAmount;
    address user = owner();
    if (msg.sender != user) revert InvalidOperation();

    delete pending;
    IERC20(USDC).safeTransfer(user, amount);

    emit DepositCancelled(user);
  }

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
      withdrawAmount: uint128(assets),
      withdrawRecipient: msg.sender,
      flags: 0x02
    });

    emit WithdrawQueued(msg.sender, assets, msg.sender);
  }

  function withdrawRegister(uint256, address) external pure override {
    revert();
  }

  function withdrawExecute(uint256 minAmountOut) external virtual override onlyController nonReentrant {
    if ((pending.flags & 0x02) == 0) revert InvalidOperation();

    address recipient = pending.withdrawRecipient;
    address user = owner();

    uint256 expectedAmount = uint256(pending.withdrawAmount);

    uint256 supply = totalShares;
    if (supply > 0) {
      uint256 totalEquity = getVaultEquity();
      uint256 sharesToBurn = totalEquity > 0
        ? (expectedAmount * supply + totalEquity - 1) / totalEquity
        : supply;
      if (sharesToBurn > supply) sharesToBurn = supply;
      totalShares -= sharesToBurn;
    }

    uint256 usdcIdleBefore = IERC20(USDC).balanceOf(address(this));
    uint256 neededFromAMM = expectedAmount > usdcIdleBefore ? expectedAmount - usdcIdleBefore : 0;

    if (neededFromAMM > 0) {
      _withdrawFromAMM(neededFromAMM);
    }

    _swapAllToUSDC();

    uint256 totalUsdcAvailable = IERC20(USDC).balanceOf(address(this));
    if (totalUsdcAvailable < minAmountOut) revert InsufficientBalance();

    if (totalUsdcAvailable > 0) {
      IERC20(USDC).safeTransfer(recipient, totalUsdcAvailable);
    }

    delete pending;

    emit WithdrawExecuted(user, expectedAmount, totalUsdcAvailable, recipient);
  }

  function withdrawCancel() external override nonReentrant {
    if ((pending.flags & 0x02) == 0) revert InvalidOperation();

    address user = owner();
    if (msg.sender != user) revert InvalidOperation();

    delete pending;

    emit WithdrawCancelled(user);
  }

  // === CONTROLLER FUNCTIONS ===

  function rebalanceAMM() external virtual override onlyController nonReentrant {
    _rebalanceAMM();
    emit AMMRebalanced(0, 0, 0, 0, block.timestamp);
  }

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

  function adjustHedge(uint256) external virtual override onlyController {}
  function accrueMarginFees() external virtual override onlyController {}

  // === OWNER FUNCTIONS ===

  function emergencyExit() external virtual override onlyOwner {
    emergencyExitTriggered = true;
    _pause();
    try this.doEmergencyWithdrawFromAMM() {} catch {}
    try this.doEmergencySwapAllToUSDC() {} catch {}
    uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
    if (usdcBalance > 0) {
      IERC20(USDC).safeTransfer(owner(), usdcBalance);
    }
    totalShares = 0;
    delete pending;
    emit EmergencyExit(usdcBalance, block.timestamp);
  }

  function doEmergencyWithdrawFromAMM() external {
    if (msg.sender != address(this)) revert OnlySelf();
    _withdrawAllFromAMM();
  }

  function doEmergencySwapAllToUSDC() external {
    if (msg.sender != address(this)) revert OnlySelf();
    _swapAllToUSDC();
  }

  function rescueTokens(address token, address to) external override onlyOwner {
    if (!emergencyExitTriggered) revert InvalidOperation();
    if (to == address(0)) revert InvalidAddress();
    uint256 balance = IERC20(token).balanceOf(address(this));
    if (balance > 0) {
      IERC20(token).safeTransfer(to, balance);
      emit TokensRescued(token, to, balance);
    }
  }

  function setPaused(bool _paused) external override onlyOwner {
    if (_paused) _pause();
    else _unpause();
    emit PauseChanged(_paused);
  }

  function setController(address _controller) external override onlyOwner {
    if (_controller == address(0)) revert InvalidAddress();
    address oldController = controller;
    controller = _controller;
    emit ControllerUpdated(oldController, _controller);
  }

  function setMaxTotalAssets(uint256 _maxTotalAssets) external override onlyOwner {
    maxTotalAssets = _maxTotalAssets;
  }

  function setMinDeposit(uint256 _minDeposit) external override onlyOwner {
    if (_minDeposit == 0) revert InvalidAmount();
    minDeposit = _minDeposit;
  }

  // === VIEW FUNCTIONS ===

  function getCurrentHedge() external view virtual override returns (HedgePosition memory) {
    return HedgePosition(false, 0, 0, 0, 0, 0);
  }

  function getCurrentAMM() external pure override returns (AMMPosition memory) {
    return AMMPosition(0, 0, 0, 0, 0);
  }

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
    withdrawalAmount = pending.withdrawAmount;
    withdrawalPending = (pending.flags & 0x02) != 0;
  }

  function calculateAMMDelta() external view override returns (uint256 deltaETH) {
    return _calculateAMMDelta();
  }

  function isPaused() external view override returns (bool) {
    return paused();
  }

  // === ABSTRACT ===

  function getVaultEquity() public view virtual returns (uint256);
  function balances() external view virtual returns (uint256 amount0, uint256 amount1);
  function _deployToAMM(uint256 usdcAmount) internal virtual returns (uint256 amount0, uint256 amount1);
  function _withdrawFromAMM(uint256 usdcAmount) internal virtual returns (uint256 amount0, uint256 amount1);
  function _calculateAMMDelta() internal view virtual returns (uint256 deltaETH);
  function _rebalanceAMM() internal virtual;
  function _harvestFees() internal virtual returns (uint256 fees0, uint256 fees1);
  function _withdrawAllFromAMM() internal virtual;
  function _getAMMPositionValue() internal view virtual returns (uint256 value);
  function _getUnclaimedFees() internal view virtual returns (uint256 fees);
  function _swapAllToUSDC() internal virtual;

  // === UUPS UPGRADE ===

  function _authorizeUpgrade(address) internal view virtual override {
    if (msg.sender != owner() && msg.sender != controller) {
      revert();
    }
  }

  function getImplementation() external view returns (address) {
    return _getImplementation();
  }
}
