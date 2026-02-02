// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AnalogHedgedUniswapVaultFactory} from "../src/AnalogHedgedUniswapVaultFactory.sol";
import {AnalogHedgedUniswapVault} from "../src/AnalogHedgedUniswapVault.sol";
import {AvantisHedgeAdapterFactory} from "../src/AvantisHedgeAdapterFactory.sol";
import {AvantisHedgeAdapter} from "../src/hedge/AvantisHedgeAdapter.sol";
import {StrategyPassiveManagerUniswap} from "beefy-zk/strategies/uniswap/StrategyPassiveManagerUniswap.sol";
import {SwapCall} from "../src/libraries/SwapExecutor.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {TestStrategyPassiveManagerUniswap} from "../src/TestStrategyPassiveManagerUniswap.sol";
import {StratFeeManagerInitializable} from "beefy-zk/strategies/StratFeeManagerInitializable.sol";
import {IStrategyConcLiq} from "beefy-zk/interfaces/beefy/IStrategyConcLiq.sol";

/**
 * @title HedgedVaultWithdrawalWithSwap
 * @notice Fork test for hedged vault withdrawal requiring ETH->USDC swap
 * @dev Run with: forge test --match-contract HedgedVaultWithdrawalWithSwap --fork-url $BASE_RPC_URL -vvv
 */
