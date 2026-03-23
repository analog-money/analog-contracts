// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IBeefyVault {
    function want() external view returns (address);
    function deposit(uint256 amount0, uint256 amount1, uint256 _minShares) external;
    function withdraw(uint256 shares) external;
    function balanceOf(address account) external view returns (uint256);
    function isCalm() external view returns (bool);
}

interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @title VaultWrapper
 * @notice Per-user wrapper that holds tokens, executes swaps, and manages vault deposits
 * @dev One wrapper instance per user, deployed via VaultWrapperFactory
 */
contract VaultWrapper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Immutable state
    address public immutable owner;
    address public immutable factory;
    address public immutable usdc;

    // Mutable state
    address public controller;

    // Approved 1inch router for swaps
    address public constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

    // Events
    event USDCDeposited(uint256 amount);
    event SwapsExecuted(uint256 swapCount);
    event DepositedToVault(address indexed vault, uint256 shares);
    event Withdrawn(address indexed vault, uint256 usdcAmount);
    event DepositCancelled(uint256 usdcAmount);
    event ControllerUpdated(address indexed newController);

    // Errors
    error OnlyOwner();
    error OnlyController();
    error OnlyFactory();
    error VaultNotCalm();
    error HasVaultShares();
    error InvalidTarget();
    error SwapFailed();
    error InsufficientBalance();

    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    /**
     * @notice Constructor sets immutable owner and factory
     * @param _owner User who owns this wrapper
     * @param _usdc USDC token address
     */
    constructor(address _owner, address _usdc) {
        owner = _owner;
        factory = msg.sender;
        usdc = _usdc;
    }

    /**
     * @notice Initialize controller (called by factory after deployment)
     * @param _controller Controller address that can trigger swaps/deposits
     */
    function initialize(address _controller) external onlyFactory {
        controller = _controller;
        
        // Approve USDC to 1inch router for swaps (unlimited approval)
        // This allows swaps from USDC to pool tokens
        IERC20(usdc).safeApprove(ONEINCH_ROUTER, 0);
        IERC20(usdc).safeApprove(ONEINCH_ROUTER, type(uint256).max);
        
        emit ControllerUpdated(_controller);
    }

    /**
     * @notice User deposits USDC into wrapper
     * @param amount Amount of USDC to deposit (6 decimals)
     */
    function depositUSDC(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert InsufficientBalance();
        
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);
        
        emit USDCDeposited(amount);
    }

    /**
     * @notice Controller executes 1inch swaps with API-provided calldata
     * @param swapCalls Array of swap calls to execute
     */
    function executeSwaps(SwapCall[] calldata swapCalls) external onlyController nonReentrant {
        uint256 swapCount = swapCalls.length;
        
        for (uint256 i = 0; i < swapCount; i++) {
            SwapCall calldata swap = swapCalls[i];
            
            // Validate target is 1inch router
            if (swap.target != ONEINCH_ROUTER) revert InvalidTarget();
            
            // Execute swap
            (bool success, ) = swap.target.call{value: swap.value}(swap.data);
            if (!success) revert SwapFailed();
        }
        
        emit SwapsExecuted(swapCount);
    }

    /**
     * @notice Controller deposits tokens to vault when calm
     * @param vault Beefy vault address
     * @param amount0 Amount of token0 to deposit
     * @param amount1 Amount of token1 to deposit
     * @param minShares Minimum shares expected (slippage protection)
     */
    function depositToVault(
        address vault,
        uint256 amount0,
        uint256 amount1,
        uint256 minShares
    ) external onlyController nonReentrant {
        IBeefyVault vaultContract = IBeefyVault(vault);
        
        // Check vault is calm
        if (!vaultContract.isCalm()) revert VaultNotCalm();
        
        // Get pool tokens
        address pool = vaultContract.want();
        IUniswapV3Pool poolContract = IUniswapV3Pool(pool);
        address token0 = poolContract.token0();
        address token1 = poolContract.token1();
        
        // Approve tokens to vault (unlimited approval for efficiency)
        if (amount0 > 0) {
            IERC20(token0).safeApprove(vault, 0);
            IERC20(token0).safeApprove(vault, type(uint256).max);
        }
        if (amount1 > 0) {
            IERC20(token1).safeApprove(vault, 0);
            IERC20(token1).safeApprove(vault, type(uint256).max);
        }
        
        // Get shares before
        uint256 sharesBefore = vaultContract.balanceOf(address(this));
        
        // Deposit to vault
        vaultContract.deposit(amount0, amount1, minShares);
        
        // Get shares after
        uint256 sharesAfter = vaultContract.balanceOf(address(this));
        uint256 sharesReceived = sharesAfter - sharesBefore;
        
        emit DepositedToVault(vault, sharesReceived);
    }

    /**
     * @notice User initiates withdrawal with controller-provided swap data
     * @param vault Beefy vault address
     * @param shares Amount of vault shares to withdraw
     * @param swapCalls Array of swap calls to convert tokens back to USDC
     */
    function withdraw(
        address vault,
        uint256 shares,
        SwapCall[] calldata swapCalls
    ) external onlyOwner nonReentrant {
        IBeefyVault vaultContract = IBeefyVault(vault);
        
        // Check we have shares
        uint256 balance = vaultContract.balanceOf(address(this));
        if (balance == 0) revert InsufficientBalance();
        if (shares > balance) revert InsufficientBalance();
        
        // Withdraw from vault (receives pool tokens)
        vaultContract.withdraw(shares);
        
        // Get pool tokens and approve them to 1inch router for swaps
        address pool = vaultContract.want();
        IUniswapV3Pool poolContract = IUniswapV3Pool(pool);
        address token0 = poolContract.token0();
        address token1 = poolContract.token1();
        
        // Approve pool tokens to 1inch router (unlimited approval)
        IERC20(token0).safeApprove(ONEINCH_ROUTER, 0);
        IERC20(token0).safeApprove(ONEINCH_ROUTER, type(uint256).max);
        IERC20(token1).safeApprove(ONEINCH_ROUTER, 0);
        IERC20(token1).safeApprove(ONEINCH_ROUTER, type(uint256).max);
        
        // Execute swaps to convert tokens back to USDC
        uint256 swapCount = swapCalls.length;
        for (uint256 i = 0; i < swapCount; i++) {
            SwapCall calldata swap = swapCalls[i];
            
            // Validate target is 1inch router
            if (swap.target != ONEINCH_ROUTER) revert InvalidTarget();
            
            // Execute swap
            (bool success, ) = swap.target.call{value: swap.value}(swap.data);
            if (!success) revert SwapFailed();
        }
        
        // Transfer USDC to owner
        uint256 usdcBalance = IERC20(usdc).balanceOf(address(this));
        if (usdcBalance > 0) {
            IERC20(usdc).safeTransfer(owner, usdcBalance);
        }
        
        emit Withdrawn(vault, usdcBalance);
    }

    /**
     * @notice User cancels deposit and gets USDC back (only if not in vault)
     * @param vault Vault address to get pool tokens from (required if swapCalls provided)
     * @param swapCalls Optional swap calls if tokens need to be converted back to USDC
     */
    function cancelDeposit(
        address vault,
        SwapCall[] calldata swapCalls
    ) external onlyOwner nonReentrant {
        // If swap calls provided, approve pool tokens to 1inch router and execute swaps
        uint256 swapCount = swapCalls.length;
        if (swapCount > 0) {
            if (vault == address(0)) revert InvalidTarget(); // Vault required for swaps
            
            // Get pool tokens from vault and approve them to 1inch router
            IBeefyVault vaultContract = IBeefyVault(vault);
            address pool = vaultContract.want();
            IUniswapV3Pool poolContract = IUniswapV3Pool(pool);
            address token0 = poolContract.token0();
            address token1 = poolContract.token1();
            
            // Approve pool tokens to 1inch router (unlimited approval)
            IERC20(token0).safeApprove(ONEINCH_ROUTER, 0);
            IERC20(token0).safeApprove(ONEINCH_ROUTER, type(uint256).max);
            IERC20(token1).safeApprove(ONEINCH_ROUTER, 0);
            IERC20(token1).safeApprove(ONEINCH_ROUTER, type(uint256).max);
            
            // Execute swaps
            for (uint256 i = 0; i < swapCount; i++) {
                SwapCall calldata swap = swapCalls[i];
                
                // Validate target is 1inch router
                if (swap.target != ONEINCH_ROUTER) revert InvalidTarget();
                
                // Execute swap
                (bool success, ) = swap.target.call{value: swap.value}(swap.data);
                if (!success) revert SwapFailed();
            }
        }
        
        // Transfer all USDC back to owner
        uint256 usdcBalance = IERC20(usdc).balanceOf(address(this));
        if (usdcBalance == 0) revert InsufficientBalance();
        
        IERC20(usdc).safeTransfer(owner, usdcBalance);
        
        emit DepositCancelled(usdcBalance);
    }

    /**
     * @notice Check if a vault is calm (ready for deposits)
     * @param vault Beefy vault address
     * @return bool True if vault is calm
     */
    function isVaultCalm(address vault) external view returns (bool) {
        return IBeefyVault(vault).isCalm();
    }

    /**
     * @notice Get vault shares balance for this wrapper
     * @param vault Beefy vault address
     * @return uint256 Vault shares balance
     */
    function getVaultShares(address vault) external view returns (uint256) {
        return IBeefyVault(vault).balanceOf(address(this));
    }

    /**
     * @notice Get token balance
     * @param token Token address
     * @return uint256 Token balance
     */
    function getTokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /**
     * @notice Update controller address (factory only)
     * @param _controller New controller address
     */
    function setController(address _controller) external onlyFactory {
        controller = _controller;
        emit ControllerUpdated(_controller);
    }

    /**
     * @notice Struct for swap call data
     */
    struct SwapCall {
        address target;    // 1inch router address
        bytes data;        // Swap calldata from 1inch API
        uint256 value;     // ETH value if needed
    }

    /**
     * @notice Allow contract to receive ETH (for native token swaps)
     */
    receive() external payable {}
}

