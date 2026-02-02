// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC4626} from "../lib/forge-std/src/interfaces/IERC4626.sol";

/**
 * @title AnalogCurveVault
 * @notice Per-user wrapper around an underlying ERC4626 vault (e.g. Beefy Curve vault)
 *         with USDC as the external accounting asset.
 *
 * @dev
 * - Users deposit and withdraw in USDC via simple `deposit` / `withdraw` functions.
 * - The off-chain controller is responsible for managing when funds are invested into
 *   or divested from the underlying ERC4626 vault.
 * - Shares of this vault represent a pro-rata claim on all USDC-equivalent value:
 *      - Idle USDC held by this contract, plus
 *      - USDC-equivalent value of shares held in the underlying ERC4626 vault.
 *
 * This is intentionally analogous to `AnalogBalancerVault` but uses an ERC4626 vault
 * instead of a Balancer pool. The underlying ERC4626 vault is expected to use USDC
 * as its `asset()`.
 */
contract AnalogCurveVault is ERC20, ReentrancyGuard {
  using SafeERC20 for IERC20;

  // -------------------------------------------------------------------------
  // Immutable / configured state
  // -------------------------------------------------------------------------

  /// @notice Accounting asset (external asset users interact with). Intended to
  ///         match the underlying ERC4626 `asset()` token.
  address public immutable usdc;

  /// @notice Underlying ERC4626 vault (e.g. Beefy Curve vault).
  IERC4626 public immutable underlyingVault;

  /// @notice Per-user owner of this vault instance.
  address public immutable owner;

  /// @notice Off-chain controller allowed to manage invest/divest operations.
  address public controller;

  // -------------------------------------------------------------------------
  // Events / errors
  // -------------------------------------------------------------------------

  event ControllerUpdated(address indexed newController);
  event Deposited(address indexed user, uint256 assets, uint256 shares);
  event Withdrawn(address indexed user, uint256 assets, uint256 shares);
  event Invested(uint256 usdcSpent, uint256 sharesReceived);
  event Divested(uint256 sharesBurned, uint256 usdcReceived);

  error OnlyOwner();
  error OnlyController();
  error InvalidAmount();
  error InsufficientLiquidity();
  error InvalidVaultAsset();

  // -------------------------------------------------------------------------
  // Modifiers
  // -------------------------------------------------------------------------

  modifier onlyOwner() {
    if (msg.sender != owner) revert OnlyOwner();
    _;
  }

  modifier onlyController() {
    if (msg.sender != controller) revert OnlyController();
    _;
  }

  // -------------------------------------------------------------------------
  // Constructor
  // -------------------------------------------------------------------------

  /**
   * @param _owner Per-user owner of this vault.
   * @param _usdc Accounting asset (must equal underlying ERC4626 asset()).
   * @param _underlyingVault Address of the underlying ERC4626 vault.
   * @param _name ERC20 share token name.
   * @param _symbol ERC20 share token symbol.
   */
  constructor(
    address _owner,
    address _usdc,
    address _underlyingVault,
    string memory _name,
    string memory _symbol
  ) ERC20(_name, _symbol) {
    if (_owner == address(0)) revert OnlyOwner();
    if (_usdc == address(0) || _underlyingVault == address(0)) {
      revert InvalidAmount();
    }

    // Underlying vault asset must match configured accounting asset.
    address vaultAsset = IERC4626(_underlyingVault).asset();
    if (vaultAsset != _usdc) revert InvalidVaultAsset();

    owner = _owner;
    usdc = _usdc;
    underlyingVault = IERC4626(_underlyingVault);

    controller = _owner;
    emit ControllerUpdated(_owner);
  }

  // -------------------------------------------------------------------------
  // View helpers (handler-style)
  // -------------------------------------------------------------------------

  /**
   * @notice Single-asset "want" used by generic handlers.
   * @dev For AnalogCurveVault this is always USDC (accounting asset).
   */
  function want() external view returns (address) {
    return usdc;
  }

  /**
   * @notice Expose the underlying ERC4626 vault address.
   */
  function vault() external view returns (address) {
    return address(underlyingVault);
  }

  /**
   * @notice Convenience view mirroring ERC4626 `asset()` for integrators.
   */
  function asset() external view returns (address) {
    return usdc;
  }

  // -------------------------------------------------------------------------
  // Controller management
  // -------------------------------------------------------------------------

  function setController(address _controller) external onlyOwner {
    if (_controller == address(0)) revert InvalidAmount();
    controller = _controller;
    emit ControllerUpdated(_controller);
  }

  // -------------------------------------------------------------------------
  // User-facing deposit / withdraw (USDC in / out)
  // -------------------------------------------------------------------------

  /**
   * @notice Deposit USDC and receive vault shares.
   * @param assets Amount of USDC to deposit (6 decimals).
   *
   * @dev
   * - 1:1 shares = assets for now, like AnalogBalancerVault.
   * - Off-chain controller decides when to invest idle USDC into the
   *   underlying ERC4626 vault.
   */
  function deposit(uint256 assets) external nonReentrant {
    if (assets == 0) revert InvalidAmount();

    IERC20(usdc).safeTransferFrom(msg.sender, address(this), assets);

    uint256 shares = assets;
    _mint(msg.sender, shares);

    emit Deposited(msg.sender, assets, shares);
  }

  /**
   * @notice Redeem vault shares for USDC.
   * @param shares Amount of shares to burn.
   *
   * @dev
   * - Requires that this contract already holds enough USDC liquidity to
   *   satisfy the request. The controller must have divested from the
   *   underlying ERC4626 vault beforehand if necessary.
   */
  function withdraw(uint256 shares) external nonReentrant {
    if (shares == 0) revert InvalidAmount();
    if (balanceOf(msg.sender) < shares) revert InsufficientLiquidity();

    uint256 assets = shares;
    uint256 usdcBalance = IERC20(usdc).balanceOf(address(this));
    if (usdcBalance < assets) revert InsufficientLiquidity();

    _burn(msg.sender, shares);
    IERC20(usdc).safeTransfer(msg.sender, assets);

    emit Withdrawn(msg.sender, assets, shares);
  }

  // -------------------------------------------------------------------------
  // Controller-only ERC4626 integration: invest (deposit) and divest (redeem)
  // -------------------------------------------------------------------------

  /**
   * @notice Invest idle USDC held in this vault into the underlying ERC4626 vault.
   * @param amountUSDC Amount of USDC to invest. If set to 0, invest entire balance.
   * @param minSharesOut Minimum acceptable underlying vault shares (slippage guard).
   */
  function invest(uint256 amountUSDC, uint256 minSharesOut) external onlyController nonReentrant {
    uint256 balanceUSDC = IERC20(usdc).balanceOf(address(this));
    uint256 amount = amountUSDC == 0 ? balanceUSDC : amountUSDC;
    if (amount == 0 || amount > balanceUSDC) revert InvalidAmount();

    IERC20(usdc).safeApprove(address(underlyingVault), 0);
    IERC20(usdc).safeApprove(address(underlyingVault), amount);

    uint256 sharesReceived = underlyingVault.deposit(amount, address(this));
    if (sharesReceived < minSharesOut) revert InsufficientLiquidity();

    emit Invested(amount, sharesReceived);
  }

  /**
   * @notice Divest from the underlying ERC4626 vault back to USDC held in this contract.
   * @param shares Amount of underlying vault shares to redeem. If 0, redeem full balance.
   * @param minUsdcOut Minimum acceptable USDC returned (slippage guard).
   */
  function divest(uint256 shares, uint256 minUsdcOut) external onlyController nonReentrant {
    uint256 vaultShareBalance = underlyingVault.balanceOf(address(this));
    uint256 toRedeem = shares == 0 ? vaultShareBalance : shares;
    if (toRedeem == 0 || toRedeem > vaultShareBalance) revert InvalidAmount();

    uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));

    underlyingVault.redeem(toRedeem, address(this), address(this));

    uint256 usdcAfter = IERC20(usdc).balanceOf(address(this));
    uint256 received = usdcAfter - usdcBefore;
    if (received < minUsdcOut) revert InsufficientLiquidity();

    emit Divested(toRedeem, received);
  }
}









