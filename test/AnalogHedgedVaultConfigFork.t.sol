// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {AnalogHedgedUniswapVault} from "../src/AnalogHedgedUniswapVault.sol";
import {BaseHedgedVault} from "../src/BaseHedgedVault.sol";
import {AnalogHedgedUniswapVaultFactory} from "../src/AnalogHedgedUniswapVaultFactory.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {AvantisHedgeAdapterFactory} from "../src/AvantisHedgeAdapterFactory.sol";
import {TestStrategyPassiveManagerUniswap} from "../src/TestStrategyPassiveManagerUniswap.sol";
import {IStrategyConcLiq} from "beefy-zk/interfaces/beefy/IStrategyConcLiq.sol";
import {StratFeeManagerInitializable} from "beefy-zk/strategies/StratFeeManagerInitializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AnalogHedgedVaultConfigForkTest
 * @notice Fork test for AnalogHedgedUniswapVault config updates
 */
contract AnalogHedgedVaultConfigForkTest is Test {
    // Base Mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    address constant OWNER = address(0x1234);
    address constant CONTROLLER = address(0x5678);

    AnalogHedgedUniswapVault vault;
    TestStrategyPassiveManagerUniswap strategy;
    StrategyFactory strategyFactory;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");

        // Set up factories and implementations
        strategyFactory = new StrategyFactory(WETH, address(this), address(this), address(0));
        TestStrategyPassiveManagerUniswap strategyImpl = new TestStrategyPassiveManagerUniswap();
        strategyFactory.addStrategy("TestStrategyPassiveManagerUniswap", address(strategyImpl));

        AvantisHedgeAdapterFactory adapterFactory = new AvantisHedgeAdapterFactory();
        AnalogHedgedUniswapVault vaultImpl = new AnalogHedgedUniswapVault(USDC, WETH, POOL, ETH_USD_FEED);

        AnalogHedgedUniswapVaultFactory vaultFactory = new AnalogHedgedUniswapVaultFactory();

        // Create vault
        (address vaultAddr, address strategyAddr, ) = vaultFactory.createVault(OWNER, "TestStrategyPassiveManagerUniswap");
        vault = AnalogHedgedUniswapVault(payable(vaultAddr));
        strategy = TestStrategyPassiveManagerUniswap(payable(strategyAddr));

        // Initialize strategy (this makes the test contract the owner)
        initializeStrategy(address(strategy), address(vault));
        
        // Transfer ownership to the vault so it can execute config changes
        strategy.transferOwnership(address(vault));

        // Fund strategy with some USDC so it's not empty (prevents InvalidTicks in some cases)
        deal(USDC, address(strategy), 100 * 10**6);

        vm.deal(OWNER, 10 ether);
        vm.deal(CONTROLLER, 10 ether);
    }

    function initializeStrategy(address _strategy, address _vault) internal {
        StratFeeManagerInitializable.CommonAddresses memory common = StratFeeManagerInitializable.CommonAddresses({
            vault: _vault,
            unirouter: SWAP_ROUTER,
            strategist: OWNER,
            factory: address(strategyFactory)
        });

        bytes memory lpToken1ToNativePath = abi.encodePacked(USDC, uint24(500), WETH);

        TestStrategyPassiveManagerUniswap(payable(_strategy)).initialize(
            POOL, QUOTER, 10, "", lpToken1ToNativePath, common
        );
        
        // Ensure calm
        TestStrategyPassiveManagerUniswap(payable(_strategy)).setDeviation(30);
        TestStrategyPassiveManagerUniswap(payable(_strategy)).setTwapInterval(120);
    }

    function test_queueAndExecuteConfigChange() public {
        uint256 newWidth = 100;

        // 1. Queue (as Owner)
        vm.startPrank(OWNER);
        vault.queueConfigChange(AnalogHedgedUniswapVault.ConfigChangeType.PositionWidth, int256(newWidth));
        vm.stopPrank();

        AnalogHedgedUniswapVault.PendingConfig memory pending = vault.getPendingConfig();
        assertEq(uint8(pending.changeType), uint8(AnalogHedgedUniswapVault.ConfigChangeType.PositionWidth));
        assertEq(pending.value, int256(newWidth));
        assertTrue(pending.isPending);

        // 2. Execute (as Controller)
        vm.prank(CONTROLLER);
        vault.executeConfigChange();

        // 3. Verify
        pending = vault.getPendingConfig();
        assertFalse(pending.isPending);
        assertEq(strategy.positionWidth(), int24(int256(newWidth)));
    }

    function test_executeRevertsIfNotCalm() public {
        uint256 newWidth = 100;

        // Queue
        vm.prank(OWNER);
        vault.queueConfigChange(AnalogHedgedUniswapVault.ConfigChangeType.PositionWidth, int256(newWidth));

        // Make it NOT calm by moving the pool significantly
        // First, set a small deviation to make it easier to exceed
        vm.prank(address(vault));
        strategy.setDeviation(1);

        // Move the pool by doing a large swap to make current tick != TWAP
        address whale = address(0x9999);
        uint256 swapAmount = 100 ether; // Large WETH swap
        deal(WETH, whale, swapAmount);

        vm.startPrank(whale);
        IERC20(WETH).approve(SWAP_ROUTER, swapAmount);
        // Swap WETH for USDC to move the pool
        (bool success,) = SWAP_ROUTER.call(
            abi.encodeWithSignature(
                "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
                WETH,
                USDC,
                uint24(500), // 0.05% fee
                whale,
                swapAmount,
                0,
                0
            )
        );
        require(success, "Swap failed");
        vm.stopPrank();

        // Don't advance time - this keeps the TWAP at the old price
        // Now current tick will be far from TWAP, making isCalm() return false

        // Execute should revert with NotCalm
        vm.prank(CONTROLLER);
        vm.expectRevert(abi.encodeWithSignature("NotCalm()"));
        vault.executeConfigChange();
    }
}
