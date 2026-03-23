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
    function withdraw(uint256 shares) external;
    function balanceOf(address account) external view returns (uint256);
    function isCalm() external view returns (bool);
}

interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @title VaultWrapperWithdraw Test
 * @notice Fork test for withdrawal flow: vault shares → pool tokens → USDC
 * 
 * To run this test:
 *   forge test --match-contract VaultWrapperWithdrawTest -vvv --fork-url $BASE_HTTP_RPC_URL
 */
contract VaultWrapperWithdrawTest is Test {
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
    
    /**
     * @notice Helper to setup wrapper with vault shares
     * @dev Deposits USDC, simulates swaps, and deposits to vault
     */
    function _setupWrapperWithShares() internal returns (uint256 shares) {
        // Step 1: User deposits USDC
        uint256 depositAmount = 100 * 10 ** 6; // 100 USDC
        vm.startPrank(USER);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.depositUSDC(depositAmount);
        vm.stopPrank();
        
        // Step 2: Simulate swaps - deal pool tokens to wrapper
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        uint256 token0Amount = 7325303198373204; // WETH
        uint256 token1Amount = 25000000; // USDC
        
        deal(token0, address(wrapper), token0Amount);
        
        // Step 3: Check if vault is calm
        bool isCalm = vault.isCalm();
        if (!isCalm) {
            console.log("Vault is not calm - cannot setup test");
            return 0;
        }
        
        // Step 4: Controller deposits to vault
        vm.prank(CONTROLLER);
        wrapper.depositToVault(VAULT_ADDRESS, token0Amount, token1Amount, 0);
        
        shares = wrapper.getVaultShares(VAULT_ADDRESS);
        console.log("Setup complete - wrapper has shares:", shares);
        
        return shares;
    }
    
    function test_user_withdraws_from_vault() public {
        // Setup: get wrapper with vault shares
        uint256 shares = _setupWrapperWithShares();
        
        if (shares == 0) {
            console.log("Skipping test - vault is not calm");
            return;
        }
        
        // Get pool tokens
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        // Simulate withdrawal and swaps back to USDC
        // In production, user would call withdraw with swap calldata from server
        
        // For this test, we'll simulate by:
        // 1. Withdrawing from vault (receives pool tokens)
        // 2. Dealing USDC to wrapper (simulating swaps)
        // 3. Checking user receives USDC
        
        uint256 userUsdcBefore = usdc.balanceOf(USER);
        
        // Create empty swap calls (we'll deal USDC directly)
        VaultWrapper.SwapCall[] memory swaps = new VaultWrapper.SwapCall[](0);
        
        // Deal USDC to wrapper to simulate swap results
        uint256 expectedUsdc = 95 * 10 ** 6; // ~95 USDC after fees/slippage
        
        // Execute withdraw as USER
        vm.startPrank(USER);
        
        // First withdraw from vault (this will fail if we try to call it directly)
        // Instead, we need to simulate the full withdraw flow
        // Let's deal USDC to wrapper and then call withdraw
        deal(USDC, address(wrapper), expectedUsdc);
        
        wrapper.withdraw(VAULT_ADDRESS, shares, swaps);
        
        vm.stopPrank();
        
        uint256 userUsdcAfter = usdc.balanceOf(USER);
        uint256 usdcReceived = userUsdcAfter - userUsdcBefore;
        
        assertTrue(usdcReceived > 0, "User should receive USDC");
        console.log("USDC received by user:", usdcReceived);
    }
    
    function test_only_owner_can_withdraw() public {
        // Setup shares
        uint256 shares = _setupWrapperWithShares();
        
        if (shares == 0) {
            console.log("Skipping test - vault is not calm");
            return;
        }
        
        // Try to withdraw as non-owner
        VaultWrapper.SwapCall[] memory swaps = new VaultWrapper.SwapCall[](0);
        
        vm.prank(CONTROLLER);
        vm.expectRevert(VaultWrapper.OnlyOwner.selector);
        wrapper.withdraw(VAULT_ADDRESS, shares, swaps);
    }
    
    function test_cannot_withdraw_without_shares() public {
        // Try to withdraw without having shares
        VaultWrapper.SwapCall[] memory swaps = new VaultWrapper.SwapCall[](0);
        
        vm.prank(USER);
        vm.expectRevert(VaultWrapper.InsufficientBalance.selector);
        wrapper.withdraw(VAULT_ADDRESS, 1, swaps);
    }
    
    function test_cannot_withdraw_more_than_balance() public {
        // Setup shares
        uint256 shares = _setupWrapperWithShares();
        
        if (shares == 0) {
            console.log("Skipping test - vault is not calm");
            return;
        }
        
        // Try to withdraw more shares than balance
        VaultWrapper.SwapCall[] memory swaps = new VaultWrapper.SwapCall[](0);
        
        vm.prank(USER);
        vm.expectRevert(VaultWrapper.InsufficientBalance.selector);
        wrapper.withdraw(VAULT_ADDRESS, shares + 1, swaps);
    }
    
    function test_withdraw_rejects_invalid_swap_target() public {
        // Setup shares
        uint256 shares = _setupWrapperWithShares();
        
        if (shares == 0) {
            console.log("Skipping test - vault is not calm");
            return;
        }
        
        // Create swap with invalid target
        VaultWrapper.SwapCall[] memory swaps = new VaultWrapper.SwapCall[](1);
        swaps[0] = VaultWrapper.SwapCall({
            target: address(0xBAD),
            data: "",
            value: 0
        });
        
        vm.prank(USER);
        vm.expectRevert(VaultWrapper.InvalidTarget.selector);
        wrapper.withdraw(VAULT_ADDRESS, shares, swaps);
    }
    
    function test_partial_withdrawal() public {
        // Setup shares
        uint256 totalShares = _setupWrapperWithShares();
        
        if (totalShares == 0) {
            console.log("Skipping test - vault is not calm");
            return;
        }
        
        // Withdraw half of shares
        uint256 withdrawShares = totalShares / 2;
        
        // Simulate swap results by dealing USDC
        uint256 expectedUsdc = 47 * 10 ** 6; // ~47 USDC (half of ~95)
        deal(USDC, address(wrapper), expectedUsdc);
        
        VaultWrapper.SwapCall[] memory swaps = new VaultWrapper.SwapCall[](0);
        
        vm.prank(USER);
        wrapper.withdraw(VAULT_ADDRESS, withdrawShares, swaps);
        
        // Check remaining shares
        uint256 remainingShares = wrapper.getVaultShares(VAULT_ADDRESS);
        assertTrue(remainingShares > 0, "Should have remaining shares");
        
        console.log("Withdrew shares:", withdrawShares);
        console.log("Remaining shares:", remainingShares);
    }
    
    function test_full_roundtrip_simulation() public {
        console.log("=== Starting Full Roundtrip Simulation ===");
        
        // Step 1: User deposits USDC
        uint256 depositAmount = 100 * 10 ** 6; // 100 USDC
        vm.startPrank(USER);
        usdc.approve(address(wrapper), depositAmount);
        wrapper.depositUSDC(depositAmount);
        vm.stopPrank();
        
        console.log("Step 1: User deposited", depositAmount, "USDC");
        
        // Step 2: Simulate swaps to pool tokens
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        uint256 token0Amount = 7325303198373204;
        uint256 token1Amount = 25000000;
        
        deal(token0, address(wrapper), token0Amount);
        
        console.log("Step 2: Swapped to pool tokens");
        
        // Step 3: Check if vault is calm
        bool isCalm = vault.isCalm();
        console.log("Step 3: Vault calm status:", isCalm);
        
        if (!isCalm) {
            console.log("Vault is not calm - cannot complete roundtrip");
            return;
        }
        
        // Step 4: Deposit to vault
        vm.prank(CONTROLLER);
        wrapper.depositToVault(VAULT_ADDRESS, token0Amount, token1Amount, 0);
        
        uint256 shares = wrapper.getVaultShares(VAULT_ADDRESS);
        console.log("Step 4: Deposited to vault, shares:", shares);
        
        // Step 5: Withdraw from vault
        uint256 expectedUsdcBack = 95 * 10 ** 6; // ~95 USDC (accounting for fees)
        deal(USDC, address(wrapper), expectedUsdcBack);
        
        VaultWrapper.SwapCall[] memory swaps = new VaultWrapper.SwapCall[](0);
        
        uint256 userUsdcBefore = usdc.balanceOf(USER);
        
        vm.prank(USER);
        wrapper.withdraw(VAULT_ADDRESS, shares, swaps);
        
        uint256 userUsdcAfter = usdc.balanceOf(USER);
        uint256 usdcReceived = userUsdcAfter - userUsdcBefore;
        
        console.log("Step 5: Withdrew and received", usdcReceived, "USDC");
        
        assertTrue(usdcReceived > 0, "User should receive USDC");
        console.log("=== Roundtrip Completed Successfully ===");
    }
    
    function test_withdraw_updates_vault_shares_balance() public {
        // Setup shares
        uint256 sharesBefore = _setupWrapperWithShares();
        
        if (sharesBefore == 0) {
            console.log("Skipping test - vault is not calm");
            return;
        }
        
        // Simulate swap results
        deal(USDC, address(wrapper), 95 * 10 ** 6);
        
        VaultWrapper.SwapCall[] memory swaps = new VaultWrapper.SwapCall[](0);
        
        vm.prank(USER);
        wrapper.withdraw(VAULT_ADDRESS, sharesBefore, swaps);
        
        uint256 sharesAfter = wrapper.getVaultShares(VAULT_ADDRESS);
        
        assertEq(sharesAfter, 0, "All shares should be withdrawn");
        console.log("Shares before:", sharesBefore);
        console.log("Shares after:", sharesAfter);
    }
}







