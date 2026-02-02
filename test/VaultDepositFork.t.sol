// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

/**
 * Fork test for vault deposit from user's wallet
 * Tests the actual deposit flow without calm check
 *
 * To run this test:
 *   forge test --match-test test_vault_deposit_from_user_wallet -vvvv --fork-url $BASE_HTTP_RPC_URL
 */

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

interface IBeefyVault {
    function want() external view returns (address);
    function deposit(
        uint256 amount0,
        uint256 amount1,
        uint256 _minShares
    ) external;
    function balanceOf(address account) external view returns (uint256);
    function previewDeposit(
        uint256 _amount0,
        uint256 _amount1
    )
        external
        view
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1,
            uint256 fee0,
            uint256 fee1
        );
    function isCalm() external view returns (bool);
}

contract VaultDepositForkTest is Test {
    // Vault and pool addresses from the codebase
    address constant VAULT_ADDRESS = 0xd505Ce5D357F117C5Cb4E8A21c2656Bb2c60AcB2;
    address constant POOL_ADDRESS = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    
    // Base Mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    
    // Actual user wallet from the codebase
    address constant USER_WALLET = 0x5811F3BDd678d68b2fA1e107750017b68D2aBD92;
    
    // Test deposit amount: 50 USDC (6 decimals)
    uint256 constant DEPOSIT_AMOUNT_USD = 50 * 10 ** 6;
    
    // Interfaces
    IERC20 usdcToken;
    IUniswapV3Pool pool;
    IBeefyVault vault;

    function setUp() public {
        // Fork Base mainnet
        string memory rpcUrl = "https://mainnet.base.org";
        try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {}
        vm.createSelectFork(rpcUrl);

        // Label addresses for nicer traces
        vm.label(VAULT_ADDRESS, "BEEFY_VAULT");
        vm.label(POOL_ADDRESS, "UNIV3_POOL");
        vm.label(USDC, "USDC");
        vm.label(ONEINCH_ROUTER, "1INCH_ROUTER");
        vm.label(USER_WALLET, "USER_WALLET");

        // Initialize interfaces
        usdcToken = IERC20(USDC);
        pool = IUniswapV3Pool(POOL_ADDRESS);
        vault = IBeefyVault(VAULT_ADDRESS);

        // Give user some ETH for gas
        vm.deal(USER_WALLET, 10 ether);
    }

    function test_vault_deposit_from_user_wallet() public {
        console.log("\n=== Vault Deposit Fork Test ===");
        console.log("Testing deposit from user wallet without calm check");
        console.log("");

        // Log initial state
        console.log("Initial State:");
        console.log("  Vault:", VAULT_ADDRESS);
        console.log("  Pool:", POOL_ADDRESS);
        console.log("  User:", USER_WALLET);
        console.log("  Deposit Amount USD:", DEPOSIT_AMOUNT_USD);
        console.log("");

        // Check vault state
        console.log("Vault State:");
        bool isCalm = vault.isCalm();
        console.log("  isCalm:", isCalm);
        console.log("  NOTE: We're testing deposit WITHOUT calm check");
        address want = vault.want();
        console.log("  want():", want);
        console.log("");

        // Get pool tokens
        address token0 = pool.token0();
        address token1 = pool.token1();
        vm.label(token0, "TOKEN0");
        vm.label(token1, "TOKEN1");
        
        console.log("Pool Tokens:");
        console.log("  token0:", token0);
        console.log("  token1:", token1);
        console.log("");

        // Get token contracts
        IERC20 token0Contract = IERC20(token0);
        IERC20 token1Contract = IERC20(token1);
        
        // Get decimals
        uint8 dec0 = token0Contract.decimals();
        uint8 dec1 = token1Contract.decimals();
        
        console.log("Token Decimals:");
        console.log("  token0 decimals:", dec0);
        console.log("  token1 decimals:", dec1);
        console.log("");

        // Check user's current balances
        uint256 userUsdcBalance = usdcToken.balanceOf(USER_WALLET);
        uint256 userToken0Balance = token0Contract.balanceOf(USER_WALLET);
        uint256 userToken1Balance = token1Contract.balanceOf(USER_WALLET);
        
        console.log("User Current Balances:");
        console.log("  USDC balance:", userUsdcBalance);
        console.log("  Token0 balance:", userToken0Balance);
        console.log("  Token1 balance:", userToken1Balance);
        console.log("");

        // Check if user has enough USDC
        if (userUsdcBalance < DEPOSIT_AMOUNT_USD) {
            console.log("User doesn't have enough USDC, funding user...");
            deal(USDC, USER_WALLET, DEPOSIT_AMOUNT_USD, true);
            userUsdcBalance = usdcToken.balanceOf(USER_WALLET);
            console.log("  New USDC balance:", userUsdcBalance);
            console.log("");
        }

        // Start acting as the user
        vm.startPrank(USER_WALLET);

        // For this test, we'll simulate having the tokens already swapped
        // In production, these would come from 1inch swaps
        // Calculate approximate token amounts based on 50/50 split
        // We'll use previewDeposit to get reasonable amounts
        
        // First, let's try to get reasonable amounts by checking pool price
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = pool.slot0();
        console.log("Pool Price:");
        console.log("  sqrtPriceX96:", uint256(sqrtPriceX96));
        console.log("  tick:", uint256(int256(tick)));
        console.log("");

        // For simplicity, let's use a small test amount
        // Split 50 USDC: 25 USDC each token
        uint256 halfUsd = DEPOSIT_AMOUNT_USD / 2;
        
        // If token1 is USDC, we already have it
        bool token1IsUsdc = token1 == USDC;
        
        // For token0, we need to estimate based on price
        // For testing, let's use a small amount that should work
        // We'll fund the user with tokens directly for testing
        uint256 token0Amount;
        uint256 token1Amount = halfUsd; // If USDC, use half
        
        if (token1IsUsdc) {
            token1Amount = halfUsd;
            // Estimate token0 amount - use a reasonable small amount
            // In production, this would come from 1inch swap output
            token0Amount = 1000000000000000; // 0.001 WETH (18 decimals) - small test amount
        } else {
            // Both tokens need to be swapped
            token0Amount = 1000000000000000; // 0.001 WETH
            token1Amount = 1000000; // 1 token1 (assuming 6 decimals)
        }

        console.log("Test Deposit Amounts:");
        console.log("  token0Amount:", token0Amount);
        console.log("  token1Amount:", token1Amount);
        console.log("  token1IsUsdc:", token1IsUsdc);
        console.log("");

        // Fund user with tokens (simulating swap completion)
        if (token0Amount > 0 && token0 != USDC) {
            deal(token0, USER_WALLET, token0Amount);
        }
        if (token1Amount > 0 && !token1IsUsdc) {
            deal(token1, USER_WALLET, token1Amount);
        }

        // Check balances after funding
        userToken0Balance = token0Contract.balanceOf(USER_WALLET);
        userToken1Balance = token1Contract.balanceOf(USER_WALLET);
        
        console.log("User Balances After Funding:");
        console.log("  Token0 balance:", userToken0Balance);
        console.log("  Token1 balance:", userToken1Balance);
        console.log("  Has enough token0:", userToken0Balance >= token0Amount);
        console.log("  Has enough token1:", userToken1Balance >= token1Amount);
        console.log("");

        // Approve tokens to vault
        console.log("Approving tokens to vault...");
        uint256 MAX_UINT = type(uint256).max;
        token0Contract.approve(VAULT_ADDRESS, MAX_UINT);
        token1Contract.approve(VAULT_ADDRESS, MAX_UINT);
        
        uint256 allowance0 = token0Contract.allowance(USER_WALLET, VAULT_ADDRESS);
        uint256 allowance1 = token1Contract.allowance(USER_WALLET, VAULT_ADDRESS);
        
        console.log("  Token0 allowance:", allowance0);
        console.log("  Token1 allowance:", allowance1);
        console.log("");

        // Preview deposit
        console.log("Preview Deposit:");
        uint256 minShares = 0;
        try vault.previewDeposit(token0Amount, token1Amount) returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1,
            uint256 fee0,
            uint256 fee1
        ) {
            console.log("  Expected shares:", shares);
            console.log("  Actual amount0:", amount0);
            console.log("  Actual amount1:", amount1);
            console.log("  Fee0:", fee0);
            console.log("  Fee1:", fee1);
            // Use 0 for minShares to avoid slippage issues
            minShares = 0;
            console.log("  Min shares (set to 0):", minShares);
        } catch (bytes memory reason) {
            console.log("  previewDeposit FAILED:");
            console.logBytes(reason);
            console.log("  Continuing with minShares = 0");
        }
        console.log("");

        // Check vault balance before
        uint256 vaultBalanceBefore = vault.balanceOf(USER_WALLET);
        console.log("Vault balance before deposit:", vaultBalanceBefore);
        console.log("");

        // Execute deposit
        console.log("Executing Deposit:");
        console.log("  amount0:", token0Amount);
        console.log("  amount1:", token1Amount);
        console.log("  minShares:", minShares);
        console.log("");

        try vault.deposit(token0Amount, token1Amount, minShares) {
            console.log("SUCCESS: Deposit completed!");
            console.log("");

            uint256 vaultBalanceAfter = vault.balanceOf(USER_WALLET);
            uint256 sharesReceived = vaultBalanceAfter - vaultBalanceBefore;
            
            console.log("Deposit Results:");
            console.log("  Vault balance after:", vaultBalanceAfter);
            console.log("  Shares received:", sharesReceived);

            assertGt(
                vaultBalanceAfter,
                vaultBalanceBefore,
                "Vault balance should increase"
            );
        } catch (bytes memory reason) {
            console.log("FAILED: Deposit reverted!");
            console.log("");

            // Decode error
            if (reason.length >= 4) {
                bytes4 errorSelector = bytes4(reason);
                console.log("Error selector:");
                console.logBytes4(errorSelector);
                console.log("");

                // Common error selectors
                if (errorSelector == bytes4(0x26c87876)) {
                    console.log("Error: NotCalm() - Pool volatility is too high");
                    console.log("NOTE: This error should NOT occur since we removed calm check");
                } else if (errorSelector == bytes4(0xfb8f41b2)) {
                    console.log("Error: TransferFromFailed() - Token transfer failed");
                } else if (errorSelector == bytes4(0x3b6cc6d7)) {
                    console.log("Error: InsufficientBalance() - Not enough tokens");
                } else {
                    console.log("Error: Unknown error selector");
                }
                console.log("");
                console.log("Full error data:");
                console.logBytes(reason);
            } else {
                console.log("Error: No error data returned");
            }

            // Fail the test to show the error
            revert("Deposit failed - see logs above for details");
        }

        vm.stopPrank();
    }

    /**
     * Test with actual user balances - don't fund, use what they have
     */
    function test_vault_deposit_with_actual_user_balances() public {
        console.log("\n=== Test with Actual User Balances ===");
        console.log("");

        // Get pool tokens
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        IERC20 token0Contract = IERC20(token0);
        IERC20 token1Contract = IERC20(token1);

        // Check user's actual balances
        uint256 userToken0Balance = token0Contract.balanceOf(USER_WALLET);
        uint256 userToken1Balance = token1Contract.balanceOf(USER_WALLET);
        uint256 userUsdcBalance = usdcToken.balanceOf(USER_WALLET);
        
        console.log("User Actual Balances:");
        console.log("  Token0 balance:", userToken0Balance);
        console.log("  Token1 balance:", userToken1Balance);
        console.log("  USDC balance:", userUsdcBalance);
        console.log("");

        // Check vault calm state
        bool isCalm = vault.isCalm();
        console.log("Vault isCalm:", isCalm);
        console.log("");

        // If user has tokens, try to deposit with what they have
        if (userToken0Balance > 0 && userToken1Balance > 0) {
            console.log("User has tokens, attempting deposit...");
            
            vm.startPrank(USER_WALLET);
            
            // Approve vault
            uint256 MAX_UINT = type(uint256).max;
            token0Contract.approve(VAULT_ADDRESS, MAX_UINT);
            token1Contract.approve(VAULT_ADDRESS, MAX_UINT);
            
            // Try deposit with actual balances
            console.log("Attempting deposit with:");
            console.log("  amount0:", userToken0Balance);
            console.log("  amount1:", userToken1Balance);
            console.log("  minShares: 0");
            console.log("");

            try vault.deposit(userToken0Balance, userToken1Balance, 0) {
                console.log("SUCCESS: Deposit with actual balances worked!");
            } catch (bytes memory reason) {
                console.log("FAILED: Deposit with actual balances failed");
                if (reason.length >= 4) {
                    bytes4 errorSelector = bytes4(reason);
                    console.logBytes4(errorSelector);
                    console.logBytes(reason);
                }
                revert("Deposit failed with actual balances");
            }
            
            vm.stopPrank();
        } else {
            console.log("User doesn't have tokens, skipping deposit test");
        }
    }
}







