// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AnalogHedgedUniswapVault} from "../src/AnalogHedgedUniswapVault.sol";
import {BaseHedgedVault} from "../src/BaseHedgedVault.sol";
import {AvantisHedgeAdapter} from "../src/hedge/AvantisHedgeAdapter.sol";
import {AnalogHedgedUniswapVaultFactory} from "../src/AnalogHedgedUniswapVaultFactory.sol";
import {AvantisHedgeAdapterFactory} from "../src/AvantisHedgeAdapterFactory.sol";
import {TestStrategyPassiveManagerUniswap} from "../src/TestStrategyPassiveManagerUniswap.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHedgedVault} from "../src/interfaces/IHedgedVault.sol";
import {IStrategyConcLiq} from "beefy-zk/interfaces/beefy/IStrategyConcLiq.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {StratFeeManagerInitializable} from "beefy-zk/strategies/StratFeeManagerInitializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SwapCall} from "../src/libraries/SwapExecutor.sol";
import "forge-std/console.sol";

/**
 * @title AnalogHedgedUniswapVaultForkTest
 * @notice Base fork tests for AnalogHedgedUniswapVault with real Avantis integration
 */
contract AnalogHedgedUniswapVaultForkTest is Test {
  // Base Mainnet addresses
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant WETH = 0x4200000000000000000000000000000000000006;

  // Uniswap V3 addresses on Base
  address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // WETH/USDC 0.05%
  address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a; // Uniswap V3 Quoter V2
  address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481; // SwapRouter02
  // Chainlink ETH/USD price feed on Base mainnet
  address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

  // Test addresses
  address constant OWNER = 0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa;
  address constant CONTROLLER = address(0x1111111111111111111111111111111111111111);

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

    // Deploy AvantisHedgeAdapterFactory
    AvantisHedgeAdapterFactory adapterImpl = new AvantisHedgeAdapterFactory();
    
    // Initialize Adapter Factory via Proxy
    bytes memory adapterInitData = abi.encodeWithSelector(
        AvantisHedgeAdapterFactory.initialize.selector,
        ETH_USD_FEED
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
        address(adapterFactory),
        QUOTER,
        SWAP_ROUTER,
        CONTROLLER,
        address(vaultImpl)
    );

    ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
    vaultFactory = AnalogHedgedUniswapVaultFactory(address(proxy));

    // Create vault using factory
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

    // Fund OWNER
    deal(USDC, OWNER, 10000 * 10 ** 6);
    vm.deal(OWNER, 10 ether);
    vm.deal(CONTROLLER, 10 ether);
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

  function testFullFlow_DeployPosition_Hedge_Withdraw() public {
    uint256 depositAmount = 1000 * 10 ** 6; // 1,000 USDC

    console.log("\n=== Step 1: User Queues Deposit ===");
    vm.startPrank(OWNER);
    usdc.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    console.log("Deposit queued");

    // Verify pending deposit - getPendingStates returns 14 values
    (uint256 depositAmt, bool depositPending,,,,,,,,,,,,) = vault.getPendingStates();
    assertEq(depositAmt, depositAmount);
    assertTrue(depositPending);

    console.log("\n=== Step 2: Controller Executes Deposit ===");
    vm.prank(CONTROLLER);
    vault.depositExecute(new SwapCall[](0));

    uint256 userSharesAfter = vault.balanceOf(OWNER);
    assertGt(userSharesAfter, 0);

    console.log("\n=== Step 3: User Queues Withdrawal ===");

    // Withdraw 90% (leave some margin for fees/precision)
    uint256 vaultEquity = vault.getVaultEquity();
    uint256 withdrawAmount = (vaultEquity * 90) / 100;

    vm.prank(OWNER);
    vault.withdraw(withdrawAmount);

    console.log("\n=== Step 4: Controller Executes Withdrawal (no pool movement) ===");

    // Execute withdrawal with minAmountOut (withdrawAmount is the minimum)
    vm.prank(CONTROLLER);
    vault.withdrawExecute(new SwapCall[](0), withdrawAmount);

    // Verify user received USDC
    uint256 ownerUSDC = usdc.balanceOf(OWNER);
    assertGt(ownerUSDC, 0, "Owner should have received USDC");
    console.log("Owner received USDC:", ownerUSDC);
  }

  // Helper: move pool by swapping
  function _movePool(uint256 amountIn, bool zeroForOne) internal {
    address tokenIn = zeroForOne ? WETH : USDC;
    address tokenOut = zeroForOne ? USDC : WETH;
    address whale = address(0x4444);
    deal(tokenIn, whale, amountIn);
    
    vm.startPrank(whale);
    IERC20(tokenIn).approve(SWAP_ROUTER, amountIn);
    
    // Simplest way to swap on router without full interfaces
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
  }

  function testAccrueMarginFeesIncreasesAccruedFees() public {
    uint256 depositAmount = 5000 * 10 ** 6;

    vm.startPrank(OWNER);
    usdc.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    vm.prank(CONTROLLER);
    vault.depositExecute(new SwapCall[](0));

    IHedgedVault.HedgePosition memory hedge = vault.getCurrentHedge();
    if (!hedge.isOpen) return;

    uint256 feesBefore = hedge.marginFeesAccrued;
    vm.warp(block.timestamp + 24 hours);

    vm.prank(CONTROLLER);
    vault.accrueMarginFees();

    hedge = vault.getCurrentHedge();
    assertGe(hedge.marginFeesAccrued, feesBefore);
  }

  function testDeposit_DeployToAMM() public {
    uint256 depositAmount = 500 * 10 ** 6;

    vm.startPrank(OWNER);
    usdc.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    vm.prank(CONTROLLER);
    vault.depositExecute(new SwapCall[](0));

    assertGt(vault.balanceOf(OWNER), 0);
  }

  function testRebalanceAMM() public {
    uint256 depositAmount = 1000 * 10 ** 6;

    vm.startPrank(OWNER);
    usdc.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    vm.prank(CONTROLLER);
    vault.depositExecute(new SwapCall[](0));

    vm.prank(CONTROLLER);
    vault.rebalanceAMM();
  }

  function testHarvestFees() public {
    uint256 depositAmount = 1000 * 10 ** 6;

    vm.startPrank(OWNER);
    usdc.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    vm.prank(CONTROLLER);
    vault.depositExecute(new SwapCall[](0));

    vm.prank(CONTROLLER);
    vault.harvest();
  }

  function testCancelDeposit() public {
    uint256 depositAmount = 1000 * 10 ** 6;
    uint256 userUSDCBefore = usdc.balanceOf(OWNER);

    vm.startPrank(OWNER);
    usdc.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    
    vault.depositCancel();
    vm.stopPrank();

    assertEq(usdc.balanceOf(OWNER), userUSDCBefore);
    (,bool depositPending,,bool withdrawPending,,,,,,,,,,) = vault.getPendingStates();
    assertFalse(depositPending);
    assertFalse(withdrawPending);
  }

  function testCancelWithdrawal() public {
    uint256 depositAmount = 1000 * 10 ** 6;

    vm.startPrank(OWNER);
    usdc.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    vm.prank(CONTROLLER);
    vault.depositExecute(new SwapCall[](0));

    uint256 shares = vault.balanceOf(OWNER);
    vm.prank(OWNER);
    vault.withdraw(depositAmount / 2);

    vm.prank(OWNER);
    vault.withdrawCancel();

    (,bool depositPending,,bool withdrawPending,,,,,,,,,,) = vault.getPendingStates();
    assertFalse(depositPending);
    assertFalse(withdrawPending);
  }

  function testEmergencyExit() public {
    uint256 depositAmount = 1000 * 10 ** 6;

    vm.startPrank(OWNER);
    usdc.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    vm.prank(CONTROLLER);
    vault.depositExecute(new SwapCall[](0));

    vm.prank(OWNER);
    vault.emergencyExit();

    assertTrue(vault.isPaused());
    assertTrue(vault.emergencyExitTriggered());
  }
}


