// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AnalogHedgedUniswapVaultFactory} from "../src/AnalogHedgedUniswapVaultFactory.sol";
import {AnalogHedgedUniswapVault} from "../src/AnalogHedgedUniswapVault.sol";
import {StrategyPassiveManagerUniswap} from "beefy-zk/strategies/uniswap/StrategyPassiveManagerUniswap.sol";
import {SwapCall} from "../src/libraries/SwapExecutor.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {TestStrategyPassiveManagerUniswap} from "../src/TestStrategyPassiveManagerUniswap.sol";
import {AvantisHedgeAdapterFactory} from "../src/AvantisHedgeAdapterFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StratFeeManagerInitializable} from "beefy-zk/strategies/StratFeeManagerInitializable.sol";
import {AvantisHedgeAdapter} from "../src/hedge/AvantisHedgeAdapter.sol";

/**
 * @title HedgedVaultWithdrawalDebug
 * @notice Comprehensive fork test to debug withdrawal balance issues
 * @dev Run with: forge test --match-contract HedgedVaultWithdrawalDebug --fork-url $BASE_RPC_URL -vvvv
 */
contract HedgedVaultWithdrawalDebug is Test {
    // Base mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC_WHALE = 0x20FE51A9229EEf2cF8Ad9E89d91CAb9312cF3b7A;
    address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    
    // Deployed factory
    address constant VAULT_FACTORY = 0x0bF76Fa0700F43C516F2aa1D3B24D715bcf6321B;
    address constant UNISWAP_POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // WETH/USDC 0.05%
    
    AnalogHedgedUniswapVault vault;
    StrategyPassiveManagerUniswap strategy;
    AnalogHedgedUniswapVaultFactory vaultFactory;
    address controller;
    address user;
    
    uint256 constant DEPOSIT_AMOUNT = 10_000_000; // 10 USDC
    
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    function setUp() public {
        controller = makeAddr("controller");
        user = makeAddr("user");
        
        // Fork Base mainnet
        string memory rpcUrl = "https://mainnet.base.org";
        try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {}
        vm.createSelectFork(rpcUrl);

        // Fund user
        vm.prank(USDC_WHALE);
        IERC20(USDC).transfer(user, DEPOSIT_AMOUNT * 10);
        
        // 1. Deploy StrategyFactory
        StrategyFactory strategyFactory = new StrategyFactory(
            WETH,
            address(this),
            address(this),
            address(0)
        );
        strategyFactory.addRebalancer(controller);

        // 2. Deploy strategy implementation
        TestStrategyPassiveManagerUniswap strategyImpl = new TestStrategyPassiveManagerUniswap();
        strategyFactory.addStrategy("TestStrategyPassiveManagerUniswap", address(strategyImpl));

        // 3. Deploy AvantisHedgeAdapterFactory
        AvantisHedgeAdapterFactory adapterImpl = new AvantisHedgeAdapterFactory();
        
        // Deploy AvantisHedgeAdapter implementation for the factory to use
        AvantisHedgeAdapter adapterLogic = new AvantisHedgeAdapter();

        bytes memory adapterInitData = abi.encodeWithSelector(
            AvantisHedgeAdapterFactory.initialize.selector,
            ETH_USD_FEED,
            address(adapterLogic)
        );
        ERC1967Proxy adapterProxy = new ERC1967Proxy(address(adapterImpl), adapterInitData);
        AvantisHedgeAdapterFactory adapterFactory = AvantisHedgeAdapterFactory(address(adapterProxy));

        // 4. Deploy vault implementation
        AnalogHedgedUniswapVault vaultImpl = new AnalogHedgedUniswapVault(
            USDC,
            WETH,
            UNISWAP_POOL,
            ETH_USD_FEED
        );

        // 5. Deploy AnalogHedgedUniswapVaultFactory Implementation
        AnalogHedgedUniswapVaultFactory factoryImpl = new AnalogHedgedUniswapVaultFactory();

        // 6. Initialize Factory via Proxy
        bytes memory initData = abi.encodeWithSelector(
            AnalogHedgedUniswapVaultFactory.initialize.selector,
            USDC,
            WETH,
            UNISWAP_POOL,
            ETH_USD_FEED,
            address(strategyFactory),
            address(adapterFactory),
            QUOTER,
            SWAP_ROUTER,
            controller,
            address(vaultImpl)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        vaultFactory = AnalogHedgedUniswapVaultFactory(address(proxy));

        // Create vault - factory returns (vaultAddress, strategyAddress, adapterAddress)
        vm.prank(user);
        (address vaultAddress, address strategyAddress,) = vaultFactory.createVault(
            user,
            "TestStrategyPassiveManagerUniswap"
        );
        
        vault = AnalogHedgedUniswapVault(payable(vaultAddress));
        strategy = StrategyPassiveManagerUniswap(strategyAddress);

        // Initialize strategy (required for withdrawal logic to work)
        StratFeeManagerInitializable.CommonAddresses memory commonAddresses = StratFeeManagerInitializable.CommonAddresses({
            vault: address(vault),
            unirouter: SWAP_ROUTER,
            strategist: user,
            factory: address(strategyFactory)
        });

        bytes memory lpToken0ToNativePath = "";
        bytes memory lpToken1ToNativePath = abi.encodePacked(USDC, uint24(500), WETH);

        TestStrategyPassiveManagerUniswap(payable(address(strategy))).initialize(
            UNISWAP_POOL,
            QUOTER,
            10,
            lpToken0ToNativePath,
            lpToken1ToNativePath,
            commonAddresses
        );
        
        TestStrategyPassiveManagerUniswap(payable(address(strategy))).setDeviation(30);
        
        console.log("=== SETUP COMPLETE ===");
        console.log("Vault:", address(vault));
        console.log("User:", user);
        console.log("Controller:", controller);
    }
    
    function testWithdrawalBalanceTracking() public {
        // 1. Deposit
        _deposit();
        
        // 3. Attempt withdrawal
        _withdrawWithDetailedLogging();
    }
    
    function _deposit() internal {
        vm.startPrank(user);
        IERC20(USDC).approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();
        
        vm.prank(controller);
        SwapCall[] memory emptySwaps = new SwapCall[](0);
        vault.depositExecute(emptySwaps);
        
        console.log("Deposited:", DEPOSIT_AMOUNT);
        console.log("User shares:", vault.balanceOf(user));
    }
    
    function _withdrawWithDetailedLogging() internal {
        uint256 vaultEquity = vault.getVaultEquity();
        uint256 withdrawAmount = (vaultEquity * 97) / 100; // 97% with 3% buffer
        
        console.log("\n=== WITHDRAWAL REQUEST ===");
        console.log("Vault Equity:", vaultEquity);
        console.log("Requested Amount (97%):", withdrawAmount);
        
        // Register withdrawal
        vm.prank(user);
        vault.withdraw(withdrawAmount);
        
        console.log("\n=== BEFORE withdrawExecute ===");
        _logBalances("Pre-Execute");
        
        // Get strategy balances BEFORE beforeAction
        (uint256 stratBal0Before, uint256 stratBal1Before) = strategy.balances();
        console.log("Strategy balances() BEFORE beforeAction:");
        console.log("  token0:", stratBal0Before);
        console.log("  token1:", stratBal1Before);
        
        // Calculate what _withdrawFromAMM will do
        uint256 totalValue = vault.getVaultEquity();
        uint256 usdcIdle = IERC20(USDC).balanceOf(address(vault));
        uint256 neededFromAMM = withdrawAmount > usdcIdle ? withdrawAmount - usdcIdle : 0;
        
        console.log("\n=== WITHDRAWAL CALCULATION ===");
        console.log("Total Value:", totalValue);
        console.log("USDC Idle:", usdcIdle);
        console.log("Needed from AMM:", neededFromAMM);
        
        if (neededFromAMM > 0) {
            // Calculate expected withdrawal amounts
            uint256 expectedWithdraw0 = (stratBal0Before * neededFromAMM) / totalValue;
            uint256 expectedWithdraw1 = (stratBal1Before * neededFromAMM) / totalValue;
            
            console.log("Expected withdraw0:", expectedWithdraw0);
            console.log("Expected withdraw1:", expectedWithdraw1);
        }
        
        // Execute withdrawal
        vm.prank(controller);
        SwapCall[] memory emptySwaps = new SwapCall[](0);
        
        try vault.withdrawExecute(emptySwaps, withdrawAmount) {
            console.log("\n=== WITHDRAWAL SUCCESS ===");
            _logBalances("Post-Execute");
            console.log("User USDC received:", IERC20(USDC).balanceOf(user));
        } catch Error(string memory reason) {
            console.log("\n=== WITHDRAWAL FAILED ===");
            console.log("Reason:", reason);
            _logBalances("At Failure");
            
            // Try to understand what went wrong
            uint256 vaultUsdcBalance = IERC20(USDC).balanceOf(address(vault));
            console.log("\nDiagnostics:");
            console.log("Vault USDC balance:", vaultUsdcBalance);
            console.log("Requested minAmountOut:", withdrawAmount);
            console.log("Shortfall:", withdrawAmount > vaultUsdcBalance ? withdrawAmount - vaultUsdcBalance : 0);
            
            revert(reason);
        }
    }
    
    function _logBalances(string memory label) internal view {
        console.log("\n--- Balances:", label, "---");
        
        // Vault balances
        console.log("Vault USDC:", IERC20(USDC).balanceOf(address(vault)));
        console.log("Vault WETH:", IERC20(WETH).balanceOf(address(vault)));
        console.log("Vault Equity:", vault.getVaultEquity());
        
        // Strategy balances
        if (address(strategy) != address(0)) {
            (uint256 bal0, uint256 bal1) = strategy.balances();
            console.log("Strategy balances():");
            console.log("  token0:", bal0);
            console.log("  token1:", bal1);
            
            address token0 = strategy.lpToken0();
            address token1 = strategy.lpToken1();
            console.log("Strategy actual balances:");
            console.log("  token0:", IERC20(token0).balanceOf(address(strategy)));
            console.log("  token1:", IERC20(token1).balanceOf(address(strategy)));
        }
        
        // User balances
        console.log("User USDC:", IERC20(USDC).balanceOf(user));
        console.log("User shares:", vault.balanceOf(user));
    }
}
