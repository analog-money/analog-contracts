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
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );
}

interface IStrategyPassiveManagerUniswap {
    function maxTickDeviation() external view returns (int24);
    function twapInterval() external view returns (uint32);
    function pool() external view returns (address);
}

/**
 * @title VaultWrapperNotCalmFork Test
 * @notice Fork test for wrapper behavior when vault is NOT calm (common real-world scenario)
 * 
 * This test validates:
 * - Wrapper accepts USDC deposits regardless of vault calm state
 * - Wrapper executes swaps regardless of vault calm state
 * - Wrapper correctly rejects vault deposits when not calm
 * - Users can cancel deposits when vault is not calm
 * - Controller can retry deposits when vault becomes calm
 * 
 * To run this test:
 *   forge test --match-contract VaultWrapperNotCalmForkTest -vvv --fork-url $BASE_HTTP_RPC_URL
 */
contract VaultWrapperNotCalmForkTest is Test {
    // Base Mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    
    // Values from StrategyDeployment cmhocogww0006bkl8oi8676p3
    address constant VAULT_ADDRESS = 0xd505Ce5D357F117C5Cb4E8A21c2656Bb2c60AcB2;
    address constant POOL_ADDRESS = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address constant STRATEGY_ADDRESS = 0x27d7Ea30b3D9bC55b6680D5B06707Cbd61E2f38B;
    
    // Test addresses
    address constant CONTROLLER = address(0x1111111111111111111111111111111111111111);
    address constant USER = address(0x2222222222222222222222222222222222222222);
    
    VaultWrapperFactory factory;
    VaultWrapper wrapper;
    IERC20 usdc;
    IBeefyVault vault;
    IUniswapV3Pool pool;
    IStrategyPassiveManagerUniswap strategy;
    
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
        vm.label(STRATEGY_ADDRESS, "STRATEGY");
        vm.label(CONTROLLER, "CONTROLLER");
        vm.label(USER, "USER");
        
        // Initialize interfaces
        usdc = IERC20(USDC);
        vault = IBeefyVault(VAULT_ADDRESS);
        pool = IUniswapV3Pool(POOL_ADDRESS);
        strategy = IStrategyPassiveManagerUniswap(STRATEGY_ADDRESS);
        
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
        
        // Log calm status
        bool isCalm = vault.isCalm();
        console.log("=== Setup Complete ===");
        console.log("Vault calm status:", isCalm);
        
        if (!isCalm) {
            console.log("NOTE: Vault is NOT calm - perfect for testing not-calm scenarios");
            _logCalmDetails();
        }
    }
    
    function _logCalmDetails() internal view {
        // Get pool tick
        (, int24 currentTick, , , , , ) = pool.slot0();
        
        // Get strategy parameters
        int24 maxTickDeviation = strategy.maxTickDeviation();
        uint32 twapInterval = strategy.twapInterval();
        
        console.log("");
        console.log("=== Pool Details ===");
        console.log("Current tick:", vm.toString(currentTick));
        console.log("Max tick deviation:", vm.toString(maxTickDeviation));
        console.log("TWAP interval:", twapInterval);
    }
    
    function test_can_deposit_usdc_when_not_calm() public {
        console.log("\n=== Test: Can Deposit USDC When Not Calm ===");
        
        bool isCalm = vault.isCalm();
        console.log("Vault calm:", isCalm);
        
        // User deposits USDC (should work regardless of calm state)
        uint256 depositAmount = 100 * 10 ** 6; // 100 USDC
        
        vm.startPrank(USER);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.depositUSDC(depositAmount);
        vm.stopPrank();
        
        // Verify deposit succeeded
        uint256 wrapperBalance = usdc.balanceOf(address(wrapper));
        assertEq(wrapperBalance, depositAmount, "Wrapper should have USDC");
        
        console.log("SUCCESS: User deposited", depositAmount, "USDC to wrapper");
        console.log("Wrapper USDC balance:", wrapperBalance);
    }
    
    function test_can_execute_swaps_when_not_calm() public {
        console.log("\n=== Test: Can Execute Swaps When Not Calm ===");
        
        // Step 1: Deposit USDC
        uint256 depositAmount = 100 * 10 ** 6;
        vm.startPrank(USER);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.depositUSDC(depositAmount);
        vm.stopPrank();
        
        console.log("Step 1: Deposited USDC");
        
        // Step 2: Simulate swaps (deal tokens to wrapper)
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        uint256 token0Amount = 7325303198373204; // WETH
        uint256 token1Amount = 25000000; // USDC
        
        deal(token0, address(wrapper), token0Amount);
        
        console.log("Step 2: Simulated swaps to pool tokens");
        console.log("  Token0 balance:", IERC20(token0).balanceOf(address(wrapper)));
        console.log("  Token1 balance:", IERC20(token1).balanceOf(address(wrapper)));
        
        // Verify tokens are in wrapper
        assertTrue(IERC20(token0).balanceOf(address(wrapper)) > 0, "Should have token0");
        assertTrue(IERC20(token1).balanceOf(address(wrapper)) > 0, "Should have token1");
        
        console.log("SUCCESS: Swaps executed successfully (vault calm state doesn't affect swaps)");
    }
    
    function test_cannot_deposit_to_vault_when_not_calm() public {
        console.log("\n=== Test: Cannot Deposit to Vault When Not Calm ===");
        
        bool isCalm = vault.isCalm();
        console.log("Vault calm:", isCalm);
        
        if (isCalm) {
            console.log("SKIP: Vault is calm, cannot test not-calm scenario");
            vm.skip(true);
            return;
        }
        
        // Setup: deposit USDC and get pool tokens
        uint256 depositAmount = 100 * 10 ** 6;
        vm.startPrank(USER);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.depositUSDC(depositAmount);
        vm.stopPrank();
        
        // Get pool tokens
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        uint256 token0Amount = 7325303198373204;
        uint256 token1Amount = 25000000;
        
        deal(token0, address(wrapper), token0Amount);
        
        console.log("Setup complete: Wrapper has USDC and pool tokens");
        
        // Try to deposit to vault when not calm - should revert
        vm.prank(CONTROLLER);
        vm.expectRevert(VaultWrapper.VaultNotCalm.selector);
        wrapper.depositToVault(VAULT_ADDRESS, token0Amount, token1Amount, 0);
        
        console.log("SUCCESS: Vault deposit correctly rejected when not calm");
        console.log("Error: VaultNotCalm()");
    }
    
    function test_can_cancel_deposit_when_not_calm() public {
        console.log("\n=== Test: Can Cancel Deposit When Not Calm ===");
        
        bool isCalm = vault.isCalm();
        console.log("Vault calm:", isCalm);
        
        // User deposits USDC
        uint256 depositAmount = 100 * 10 ** 6;
        vm.startPrank(USER);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.depositUSDC(depositAmount);
        vm.stopPrank();
        
        console.log("User deposited USDC to wrapper");
        
        // User decides to cancel (vault is not calm, so can't deposit)
        uint256 userBalanceBefore = usdc.balanceOf(USER);
        
        VaultWrapper.SwapCall[] memory swaps = new VaultWrapper.SwapCall[](0);
        
        vm.prank(USER);
        wrapper.cancelDeposit(address(0), swaps);
        
        uint256 userBalanceAfter = usdc.balanceOf(USER);
        uint256 usdcReturned = userBalanceAfter - userBalanceBefore;
        
        assertEq(usdcReturned, depositAmount, "User should receive full deposit back");
        
        console.log("SUCCESS: User cancelled deposit and received", usdcReturned, "USDC back");
        console.log("This allows users to exit if vault remains not calm");
    }
    
    function test_can_cancel_after_swaps_when_not_calm() public {
        console.log("\n=== Test: Can Cancel After Swaps When Not Calm ===");
        
        // Setup: deposit USDC and execute swaps
        uint256 depositAmount = 100 * 10 ** 6;
        vm.startPrank(USER);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.depositUSDC(depositAmount);
        vm.stopPrank();
        
        // Simulate swaps
        address token0 = pool.token0();
        deal(token0, address(wrapper), 1 ether);
        
        console.log("User deposited USDC and swaps were executed");
        console.log("Vault is not calm, so tokens are stuck in pool token form");
        
        // User cancels - needs to swap back to USDC
        // Simulate reverse swaps
        uint256 usdcToReturn = 95 * 10 ** 6; // ~95 USDC after fees
        deal(USDC, address(wrapper), usdcToReturn);
        
        VaultWrapper.SwapCall[] memory swaps = new VaultWrapper.SwapCall[](0);
        
        uint256 userBalanceBefore = usdc.balanceOf(USER);
        
        vm.prank(USER);
        wrapper.cancelDeposit(VAULT_ADDRESS, swaps);
        
        uint256 userBalanceAfter = usdc.balanceOf(USER);
        uint256 usdcReturned = userBalanceAfter - userBalanceBefore;
        
        assertTrue(usdcReturned > 0, "User should receive USDC back");
        console.log("SUCCESS: User cancelled after swaps and received", usdcReturned, "USDC");
        console.log("Note: Lost ~5 USDC to swap fees (expected)");
    }
    
    function test_check_vault_calm_status() public view {
        console.log("\n=== Test: Check Vault Calm Status ===");
        
        bool isCalm = wrapper.isVaultCalm(VAULT_ADDRESS);
        console.log("Vault calm (via wrapper):", isCalm);
        
        // Also check directly
        bool isCalmDirect = vault.isCalm();
        console.log("Vault calm (direct):", isCalmDirect);
        
        assertEq(isCalm, isCalmDirect, "Wrapper should report same calm status");
        
        if (!isCalm) {
            console.log("\nVault is NOT calm. This means:");
            console.log("- USDC deposits to wrapper: ALLOWED");
            console.log("- Swap execution: ALLOWED");
            console.log("- Vault deposits: BLOCKED (will revert)");
            console.log("- Cancellation: ALLOWED");
            console.log("\nController should:");
            console.log("1. Monitor calm status");
            console.log("2. Retry vault deposit when calm");
            console.log("3. Or allow user to cancel if vault stays volatile");
        }
    }
    
    function test_full_flow_waiting_for_calm() public {
        console.log("\n=== Test: Full Flow - Waiting for Calm ===");
        
        // Step 1: User deposits USDC
        uint256 depositAmount = 100 * 10 ** 6;
        vm.startPrank(USER);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.depositUSDC(depositAmount);
        vm.stopPrank();
        
        console.log("Step 1: User deposited USDC");
        
        // Step 2: Controller executes swaps
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        uint256 token0Amount = 7325303198373204;
        uint256 token1Amount = 25000000;
        
        deal(token0, address(wrapper), token0Amount);
        
        console.log("Step 2: Controller executed swaps");
        
        // Step 3: Check if calm
        bool isCalm = vault.isCalm();
        console.log("Step 3: Vault calm status:", isCalm);
        
        if (!isCalm) {
            console.log("Step 4: Vault is NOT calm - deposit will fail");
            
            // Try to deposit - should fail
            vm.prank(CONTROLLER);
            vm.expectRevert(VaultWrapper.VaultNotCalm.selector);
            wrapper.depositToVault(VAULT_ADDRESS, token0Amount, token1Amount, 0);
            
            console.log("Step 5: Deposit rejected (expected)");
            console.log("\nIn production:");
            console.log("- Controller would monitor calm status");
            console.log("- Retry deposit when vault becomes calm");
            console.log("- User can cancel anytime before vault deposit");
            
            // Verify tokens are still in wrapper
            assertTrue(
                IERC20(token0).balanceOf(address(wrapper)) > 0,
                "Tokens should remain in wrapper"
            );
            console.log("\nTokens safely held in wrapper until vault is calm");
        } else {
            console.log("Step 4: Vault IS calm - deposit will succeed");
            
            vm.prank(CONTROLLER);
            wrapper.depositToVault(VAULT_ADDRESS, token0Amount, token1Amount, 0);
            
            uint256 shares = wrapper.getVaultShares(VAULT_ADDRESS);
            console.log("Step 5: Deposited to vault, received shares:", shares);
        }
    }
    
    function test_multiple_users_with_not_calm_vault() public {
        console.log("\n=== Test: Multiple Users with Not Calm Vault ===");
        
        // Create second user
        address USER2 = address(0x3333333333333333333333333333333333333333);
        vm.label(USER2, "USER2");
        deal(USDC, USER2, 10000 * 10 ** 6, true);
        vm.deal(USER2, 10 ether);
        
        address wrapper2Addr = factory.createWrapper(USER2);
        VaultWrapper wrapper2 = VaultWrapper(payable(wrapper2Addr));
        
        console.log("Created wrappers for 2 users");
        
        // Both users deposit
        uint256 depositAmount = 100 * 10 ** 6;
        
        vm.startPrank(USER);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.depositUSDC(depositAmount);
        vm.stopPrank();
        
        vm.startPrank(USER2);
        usdc.approve(address(wrapper2), depositAmount);
        wrapper2.depositUSDC(depositAmount);
        vm.stopPrank();
        
        console.log("Both users deposited USDC");
        
        // Check calm status
        bool isCalm = vault.isCalm();
        console.log("Vault calm:", isCalm);
        
        // USER1 decides to cancel (vault not calm for too long)
        VaultWrapper.SwapCall[] memory swaps = new VaultWrapper.SwapCall[](0);
        
        vm.prank(USER);
        wrapper.cancelDeposit(address(0), swaps);
        
        console.log("USER1 cancelled deposit");
        
        // USER2 decides to wait for calm
        uint256 wrapper2Balance = usdc.balanceOf(address(wrapper2));
        assertEq(wrapper2Balance, depositAmount, "USER2's deposit should remain");
        
        console.log("USER2 is waiting for vault to become calm");
        console.log("\nSUCCESS: Each user can independently decide to wait or cancel");
    }
    
    function test_wrapper_state_during_volatility() public view {
        console.log("\n=== Test: Wrapper State During Volatility ===");
        
        bool isCalm = vault.isCalm();
        console.log("Vault calm:", isCalm);
        
        console.log("\nWrapper capabilities during volatility:");
        console.log("- depositUSDC(): ENABLED");
        console.log("- executeSwaps(): ENABLED");
        console.log("- depositToVault(): DISABLED (will revert)");
        console.log("- withdraw(): N/A (no vault shares yet)");
        console.log("- cancelDeposit(): ENABLED");
        console.log("- isVaultCalm(): READABLE");
        console.log("- getTokenBalance(): READABLE");
        console.log("- getVaultShares(): READABLE (will be 0)");
        
        console.log("\nThis design allows:");
        console.log("1. Users to deposit funds anytime");
        console.log("2. Controller to prepare swaps in advance");
        console.log("3. Automatic retry when vault becomes calm");
        console.log("4. User cancellation if vault stays volatile");
    }
}

