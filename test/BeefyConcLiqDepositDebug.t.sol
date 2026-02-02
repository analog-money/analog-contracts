// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

/**
 * Fork test for debugging Beefy ConcLiq deposit failure
 * Uses actual values from failed deposit attempt
 *
 * To run this test:
 *   forge test --match-test test_beefy_concliq_deposit -vvvv --fork-url $BASE_HTTP_RPC_URL
 *
 * Values from actual failed deposit:
 * - Vault: 0xd505Ce5D357F117C5Cb4E8A21c2656Bb2c60AcB2
 * - Token0 (WETH): 0x4200000000000000000000000000000000000006
 * - Token1 (USDC): 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
 * - amount0: 14281273676956 (0.000014281273676956 WETH)
 * - amount1: 50000 (0.05 USDC)
 * - minShares: 99369
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

contract BeefyConcLiqDepositDebugTest is Test {
    // Actual values from the failed deposit
    address constant VAULT_ADDRESS = 0xd505Ce5D357F117C5Cb4E8A21c2656Bb2c60AcB2;
    address constant TOKEN0 = 0x4200000000000000000000000000000000000006; // WETH
    address constant TOKEN1 = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC
    address constant POOL_ADDRESS = 0xd0b53D9277642d899DF5C87A3966A349A798F224;

    // Actual user from the logs
    address constant USER = 0x5811F3BDd678d68b2fA1e107750017b68D2aBD92;

    // Actual amounts from the logs
    uint256 constant AMOUNT0 = 14281273676956; // 0.000014281273676956 WETH
    uint256 constant AMOUNT1 = 50000; // 0.05 USDC
    uint256 constant MIN_SHARES = 99369;

    // User's actual token balances from logs
    uint256 constant USER_TOKEN0_BALANCE = 14425256285424; // 0.000014425256285424 WETH

    // Interfaces
    IERC20 token0Contract;
    IERC20 token1Contract;
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
        vm.label(TOKEN0, "WETH");
        vm.label(TOKEN1, "USDC");
        vm.label(USER, "USER");

        // Initialize interfaces
        token0Contract = IERC20(TOKEN0);
        token1Contract = IERC20(TOKEN1);
        pool = IUniswapV3Pool(POOL_ADDRESS);
        vault = IBeefyVault(VAULT_ADDRESS);

        // Give user some ETH for gas
        vm.deal(USER, 10 ether);
    }

    function test_beefy_concliq_deposit() public {
        console.log("\n=== Beefy ConcLiq Deposit Debug Test ===");
        console.log("Testing with actual failed deposit values");
        console.log("");

        // Log initial state
        console.log("Initial State:");
        console.log("  Vault:", VAULT_ADDRESS);
        console.log("  Pool:", POOL_ADDRESS);
        console.log("  Token0 (WETH):", TOKEN0);
        console.log("  Token1 (USDC):", TOKEN1);
        console.log("  User:", USER);
        console.log("");

        // Check pool state
        console.log("Pool State:");
        (
            uint160 sqrtPriceX96,
            int24 tick,
            ,
            ,
            ,
            ,
            bool unlocked
        ) = pool.slot0();
        console.log("  sqrtPriceX96:", uint256(sqrtPriceX96));
        console.log("  tick:", uint256(int256(tick)));
        console.log("  unlocked:", unlocked);
        address poolToken0 = pool.token0();
        address poolToken1 = pool.token1();
        console.log("  pool.token0():", poolToken0);
        console.log("  pool.token1():", poolToken1);
        console.log("");

        // Check vault state
        console.log("Vault State:");
        bool isCalm = vault.isCalm();
        console.log("  isCalm:", isCalm);
        address want = vault.want();
        console.log("  want:", want);
        console.log("");

        // Fund user with exact amounts from the logs
        console.log("Funding user with tokens:");
        console.log("  Token0 amount:", AMOUNT0);
        console.log("  Token1 amount:", AMOUNT1);
        deal(TOKEN0, USER, USER_TOKEN0_BALANCE); // Use actual balance from logs
        deal(TOKEN1, USER, AMOUNT1);
        console.log("");

        // Start acting as the user
        vm.startPrank(USER);

        // Check balances
        uint256 token0Balance = token0Contract.balanceOf(USER);
        uint256 token1Balance = token1Contract.balanceOf(USER);
        console.log("User Token Balances:");
        console.log("  Token0 balance:", token0Balance);
        console.log("  Token1 balance:", token1Balance);
        console.log("  Has enough token0:", token0Balance >= AMOUNT0);
        console.log("  Has enough token1:", token1Balance >= AMOUNT1);
        console.log("");

        // Check token decimals
        uint8 dec0 = token0Contract.decimals();
        uint8 dec1 = token1Contract.decimals();
        console.log("Token Decimals:");
        console.log("  Token0 decimals:", dec0);
        console.log("  Token1 decimals:", dec1);
        console.log("");

        // Approve tokens to vault
        console.log("Approving tokens to vault:");
        token0Contract.approve(VAULT_ADDRESS, AMOUNT0);
        token1Contract.approve(VAULT_ADDRESS, AMOUNT1);

        uint256 allowance0 = token0Contract.allowance(USER, VAULT_ADDRESS);
        uint256 allowance1 = token1Contract.allowance(USER, VAULT_ADDRESS);
        console.log("  Token0 allowance:", allowance0);
        console.log("  Token1 allowance:", allowance1);
        console.log("");

        // Preview deposit
        console.log("Preview Deposit:");
        try vault.previewDeposit(AMOUNT0, AMOUNT1) returns (
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
            console.log("  Min shares (from logs):", MIN_SHARES);
            console.log("  Min shares check:", shares >= MIN_SHARES);
        } catch (bytes memory reason) {
            console.log("  previewDeposit FAILED:");
            console.logBytes(reason);
        }
        console.log("");

        // Check vault balance before
        uint256 vaultBalanceBefore = vault.balanceOf(USER);
        console.log("Vault balance before deposit:", vaultBalanceBefore);
        console.log("");

        // Execute deposit with actual values
        console.log("Executing Deposit:");
        console.log("  amount0:", AMOUNT0);
        console.log("  amount1:", AMOUNT1);
        console.log("  minShares:", MIN_SHARES);
        console.log("");

        try vault.deposit(AMOUNT0, AMOUNT1, MIN_SHARES) {
            console.log("SUCCESS: Deposit completed!");
            console.log("");

            uint256 vaultBalanceAfter = vault.balanceOf(USER);
            uint256 sharesReceived = vaultBalanceAfter - vaultBalanceBefore;
            console.log("Deposit Results:");
            console.log("  Vault balance after:", vaultBalanceAfter);
            console.log("  Shares received:", sharesReceived);

            // Verify deposit succeeded
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

                // Common error selectors:
                // 0x26c87876 = NotCalm()
                // 0xfb8f41b2 = TransferFromFailed()
                // 0x3b6cc6d7 = InsufficientBalance()

                if (errorSelector == bytes4(0x26c87876)) {
                    console.log("Error: NotCalm() - Pool volatility is too high");
                } else if (errorSelector == bytes4(0xfb8f41b2)) {
                    console.log(
                        "Error: TransferFromFailed() - Token transfer failed"
                    );
                } else if (errorSelector == bytes4(0x3b6cc6d7)) {
                    console.log(
                        "Error: InsufficientBalance() - Not enough tokens"
                    );
                } else {
                    console.log("Error: Unknown error");
                }
                console.log("");
                console.log("Full error data:");
                console.logBytes(reason);
            } else {
                console.log("Error: No error data returned");
            }

            // Fail the test with detailed error
            revert("Deposit failed - see logs above for details");
        }

        vm.stopPrank();
    }

    /**
     * Test with unlimited approvals to rule out approval issues
     */
    function test_beefy_concliq_deposit_with_unlimited_approval() public {
        console.log("\n=== Test with Unlimited Approvals ===");

        // Fund user
        deal(TOKEN0, USER, USER_TOKEN0_BALANCE);
        deal(TOKEN1, USER, AMOUNT1);
        vm.deal(USER, 10 ether);

        vm.startPrank(USER);

        // Approve unlimited amounts
        uint256 MAX_UINT = type(uint256).max;
        token0Contract.approve(VAULT_ADDRESS, MAX_UINT);
        token1Contract.approve(VAULT_ADDRESS, MAX_UINT);

        console.log("Approved unlimited amounts:");
        console.log("  Token0 allowance:", MAX_UINT);
        console.log("  Token1 allowance:", MAX_UINT);
        console.log("");

        // Execute deposit
        console.log("Executing deposit with unlimited approvals...");
        try vault.deposit(AMOUNT0, AMOUNT1, MIN_SHARES) {
            console.log("SUCCESS: Deposit completed with unlimited approvals!");
        } catch (bytes memory reason) {
            console.log("FAILED: Deposit still fails with unlimited approvals");
            if (reason.length >= 4) {
                bytes4 errorSelector = bytes4(reason);
                console.log("Error selector:");
                console.logBytes4(errorSelector);
            }
            console.logBytes(reason);
            revert("Deposit failed even with unlimited approvals");
        }

        vm.stopPrank();
    }

    /**
     * Test with slightly higher amounts to check if amounts are too low
     */
    function test_beefy_concliq_deposit_with_higher_amounts() public {
        console.log("\n=== Test with 10x Higher Amounts ===");

        uint256 amount0Higher = AMOUNT0 * 10;
        uint256 amount1Higher = AMOUNT1 * 10;

        // Fund user
        deal(TOKEN0, USER, amount0Higher);
        deal(TOKEN1, USER, amount1Higher);
        vm.deal(USER, 10 ether);

        vm.startPrank(USER);

        // Approve
        token0Contract.approve(VAULT_ADDRESS, amount0Higher);
        token1Contract.approve(VAULT_ADDRESS, amount1Higher);

        console.log("Testing with 10x amounts:");
        console.log("  amount0:", amount0Higher);
        console.log("  amount1:", amount1Higher);
        console.log("");

        // Preview with higher amounts
        try vault.previewDeposit(amount0Higher, amount1Higher) returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1,
            uint256 fee0,
            uint256 fee1
        ) {
            console.log("Preview with higher amounts:");
            console.log("  Expected shares:", shares);
            uint256 minSharesHigher = (shares * 99) / 100;
            console.log("  Min shares (99%):", minSharesHigher);
            console.log("");

            // Execute deposit with higher amounts
            console.log("Executing deposit with higher amounts...");
            try vault.deposit(amount0Higher, amount1Higher, minSharesHigher) {
                console.log("SUCCESS: Deposit completed with higher amounts!");
            } catch (bytes memory reason) {
                console.log("FAILED: Deposit fails with higher amounts too");
                if (reason.length >= 4) {
                    console.logBytes4(bytes4(reason));
                }
                console.logBytes(reason);
            }
        } catch (bytes memory reason) {
            console.log("FAILED: previewDeposit fails with higher amounts");
            console.logBytes(reason);
        }

        vm.stopPrank();
    }
}

