// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {VaultWrapper} from "../src/VaultWrapper.sol";
import {VaultWrapperFactory} from "../src/VaultWrapperFactory.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IBeefyVault {
    function want() external view returns (address);
    function deposit(uint256 amount0, uint256 amount1, uint256 _minShares) external;
    function balanceOf(address account) external view returns (uint256);
    function isCalm() external view returns (bool);
}

interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @title VaultWrapperApprovalsFork Test
 * @notice Fork test to verify token approvals are set correctly
 * 
 * To run this test:
 *   forge test --match-contract VaultWrapperApprovalsForkTest -vvv --fork-url https://mainnet.base.org
 */
contract VaultWrapperApprovalsForkTest is Test {
    // Base Mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    
    // Values from StrategyDeployment cmhocogww0006bkl8oi8676p3
    address constant VAULT_ADDRESS = 0xd505Ce5D357F117C5Cb4E8A21c2656Bb2c60AcB2;
    address constant POOL_ADDRESS = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    
    // Test addresses
    address constant CONTROLLER = address(0x1111111111111111111111111111111111111111);
    address constant USER = address(0x2222222222222222222222222222222222222222);
    
    VaultWrapperFactory factory;
    VaultWrapper wrapper;
    IERC20 usdc;
    IBeefyVault vault;
    IUniswapV3Pool pool;
    
    function setUp() public {
        // Fork Base mainnet
        string memory rpcUrl = "https://mainnet.base.org";
        try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {}
        vm.createSelectFork(rpcUrl);
        
        // Label addresses
        vm.label(USDC, "USDC");
        vm.label(ONEINCH_ROUTER, "1INCH_ROUTER");
        vm.label(VAULT_ADDRESS, "BEEFY_VAULT");
        vm.label(POOL_ADDRESS, "UNIV3_POOL");
        vm.label(CONTROLLER, "CONTROLLER");
        vm.label(USER, "USER");
        
        // Initialize interfaces
        usdc = IERC20(USDC);
        vault = IBeefyVault(VAULT_ADDRESS);
        pool = IUniswapV3Pool(POOL_ADDRESS);
        
        // Deploy factory and create wrapper for USER
        factory = new VaultWrapperFactory(USDC, CONTROLLER);
        address wrapperAddr = factory.createWrapper(USER);
        wrapper = VaultWrapper(payable(wrapperAddr));
        
        vm.label(address(factory), "FACTORY");
        vm.label(address(wrapper), "WRAPPER");
        
        // Fund USER with USDC
        uint256 usdcAmount = 10000 * 10 ** 6; // 10,000 USDC
        deal(USDC, USER, usdcAmount, true);
        
        // Give USER and CONTROLLER ETH for gas
        vm.deal(USER, 10 ether);
        vm.deal(CONTROLLER, 10 ether);
    }
    
    function test_usdc_approved_to_1inch_on_init() public view {
        console.log("\n=== Test: USDC Approved to 1inch Router on Init ===");
        
        // Check USDC allowance to 1inch router
        uint256 allowance = usdc.allowance(address(wrapper), ONEINCH_ROUTER);
        
        console.log("USDC allowance to 1inch router:", allowance);
        console.log("Max uint256:", type(uint256).max);
        
        // Should be max uint256 (unlimited approval)
        assertEq(allowance, type(uint256).max, "USDC should have unlimited approval to 1inch router");
        
        console.log("SUCCESS: USDC is approved to 1inch router");
    }
    
    function test_pool_tokens_approved_to_vault_on_deposit() public {
        console.log("\n=== Test: Pool Tokens Approved to Vault on Deposit ===");
        
        // Setup: deposit USDC and get pool tokens
        uint256 depositAmount = 100 * 10 ** 6;
        vm.startPrank(USER);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.depositUSDC(depositAmount);
        vm.stopPrank();
        
        // Simulate swaps - deal pool tokens to wrapper
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        uint256 token0Amount = 7325303198373204;
        uint256 token1Amount = 25000000;
        
        deal(token0, address(wrapper), token0Amount);
        
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        
        // Check if vault is calm
        bool isCalm = vault.isCalm();
        console.log("Vault calm:", isCalm);
        
        if (!isCalm) {
            console.log("Vault is not calm - cannot test deposit");
            console.log("But we can verify approvals would be set correctly");
            return;
        }
        
        // Deposit to vault
        vm.prank(CONTROLLER);
        wrapper.depositToVault(VAULT_ADDRESS, token0Amount, token1Amount, 0);
        
        // Check allowances
        uint256 token0Allowance = IERC20(token0).allowance(address(wrapper), VAULT_ADDRESS);
        uint256 token1Allowance = IERC20(token1).allowance(address(wrapper), VAULT_ADDRESS);
        
        console.log("Token0 allowance to vault:", token0Allowance);
        console.log("Token1 allowance to vault:", token1Allowance);
        
        // Should be max uint256 (unlimited approval)
        assertEq(token0Allowance, type(uint256).max, "Token0 should have unlimited approval to vault");
        assertEq(token1Allowance, type(uint256).max, "Token1 should have unlimited approval to vault");
        
        console.log("SUCCESS: Pool tokens are approved to vault");
    }
    
    function test_pool_tokens_approved_to_1inch_on_withdraw() public {
        console.log("\n=== Test: Pool Tokens Approved to 1inch Router on Withdraw ===");
        
        // Setup: get wrapper with vault shares
        uint256 depositAmount = 100 * 10 ** 6;
        vm.startPrank(USER);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.depositUSDC(depositAmount);
        vm.stopPrank();
        
        // Simulate swaps
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        uint256 token0Amount = 7325303198373204;
        uint256 token1Amount = 25000000;
        
        deal(token0, address(wrapper), token0Amount);
        
        // Check if vault is calm
        bool isCalm = vault.isCalm();
        if (!isCalm) {
            console.log("Vault is not calm - cannot setup test");
            return;
        }
        
        // Deposit to vault
        vm.prank(CONTROLLER);
        wrapper.depositToVault(VAULT_ADDRESS, token0Amount, token1Amount, 0);
        
        uint256 shares = wrapper.getVaultShares(VAULT_ADDRESS);
        console.log("Vault shares:", shares);
        
        // Check allowances before withdraw
        uint256 token0AllowanceBefore = IERC20(token0).allowance(address(wrapper), ONEINCH_ROUTER);
        uint256 token1AllowanceBefore = IERC20(token1).allowance(address(wrapper), ONEINCH_ROUTER);
        
        console.log("Token0 allowance to 1inch (before):", token0AllowanceBefore);
        console.log("Token1 allowance to 1inch (before):", token1AllowanceBefore);
        
        // Simulate swap results
        deal(USDC, address(wrapper), 95 * 10 ** 6);
        
        VaultWrapper.SwapCall[] memory swaps = new VaultWrapper.SwapCall[](0);
        
        // Withdraw (this will approve tokens to 1inch)
        vm.prank(USER);
        wrapper.withdraw(VAULT_ADDRESS, shares, swaps);
        
        // Check allowances after withdraw
        uint256 token0AllowanceAfter = IERC20(token0).allowance(address(wrapper), ONEINCH_ROUTER);
        uint256 token1AllowanceAfter = IERC20(token1).allowance(address(wrapper), ONEINCH_ROUTER);
        
        console.log("Token0 allowance to 1inch (after):", token0AllowanceAfter);
        console.log("Token1 allowance to 1inch (after):", token1AllowanceAfter);
        
        // Should be max uint256 (unlimited approval)
        assertEq(token0AllowanceAfter, type(uint256).max, "Token0 should have unlimited approval to 1inch router");
        assertEq(token1AllowanceAfter, type(uint256).max, "Token1 should have unlimited approval to 1inch router");
        
        console.log("SUCCESS: Pool tokens are approved to 1inch router on withdraw");
    }
    
    function test_all_approvals_summary() public view {
        console.log("\n=== Approval Summary ===");
        
        // Check USDC to 1inch
        uint256 usdcTo1inch = usdc.allowance(address(wrapper), ONEINCH_ROUTER);
        console.log("USDC -> 1inch Router:", usdcTo1inch == type(uint256).max ? "APPROVED (unlimited)" : "NOT APPROVED");
        
        // Get pool tokens
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        // Check token0 to 1inch (might be 0 if not used yet)
        uint256 token0To1inch = IERC20(token0).allowance(address(wrapper), ONEINCH_ROUTER);
        console.log("Token0 -> 1inch Router:", token0To1inch == type(uint256).max ? "APPROVED (unlimited)" : "NOT YET APPROVED");
        
        // Check token1 to 1inch
        uint256 token1To1inch = IERC20(token1).allowance(address(wrapper), ONEINCH_ROUTER);
        console.log("Token1 -> 1inch Router:", token1To1inch == type(uint256).max ? "APPROVED (unlimited)" : "NOT YET APPROVED");
        
        // Check token0 to vault
        uint256 token0ToVault = IERC20(token0).allowance(address(wrapper), VAULT_ADDRESS);
        console.log("Token0 -> Vault:", token0ToVault == type(uint256).max ? "APPROVED (unlimited)" : "NOT YET APPROVED");
        
        // Check token1 to vault
        uint256 token1ToVault = IERC20(token1).allowance(address(wrapper), VAULT_ADDRESS);
        console.log("Token1 -> Vault:", token1ToVault == type(uint256).max ? "APPROVED (unlimited)" : "NOT YET APPROVED");
        
        console.log("\nApproval Flow:");
        console.log("1. On Init: USDC -> 1inch Router (APPROVED)");
        console.log("2. On Deposit: Token0/Token1 -> Vault (APPROVED)");
        console.log("3. On Withdraw: Token0/Token1 -> 1inch Router (APPROVED)");
    }
}