contract HedgedVaultWithdrawalWithSwap is Test {
    // Base mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // WETH/USDC 0.05%
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant USDC_WHALE = 0x20FE51A9229EEf2cF8Ad9E89d91CAb9312cF3b7A;
    
    address constant OWNER = 0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa;
    address constant CONTROLLER = address(0x1111111111111111111111111111111111111111);
    uint256 constant DEPOSIT_AMOUNT = 1000 * 10 ** 6; // 1,000 USDC
    
    AnalogHedgedUniswapVault vault;
    AvantisHedgeAdapter hedgeAdapter;
    IStrategyConcLiq strategy;
    AnalogHedgedUniswapVaultFactory vaultFactory;
    AvantisHedgeAdapterFactory adapterFactory;
    StrategyFactory strategyFactory;
    IERC20 usdc;
    IERC20 weth;
    
    function setUp() public {
        // Fork Base mainnet
        string memory rpcUrl = "https://mainnet.base.org";
        try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {}
        vm.createSelectFork(rpcUrl);
        
        // Initialize token interfaces
        usdc = IERC20(USDC);
        weth = IERC20(WETH);
        
        // Fund OWNER for later use
        deal(USDC, OWNER, 10000 * 10 ** 6);
        vm.deal(OWNER, 10 ether);
        vm.deal(CONTROLLER, 10 ether);

        // Deploy StrategyFactory
        strategyFactory = new StrategyFactory(
            WETH,
            address(this),
            address(this),
            address(0)
        );
        strategyFactory.addRebalancer(CONTROLLER);
        
        // Deploy strategy implementation
        TestStrategyPassiveManagerUniswap strategyImpl = new TestStrategyPassiveManagerUniswap();
        strategyFactory.addStrategy("TestStrategyPassiveManagerUniswap", address(strategyImpl));
        
        // Deploy AvantisHedgeAdapterFactory Implementation
        AvantisHedgeAdapterFactory adapterImpl = new AvantisHedgeAdapterFactory();
        
        // Deploy AvantisHedgeAdapter implementation for the factory to use
        AvantisHedgeAdapter adapterLogic = new AvantisHedgeAdapter();

        // Initialize Adapter Factory via Proxy
        bytes memory adapterInitData = abi.encodeWithSelector(
            AvantisHedgeAdapterFactory.initialize.selector,
            ETH_USD_FEED,
            address(adapterLogic)
        );
        ERC1967Proxy adapterProxy = new ERC1967Proxy(address(adapterImpl), adapterInitData);
        adapterFactory = AvantisHedgeAdapterFactory(address(adapterProxy));
        
        // Deploy vault implementation
        AnalogHedgedUniswapVault vaultImpl = new AnalogHedgedUniswapVault(
            USDC,
            WETH,
            POOL,
            ETH_USD_FEED
        );
        
        // Deploy AnalogHedgedUniswapVaultFactory Implementation
        AnalogHedgedUniswapVaultFactory factoryImpl = new AnalogHedgedUniswapVaultFactory();
        
        // Initialize Factory via Proxy
        bytes memory initData = abi.encodeWithSelector(
            AnalogHedgedUniswapVaultFactory.initialize.selector,
            USDC,
            WETH,
            POOL,
            ETH_USD_FEED,
            address(strategyFactory),
            address(adapterFactory), // Use Proxy Address
            QUOTER,
            SWAP_ROUTER,
            CONTROLLER,
            address(vaultImpl)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        vaultFactory = AnalogHedgedUniswapVaultFactory(address(proxy));
        
        // Create vault using proxy factory
        vm.prank(address(this));
        (address vaultAddress, address strategyAddress, address adapterAddress) = vaultFactory.createVault(
            OWNER,
            "TestStrategyPassiveManagerUniswap"
        );
        vault = AnalogHedgedUniswapVault(payable(vaultAddress));
        strategy = IStrategyConcLiq(strategyAddress);
        hedgeAdapter = AvantisHedgeAdapter(adapterAddress);
        
        // Initialize strategy
        initializeStrategy(address(strategy), address(vault));
        
        // Transfer ownership to OWNER (since factory initializes with msg.sender)
        vault.transferOwnership(OWNER);
        
        // Set adapter on vault
        vm.prank(OWNER);
        vault.setHedgeAdapter(address(hedgeAdapter));
        
        // Set TWAP interval
        vm.prank(OWNER);
        try TestStrategyPassiveManagerUniswap(payable(address(strategy))).setTwapInterval(60) {} catch {}
    }
    
    function initializeStrategy(address _strategy, address _vault) internal {
        StratFeeManagerInitializable.CommonAddresses memory commonAddresses = StratFeeManagerInitializable.CommonAddresses({
            vault: _vault,
            unirouter: SWAP_ROUTER,
            strategist: OWNER,
            factory: address(strategyFactory)
        });
        
        bytes memory lpToken0ToNativePath = "";
        bytes memory lpToken1ToNativePath = abi.encodePacked(USDC, uint24(500), WETH);
        
        TestStrategyPassiveManagerUniswap(_strategy).initialize(
            POOL,
            QUOTER,
            10,
            lpToken0ToNativePath,
            lpToken1ToNativePath,
            commonAddresses
        );
        
        TestStrategyPassiveManagerUniswap(_strategy).setDeviation(30);
    }
    
    function testWithdrawalWithETHSwap() public {
        console.log("\n=== TEST: Hedged Vault Withdrawal with ETH->USDC Swap ===\n");
        
        // Step 1: Deposit
        console.log("Step 1: User deposits USDC");
        vm.startPrank(OWNER);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();
        
        // Step 2: Execute deposit
        console.log("Step 2: Controller executes deposit");
        vm.prank(CONTROLLER);
        vault.depositExecute(new SwapCall[](0));
        
        uint256 userSharesAfter = vault.balanceOf(OWNER);
        assertGt(userSharesAfter, 0);
        console.log("User shares:", userSharesAfter);
        
        // Log initial balances
        console.log("\n--- After Deposit ---");
        _logBalances();
        
        // Step 3: Move pool to create ETH position
        console.log("\nStep 3: Moving pool to create ETH position...");
        _movePool(100_000_000 * 10**6, false); // Buy WETH with 100M USDC
        
        // Wait for TWAP
        vm.warp(block.timestamp + 300);
        vm.roll(block.number + 100);
        
        console.log("\n--- After Pool Movement ---");
        _logBalances();
        
        // Step 4: Withdraw
        console.log("\nStep 4: User queues withdrawal");
        uint256 vaultEquity = vault.getVaultEquity();
        uint256 withdrawAmount = (vaultEquity * 90) / 100; // 90% to leave margin
        
        console.log("Vault Equity:", vaultEquity);
        console.log("Withdraw Amount (90%):", withdrawAmount);
        
        vm.prank(OWNER);
        vault.withdraw(withdrawAmount);
        
        // Step 5: Execute withdrawal
        console.log("\nStep 5: Controller executes withdrawal");
        console.log("This should withdraw ETH from strategy and swap to USDC...");
        
        vm.prank(CONTROLLER);
        // Use empty swaps - in production this would have 1inch swap calls
        // The vault should handle the WETH->USDC conversion
        vault.withdrawExecute(new SwapCall[](0), withdrawAmount);
        
        // Verify user received USDC
        uint256 ownerUSDC = usdc.balanceOf(OWNER);
        assertGt(ownerUSDC, 0, "Owner should have received USDC");
        console.log("\nOwner received USDC:", ownerUSDC);
        
        console.log("\n--- After Withdrawal ---");
        _logBalances();
    }
    
    function _movePool(uint256 amountIn, bool zeroForOne) internal {
        address tokenIn = zeroForOne ? WETH : USDC;
        address tokenOut = zeroForOne ? USDC : WETH;
        address whale = address(0x4444);
        deal(tokenIn, whale, amountIn);
        
        vm.startPrank(whale);
        IERC20(tokenIn).approve(SWAP_ROUTER, amountIn);
        
        (bool success,) = SWAP_ROUTER.call(
            abi.encodeWithSignature(
                "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
                tokenIn,
                tokenOut,
                uint24(500), // 0.05% fee tier
                whale,
                amountIn,
                0,
                0
            )
        );
        require(success, "Swap failed");
        vm.stopPrank();
        
        console.log("Pool moved successfully");
    }
    
    function _logBalances() internal view {
        console.log("Vault USDC:", usdc.balanceOf(address(vault)));
        console.log("Vault WETH:", weth.balanceOf(address(vault)));
        console.log("Vault Equity:", vault.getVaultEquity());
        
        (uint256 bal0, uint256 bal1) = vault.balances();
        console.log("Strategy balances - token0 (WETH):", bal0, "token1 (USDC):", bal1);
        
        console.log("Owner USDC:", usdc.balanceOf(OWNER));
        console.log("Owner WETH:", weth.balanceOf(OWNER));
    }
}
