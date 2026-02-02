// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SwapCall, SwapExecutor} from "./libraries/SwapExecutor.sol";
import {IRouter} from "balancer-v3-monorepo/pkg/interfaces/contracts/vault/IRouter.sol";

interface IPermit2 {
  function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/**
 * @title AnalogBalancerVault
 * @notice Per-user Balancer vault wrapper with USDC as accounting asset.
 * @dev
 * - Shares represent a claim on the vault's total USDC-equivalent value.
 * - `want()` returns the accounting asset (USDC).
 * - `wants()` returns the underlying Balancer pool tokens (token0, token1).
 * - User-facing flow is:
 *    1) User calls `deposit(assets)` in USDC.
 *    2) Controller calls `invest()` with 1inch swap calldata to acquire pool tokens
 *       and `joinPool` via Balancer Vault.
 *    3) On exit, controller calls `divest()` to `exitPool` and swap back to USDC;
 *       then user can call `withdraw(assets)`.
 *
 * This keeps user interactions simple (USDC in/out) while allowing the
 * controller to manage Balancer positions under the hood.
 */
contract AnalogBalancerVault is ERC20, ReentrancyGuard {
  using SafeERC20 for IERC20;

  // -------------------------------------------------------------------------
  // Immutable / configured state
  // -------------------------------------------------------------------------

  /// @notice USDC accounting asset (returned by want()).
  address public immutable usdc;

  /// @notice Balancer Vault contract address.
  address public immutable balancerVault;

  /// @notice Balancer v3 Router contract address (trusted by the Vault).
  address public immutable balancerRouter;

  /// @notice Uniswap Permit2 contract used by the Balancer router for allowances.
  address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

  /// @notice Balancer v3 pool address for the target pool (also the BPT token).
  address public immutable pool;

  /// @notice Underlying pool tokens (e.g., GHO, USDC).
  address public immutable token0;
  address public immutable token1;

  /// @notice 1inch router used for swaps.
  address public immutable router;

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
  event Invested(uint256 usdcSpent, uint256 amount0, uint256 amount1);
  event Divested(uint256 amount0, uint256 amount1, uint256 usdcReceived);

  error OnlyOwner();
  error OnlyController();
  error InvalidAmount();
  error InsufficientLiquidity();

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
   * @param _usdc USDC accounting asset.
   * @param _balancerVault Balancer v3 Vault address.
   * @param _balancerRouter Balancer v3 Batch Router address.
   * @param _pool Balancer v3 pool address for the target pool (also the BPT token).
   * @param _token0 First pool token (e.g., GHO).
   * @param _token1 Second pool token (e.g., USDC).
   * @param _router 1inch router used for swaps.
   * @param _name ERC20 share token name.
   * @param _symbol ERC20 share token symbol.
   */
  constructor(
    address _owner,
    address _usdc,
    address _balancerVault,
    address _balancerRouter,
    address _pool,
    address _token0,
    address _token1,
    address _router,
    string memory _name,
    string memory _symbol
  ) ERC20(_name, _symbol) {
    require(_owner != address(0), "Invalid owner");
    require(_usdc != address(0), "Invalid USDC");
    require(_balancerVault != address(0), "Invalid Balancer Vault");
    require(_balancerRouter != address(0), "Invalid Balancer Router");
    require(_pool != address(0), "Invalid pool");
    require(_token0 != address(0) && _token1 != address(0), "Invalid pool tokens");
    require(_router != address(0), "Invalid router");

    owner = _owner;
    usdc = _usdc;
    balancerVault = _balancerVault;
    balancerRouter = _balancerRouter;
    pool = _pool;
    token0 = _token0;
    token1 = _token1;
    router = _router;

    controller = _owner;
    emit ControllerUpdated(_owner);
  }

  // -------------------------------------------------------------------------
  // View helpers (Beefy / handler-style)
  // -------------------------------------------------------------------------

  /**
   * @notice Single-asset "want" used by generic handlers.
   * @dev For AnalogBalancerVault this is always USDC (accounting asset).
   */
  function want() external view returns (address) {
    return usdc;
  }

  /**
   * @notice Multi-asset wants for Balancer pool (token0, token1).
   */
  function wants() external view returns (address, address) {
    return (token0, token1);
  }

  // -------------------------------------------------------------------------
  // Controller management
  // -------------------------------------------------------------------------

  function setController(address _controller) external onlyOwner {
    require(_controller != address(0), "Invalid controller");
    controller = _controller;
    emit ControllerUpdated(_controller);
  }

  // -------------------------------------------------------------------------
  // User-facing deposit / withdraw (USDC in / out)
  // -------------------------------------------------------------------------

  /**
   * @notice Deposit USDC and receive vault shares.
   * @param assets Amount of USDC to deposit (6 decimals).
   */
  function deposit(uint256 assets) external nonReentrant {
    if (assets == 0) revert InvalidAmount();

    // Pull USDC from user
    IERC20(usdc).safeTransferFrom(msg.sender, address(this), assets);

    // Simple 1:1 shares = assets for now
    uint256 shares = assets;
    _mint(msg.sender, shares);

    emit Deposited(msg.sender, assets, shares);
  }

  /**
   * @notice Redeem vault shares for USDC.
   * @param shares Amount of shares to burn.
   */
  function withdraw(uint256 shares) external nonReentrant {
    if (shares == 0) revert InvalidAmount();
    if (balanceOf(msg.sender) < shares) revert InsufficientLiquidity();

    // For now we require that vault already holds enough USDC
    // (controller must have divested from Balancer before withdraw).
    uint256 assets = shares;
    uint256 usdcBalance = IERC20(usdc).balanceOf(address(this));
    if (usdcBalance < assets) revert InsufficientLiquidity();

    _burn(msg.sender, shares);
    IERC20(usdc).safeTransfer(msg.sender, assets);

    emit Withdrawn(msg.sender, assets, shares);
  }

  // -------------------------------------------------------------------------
  // Controller-only Balancer integration: invest (join) and divest (exit)
  // -------------------------------------------------------------------------

  /**
   * @notice Convert USDC held in the vault into pool tokens and join the Balancer pool.
   * @dev
   * - Expects swap calls that swap USDC -> token0/token1 via 1inch router.
   * - After swaps, joins the Balancer pool with resulting balances.
   * - Any remaining USDC stays as idle liquidity backing shares.
   */
  function invest(
    SwapCall[] calldata swapCalls,
    uint256 minAmount0,
    uint256 minAmount1
  ) external onlyController nonReentrant {
    // Execute off-chain provided 1inch swaps from USDC to token0/token1
    if (swapCalls.length > 0) {
      // Approvals must be set off-chain or via a separate helper if needed.
      SwapExecutor.executeSwaps(swapCalls, router);
    }

    uint256 bal0 = IERC20(token0).balanceOf(address(this));
    uint256 bal1 = IERC20(token1).balanceOf(address(this));

    if (bal0 < minAmount0 || bal1 < minAmount1) revert InsufficientLiquidity();

    // Approve Permit2 for pool tokens; the router will use Permit2 to pull
    // tokens from this vault into the Vault.
    IERC20(token0).safeApprove(PERMIT2, 0);
    IERC20(token0).safeApprove(PERMIT2, bal0);
    IERC20(token1).safeApprove(PERMIT2, 0);
    IERC20(token1).safeApprove(PERMIT2, bal1);

    // Set Permit2 allowances for the Router as spender (Permit2 checks
    // allowance keyed by (owner, msg.sender, token)).
    IPermit2(PERMIT2).approve(token0, balancerRouter, type(uint160).max, type(uint48).max);
    IPermit2(PERMIT2).approve(token1, balancerRouter, type(uint160).max, type(uint48).max);

    uint256[] memory maxAmountsIn = new uint256[](2);
    maxAmountsIn[0] = bal0;
    maxAmountsIn[1] = bal1;

    // For Balancer v3, we call the Router's unbalanced add liquidity helper.
    // This will transfer tokens from this vault into the Vault and mint BPT
    // to this contract.
    IRouter(balancerRouter).addLiquidityUnbalanced(
      pool,
      maxAmountsIn,
      0, // minBptAmountOut
      false, // wethIsEth
      ""
    );

    emit Invested(IERC20(usdc).balanceOf(address(this)), bal0, bal1);
  }

  /**
   * @notice Exit Balancer pool back to pool tokens and optionally swap them to USDC.
   * @dev
   * - Controller decides how many BPT to burn via `bptAmountIn`.
   * - Expects the vault to already hold BPT (not tracked explicitly here).
   * - After exit, controller can use `swapCalls` to convert pool tokens back to USDC.
   */
  function divest(
    address bptToken,
    uint256 bptAmountIn,
    uint256[] calldata minAmountsOut,
    SwapCall[] calldata swapCalls
  ) external onlyController nonReentrant {
    require(bptToken != address(0), "Invalid BPT");
    if (bptAmountIn == 0) revert InvalidAmount();

    // Approve Balancer Router to pull BPT when exiting.
    IERC20(bptToken).safeApprove(balancerRouter, 0);
    IERC20(bptToken).safeApprove(balancerRouter, bptAmountIn);

    // For Balancer v3, we call the Router's proportional remove liquidity
    // helper to burn BPT and receive the underlying pool tokens here.
    IRouter(balancerRouter).removeLiquidityProportional(
      pool,
      bptAmountIn,
      minAmountsOut,
      false, // wethIsEth
      ""
    );

    uint256 bal0 = IERC20(token0).balanceOf(address(this));
    uint256 bal1 = IERC20(token1).balanceOf(address(this));

    // Optionally convert pool tokens back to USDC via 1inch swaps
    if (swapCalls.length > 0) {
      // Approvals must be managed off-chain; here we just execute swaps
      SwapExecutor.executeSwaps(swapCalls, router);
    }

    uint256 usdcReceived = IERC20(usdc).balanceOf(address(this));
    emit Divested(bal0, bal1, usdcReceived);
  }
}









