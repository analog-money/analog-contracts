// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SimpleWithdrawalDebug
 * @notice Minimal test to debug withdrawal balance calculations
 * @dev Run with: forge test --match-contract SimpleWithdrawalDebug --fork-url $BASE_RPC_URL -vvv
 */
contract SimpleWithdrawalDebug is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    
    // Use an existing deployed vault from production
    // Replace with actual vault address that's experiencing the issue
    address constant EXISTING_VAULT = 0x0000000000000000000000000000000000000000; // TODO: Set actual vault
    
    function testCalculateWithdrawalAmounts() public view {
        console.log("=== Withdrawal Amount Calculation Test ===\n");
        
        // Simulate vault state
        uint256 mockVaultEquity = 9_999_999; // ~10 USDC after fees
        uint256 mockIdleUsdc = 1_000_000; // 1 USDC idle
        uint256 mockStrategyBal0 = 0; // USDC in strategy
        uint256 mockStrategyBal1 = 8_999_999; // WETH in strategy
        
        console.log("Mock Vault State:");
        console.log("  Vault Equity:", mockVaultEquity);
        console.log("  Idle USDC:", mockIdleUsdc);
        console.log("  Strategy token0 (USDC):", mockStrategyBal0);
        console.log("  Strategy token1 (WETH):", mockStrategyBal1);
        
        // User requests 97% withdrawal
        uint256 requestedAmount = (mockVaultEquity * 97) / 100;
        console.log("\nRequested withdrawal (97%):", requestedAmount);
        
        // Calculate needed from AMM
        uint256 neededFromAMM = requestedAmount > mockIdleUsdc 
            ? requestedAmount - mockIdleUsdc 
            : 0;
        console.log("Needed from AMM:", neededFromAMM);
        
        // Calculate withdrawal amounts (BEFORE beforeAction)
        uint256 totalStrategyValue = mockStrategyBal0 + mockStrategyBal1;
        uint256 withdraw0 = (mockStrategyBal0 * neededFromAMM) / mockVaultEquity;
        uint256 withdraw1 = (mockStrategyBal1 * neededFromAMM) / mockVaultEquity;
        
        console.log("\nWithdrawal amounts (BEFORE beforeAction):");
        console.log("  withdraw0 (USDC):", withdraw0);
        console.log("  withdraw1 (WETH):", withdraw1);
        
        // After withdrawal, we have:
        uint256 totalUsdc = mockIdleUsdc + withdraw0;
        uint256 totalWeth = withdraw1;
        
        console.log("\nAfter withdrawal (before swap):");
        console.log("  Total USDC:", totalUsdc);
        console.log("  Total WETH:", totalWeth);
        
        // Simulate WETH->USDC swap with 1% slippage
        uint256 wethToUsdcValue = totalWeth; // Assume 1:1 for simplicity
        uint256 usdcFromSwap = (wethToUsdcValue * 99) / 100; // 1% slippage
        
        uint256 finalUsdc = totalUsdc + usdcFromSwap;
        
        console.log("\nAfter WETH->USDC swap (1% slippage):");
        console.log("  USDC from swap:", usdcFromSwap);
        console.log("  Final USDC:", finalUsdc);
        
        console.log("\nComparison:");
        console.log("  Requested:", requestedAmount);
        console.log("  Available:", finalUsdc);
        console.log("  Sufficient?", finalUsdc >= requestedAmount ? "YES" : "NO");
        
        if (finalUsdc < requestedAmount) {
            console.log("  Shortfall:", requestedAmount - finalUsdc);
        }
    }
    
    function testCorrectCalculation() public view {
        console.log("\n=== CORRECT Calculation (using original balances) ===\n");
        
        uint256 mockVaultEquity = 9_999_999;
        uint256 mockIdleUsdc = 1_000_000;
        uint256 mockStrategyBal0 = 0; // BEFORE beforeAction
        uint256 mockStrategyBal1 = 8_999_999; // BEFORE beforeAction
        
        uint256 requestedAmount = (mockVaultEquity * 97) / 100;
        uint256 neededFromAMM = requestedAmount - mockIdleUsdc;
        
        // CORRECT: Calculate based on ORIGINAL balances
        uint256 withdraw0 = (mockStrategyBal0 * neededFromAMM) / mockVaultEquity;
        uint256 withdraw1 = (mockStrategyBal1 * neededFromAMM) / mockVaultEquity;
        
        console.log("Using ORIGINAL balances:");
        console.log("  withdraw0:", withdraw0);
        console.log("  withdraw1:", withdraw1);
        console.log("  Total requested from strategy:", withdraw0 + withdraw1);
        console.log("  Needed from AMM:", neededFromAMM);
    }
    
    function testIncorrectCalculation() public view {
        console.log("\n=== INCORRECT Calculation (using post-beforeAction balances) ===\n");
        
        uint256 mockVaultEquity = 9_999_999;
        uint256 mockIdleUsdc = 1_000_000;
        
        // AFTER beforeAction, ALL liquidity is removed, so strategy has EVERYTHING
        uint256 strategyBal0AfterRemoval = 0;
        uint256 strategyBal1AfterRemoval = 8_999_999; // ALL tokens now idle in strategy
        
        uint256 requestedAmount = (mockVaultEquity * 97) / 100;
        uint256 neededFromAMM = requestedAmount - mockIdleUsdc;
        
        // INCORRECT: Calculate based on POST-removal balances
        uint256 withdraw0 = (strategyBal0AfterRemoval * neededFromAMM) / mockVaultEquity;
        uint256 withdraw1 = (strategyBal1AfterRemoval * neededFromAMM) / mockVaultEquity;
        
        console.log("Using POST-beforeAction balances:");
        console.log("  withdraw0:", withdraw0);
        console.log("  withdraw1:", withdraw1);
        console.log("  Total requested from strategy:", withdraw0 + withdraw1);
        console.log("  Needed from AMM:", neededFromAMM);
        console.log("\nPROBLEM: We're requesting the correct proportion, but from the WRONG total!");
    }
}
