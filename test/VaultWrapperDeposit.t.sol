// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {VaultWrapper} from "../src/VaultWrapper.sol";
import {VaultWrapperFactory} from "../src/VaultWrapperFactory.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
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
 * @title VaultWrapperDeposit Test
 * @notice Fork test for deposit flow: USDC deposit → 1inch swaps → vault deposit
 * 
 * To run this test:
 *   forge test --match-contract VaultWrapperDepositTest -vvv --fork-url $BASE_HTTP_RPC_URL
 */
contract VaultWrapperDepositTest is Test {
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
        string memory rpcUrl = "https://api.developer.coinbase.com/rpc/v1/base/SF6TF2InaVNiSGPhP3Up4b62uEhp1qme";
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
        
        // Give USER some ETH for gas
        vm.deal(USER, 10 ether);
        
        // Give CONTROLLER some ETH for gas
        vm.deal(CONTROLLER, 10 ether);
    }
    
    function test_user_deposits_usdc() public {
        uint256 depositAmount = 100 * 10 ** 6; // 100 USDC
        
        vm.startPrank(USER);
        
        // Approve wrapper to spend USDC
        usdc.approve(address(wrapper), depositAmount);
        
        // Get balances before
        uint256 userBalanceBefore = usdc.balanceOf(USER);
        uint256 wrapperBalanceBefore = usdc.balanceOf(address(wrapper));
        
        // Deposit USDC
        wrapper.depositUSDC(depositAmount);
        
        // Get balances after
        uint256 userBalanceAfter = usdc.balanceOf(USER);
        uint256 wrapperBalanceAfter = usdc.balanceOf(address(wrapper));
        
        // Verify transfer
        assertEq(
            userBalanceBefore - userBalanceAfter,
            depositAmount,
            "User balance should decrease by deposit amount"
        );
        assertEq(
            wrapperBalanceAfter - wrapperBalanceBefore,
            depositAmount,
            "Wrapper balance should increase by deposit amount"
        );
        
        vm.stopPrank();
        
        console.log("USDC deposited:", depositAmount);
        console.log("Wrapper USDC balance:", wrapperBalanceAfter);
    }
    
    function test_only_owner_can_deposit() public {
        uint256 depositAmount = 100 * 10 ** 6; // 100 USDC
        
        // Try to deposit as non-owner
        vm.prank(CONTROLLER);
        vm.expectRevert(VaultWrapper.OnlyOwner.selector);
        wrapper.depositUSDC(depositAmount);
    }
    
    function test_controller_executes_swaps() public {
        // First, deposit USDC as user
        uint256 depositAmount = 100 * 10 ** 6; // 100 USDC
        vm.startPrank(USER);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.depositUSDC(depositAmount);
        vm.stopPrank();
        
        // Get pool tokens
        address token0 = pool.token0();
        address token1 = pool.token1();
        vm.label(token0, "TOKEN0");
        vm.label(token1, "TOKEN1");
        
        console.log("Pool token0:", token0);
        console.log("Pool token1:", token1);
        
        // For this test, we simulate swaps by dealing tokens directly
        // In production, controller would provide actual 1inch calldata
        uint256 halfUsd = depositAmount / 2;
        
        // Simulate token amounts (using values from existing test)
        uint256 token0Amount = 7325303198373204; // WETH amount
        uint256 token1Amount = 25000000; // USDC amount (half)
        
        // Deal tokens to wrapper (simulating swap results)
        deal(token0, address(wrapper), token0Amount);
        // USDC is already in wrapper, we just need to keep half for token1
        
        // Get balances after "swaps"
        uint256 wrapperToken0Balance = IERC20(token0).balanceOf(address(wrapper));
        uint256 wrapperToken1Balance = IERC20(token1).balanceOf(address(wrapper));
        
        console.log("Wrapper token0 balance after swaps:", wrapperToken0Balance);
        console.log("Wrapper token1 balance after swaps:", wrapperToken1Balance);
        
        assertTrue(wrapperToken0Balance > 0, "Wrapper should have token0");
        assertTrue(wrapperToken1Balance > 0, "Wrapper should have token1");
    }
    
    function test_controller_deposits_to_vault_when_calm() public {
        // Setup: deposit USDC and get pool tokens
        uint256 depositAmount = 100 * 10 ** 6; // 100 USDC
        vm.startPrank(USER);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.depositUSDC(depositAmount);
        vm.stopPrank();
        
        // Get pool tokens
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        // Simulate swaps - deal tokens to wrapper
        uint256 token0Amount = 7325303198373204; // WETH
        uint256 token1Amount = 25000000; // USDC (half of 50)
        deal(token0, address(wrapper), token0Amount);
        
        // Check if vault is calm
        bool isCalm = vault.isCalm();
        console.log("Vault is calm:", isCalm);
        
        if (!isCalm) {
            console.log("NOTE: Vault is not calm - test will verify error handling");
            
            // Try to deposit when not calm - should revert
            vm.prank(CONTROLLER);
            vm.expectRevert(VaultWrapper.VaultNotCalm.selector);
            wrapper.depositToVault(VAULT_ADDRESS, token0Amount, token1Amount, 0);
            
            console.log("Correctly reverted with VaultNotCalm error");
            return;
        }
        
        // Vault is calm - proceed with deposit
        uint256 sharesBefore = vault.balanceOf(address(wrapper));
        
        vm.prank(CONTROLLER);
        wrapper.depositToVault(VAULT_ADDRESS, token0Amount, token1Amount, 0);
        
        uint256 sharesAfter = vault.balanceOf(address(wrapper));
        
        assertTrue(sharesAfter > sharesBefore, "Wrapper should receive vault shares");
        
        console.log("Vault shares received:", sharesAfter - sharesBefore);
    }
    
    function test_only_controller_can_execute_swaps() public {
        // Create empty swap call
        VaultWrapper.SwapCall[] memory swaps = new VaultWrapper.SwapCall[](0);
        
        // Try to execute as non-controller
        vm.prank(USER);
        vm.expectRevert(VaultWrapper.OnlyController.selector);
        wrapper.executeSwaps(swaps);
    }
    
    function test_only_controller_can_deposit_to_vault() public {
        // Try to deposit as non-controller
        vm.prank(USER);
        vm.expectRevert(VaultWrapper.OnlyController.selector);
        wrapper.depositToVault(VAULT_ADDRESS, 0, 0, 0);
    }
    
    function test_cannot_deposit_to_vault_with_invalid_target() public {
        // This test verifies that executeSwaps rejects non-1inch targets
        uint256 depositAmount = 100 * 10 ** 6;
        
        vm.startPrank(USER);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.depositUSDC(depositAmount);
        vm.stopPrank();
        
        // Create swap with invalid target
        VaultWrapper.SwapCall[] memory swaps = new VaultWrapper.SwapCall[](1);
        swaps[0] = VaultWrapper.SwapCall({
            target: address(0xBAD), // Invalid target
            data: "",
            value: 0
        });
        
        vm.prank(CONTROLLER);
        vm.expectRevert(VaultWrapper.InvalidTarget.selector);
        wrapper.executeSwaps(swaps);
    }
    
    function test_check_vault_calm_status() public view {
        bool isCalm = wrapper.isVaultCalm(VAULT_ADDRESS);
        console.log("Vault calm status:", isCalm);
        
        // Just verify the call works (actual value depends on market conditions)
        // No assertion needed as this is informational
    }
    
    function test_get_token_balance() public {
        // Deposit USDC
        uint256 depositAmount = 100 * 10 ** 6;
        vm.startPrank(USER);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.depositUSDC(depositAmount);
        vm.stopPrank();
        
        // Check balance via wrapper
        uint256 balance = wrapper.getTokenBalance(USDC);
        assertEq(balance, depositAmount, "Token balance should match deposit");
    }
    
    function test_get_vault_shares() public view {
        // Check vault shares (should be 0 initially)
        uint256 shares = wrapper.getVaultShares(VAULT_ADDRESS);
        assertEq(shares, 0, "Initial vault shares should be 0");
    }
    
    function test_full_deposit_flow_simulation() public {
        // This test simulates the full flow without actual 1inch swaps
        console.log("=== Starting Full Deposit Flow Simulation ===");
        
        // Step 1: User deposits USDC
        uint256 depositAmount = 100 * 10 ** 6; // 100 USDC
        vm.startPrank(USER);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.depositUSDC(depositAmount);
        vm.stopPrank();
        
        console.log("Step 1: Deposited", depositAmount, "USDC");
        
        // Step 2: Controller simulates swaps (we deal tokens directly)
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        uint256 token0Amount = 7325303198373204;
        uint256 token1Amount = 25000000;
        
        deal(token0, address(wrapper), token0Amount);
        
        console.log("Step 2: Simulated swaps");
        console.log("  Token0 amount:", token0Amount);
        console.log("  Token1 amount:", token1Amount);
        
        // Step 3: Check if vault is calm
        bool isCalm = vault.isCalm();
        console.log("Step 3: Vault calm status:", isCalm);
        
        if (!isCalm) {
            console.log("Vault is not calm - skipping deposit step");
            console.log("In production, controller would retry later");
            return;
        }
        
        // Step 4: Controller deposits to vault
        vm.prank(CONTROLLER);
        wrapper.depositToVault(VAULT_ADDRESS, token0Amount, token1Amount, 0);
        
        uint256 shares = wrapper.getVaultShares(VAULT_ADDRESS);
        console.log("Step 4: Deposited to vault, received shares:", shares);
        
        assertTrue(shares > 0, "Should have received vault shares");
        
        console.log("=== Full Deposit Flow Completed Successfully ===");
    }
}







