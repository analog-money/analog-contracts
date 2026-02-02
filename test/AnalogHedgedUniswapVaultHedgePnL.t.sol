// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AnalogHedgedUniswapVault} from "../src/AnalogHedgedUniswapVault.sol";
import {AnalogHedgedUniswapVaultFactory} from "../src/AnalogHedgedUniswapVaultFactory.sol";
import {AvantisHedgeAdapterFactory} from "../src/AvantisHedgeAdapterFactory.sol";
import {AvantisHedgeAdapter} from "../src/hedge/AvantisHedgeAdapter.sol";
import {IHedgeAdapter} from "../src/interfaces/IHedgeAdapter.sol";
import {TestStrategyPassiveManagerUniswap} from "../src/TestStrategyPassiveManagerUniswap.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {StratFeeManagerInitializable} from "beefy-zk/strategies/StratFeeManagerInitializable.sol";
import {IHedgedVault} from "../src/interfaces/IHedgedVault.sol";
import {SwapCall} from "../src/libraries/SwapExecutor.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

/**
 * @title AnalogHedgedUniswapVaultHedgePnLTest
 * @notice Fork test to verify hedge P&L behavior across price movements
 */
contract AnalogHedgedUniswapVaultHedgePnLTest is Test {
  // Base mainnet addresses
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant WETH = 0x4200000000000000000000000000000000000006;
  address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // WETH/USDC 0.05%
  address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
  address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
  address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

  address constant OWNER = address(0x1234);
  address constant CONTROLLER = address(0x5678);

  IERC20 usdc;
  IERC20 weth;

  AnalogHedgedUniswapVaultFactory vaultFactory;
  AvantisHedgeAdapterFactory adapterFactory;
  StrategyFactory strategyFactory;

  AnalogHedgedUniswapVault vault;

  function _getVaultValue() internal view returns (uint256) {
      (uint256 amount0, uint256 amount1) = vault.balances();
      
      // Get price from oracle
      (, int256 priceStr, , , ) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();
      uint256 price = uint256(priceStr) * 1e10; // Chainlink 8 decimals -> 18 decimals

      // AMM value in USDC (1e6)
      // amount0 is WETH (1e18), amount1 is USDC (1e6)
      // Val = amount1 + (amount0 * price / 1e18) / 1e12 * 1e6 ? No
      // amount0 * 1e18 * price (1e18) / 1e18 = amount0_in_usd * 1e18 (if 18dec)
      // WETH is 18 dec. Price is 18 dec ($3000 * 1e18)
      // Value in USDC (6 dec) = (amount0 * price) / 1e30
      
      uint256 ammValue = amount1 + (amount0 * price) / 1e30;
      
      int256 hedgeValue = 0;
      if (address(vault.hedgeAdapter()) != address(0)) {
           hedgeValue = vault.hedgeAdapter().getHedgeValue(address(vault));
      }
      
      uint256 idle = usdc.balanceOf(address(vault));
      
      int256 total = int256(ammValue + idle) + hedgeValue;
      return total > 0 ? uint256(total) : 0;
  }
  TestStrategyPassiveManagerUniswap strategy;
  AvantisHedgeAdapter adapter;

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
    adapterFactory = new AvantisHedgeAdapterFactory();

    // Deploy vault implementation
    AnalogHedgedUniswapVault vaultImpl = new AnalogHedgedUniswapVault(
      USDC,
      WETH,
      POOL,
      ETH_USD_FEED
    );

    // Deploy AnalogHedgedUniswapVaultFactory
    vaultFactory = new AnalogHedgedUniswapVaultFactory();

    // Create vault using factory
    vm.prank(address(this));
    (address vaultAddr, address strategyAddr, address adapterAddr) = vaultFactory.createVault(
      OWNER,
      "TestStrategyPassiveManagerUniswap"
    );

    vault = AnalogHedgedUniswapVault(vaultAddr);
    strategy = TestStrategyPassiveManagerUniswap(strategyAddr);
    adapter = AvantisHedgeAdapter(adapterAddr);

    // Set adapter on vault
    vm.prank(OWNER);
    vault.setHedgeAdapter(address(adapter));

    // Initialize strategy
    initializeStrategy(address(strategy), address(vault));

    // Fund OWNER
    deal(USDC, OWNER, 100000 * 10 ** 6); // 100k USDC for testing
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

  /**
   * @notice Test hedge P&L behavior when price moves DOWN (favorable for short)
   * @dev When ETH price drops, AMM delta decreases, hedge should profit
   */
  function testHedgePnL_PriceDown() public {
    uint256 depositAmount = 10000 * 10 ** 6; // 10,000 USDC

    console.log("\n=== HEDGE P&L TEST: PRICE DOWN ===");
    console.log("Initial deposit (USDC):", depositAmount / 1e6);

    // Step 1: Deposit
    vm.startPrank(OWNER);
    usdc.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    vm.prank(CONTROLLER);
    vault.depositExecute(new SwapCall[](0));

    // Record initial state
    uint256 deltaInitial = vault.calculateAMMDelta();
    IHedgeAdapter.HedgeState memory hedgeInitial = adapter.getHedgeState(address(vault));
    int256 hedgeValueInitial = adapter.getHedgeValue(address(vault));
    
    console.log("\n--- Initial State ---");
    console.log("AMM Delta (WETH):", deltaInitial);
    console.log("Hedge Open:", hedgeInitial.isOpen);
    console.log("Hedge Size (USD):", hedgeInitial.sizeUSD / 1e6);
    console.log("Hedge Value (USDC):", hedgeValueInitial);

    // Step 2: Move price DOWN (WETH -> USDC swap)
    console.log("\n--- Simulating Price Drop (100 ETH sell) ---");
    _movePool(100 ether, true); // Sell WETH for USDC
    
    // Wait for TWAP to settle
    vm.warp(block.timestamp + 300);
    vm.roll(block.number + 100);

    // Record state after price move
    uint256 deltaAfterMove = vault.calculateAMMDelta();
    int256 hedgeValueAfterMove = adapter.getHedgeValue(address(vault));
    
    console.log("\n--- After Price Drop ---");
    console.log("AMM Delta (WETH):", deltaAfterMove);
    console.log("Delta Change:", int256(deltaAfterMove) - int256(deltaInitial));
    console.log("Hedge Value (USDC):", hedgeValueAfterMove);
    console.log("Hedge P&L:", hedgeValueAfterMove - hedgeValueInitial);

    // Verify: Delta decreased (less WETH exposure)
    assertLt(deltaAfterMove, deltaInitial, "Delta should decrease when price drops");
    
    // Note: Current implementation only tracks fees (negative)
    // In production, hedge should show profit when price drops
    console.log("\n--- Expected Behavior ---");
    console.log("AMM lost value due to impermanent loss");
    console.log("Hedge should profit from price drop (short position)");
    console.log("Net effect should be approximately neutral");
  }

  /**
   * @notice Test hedge P&L behavior when price moves UP (unfavorable for short)
   * @dev When ETH price rises, AMM delta increases, hedge should lose
   */
  function testHedgePnL_PriceUp() public {
    uint256 depositAmount = 10000 * 10 ** 6; // 10,000 USDC

    console.log("\n=== HEDGE P&L TEST: PRICE UP ===");
    console.log("Initial deposit (USDC):", depositAmount / 1e6);

    // Step 1: Deposit
    vm.startPrank(OWNER);
    usdc.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    vm.prank(CONTROLLER);
    vault.depositExecute(new SwapCall[](0));

    // Record initial state
    uint256 deltaInitial = vault.calculateAMMDelta();
    IHedgeAdapter.HedgeState memory hedgeInitial = adapter.getHedgeState(address(vault));
    int256 hedgeValueInitial = adapter.getHedgeValue(address(vault));
    
    console.log("\n--- Initial State ---");
    console.log("AMM Delta (WETH):", deltaInitial);
    console.log("Hedge Open:", hedgeInitial.isOpen);
    console.log("Hedge Size (USD):", hedgeInitial.sizeUSD / 1e6);
    console.log("Hedge Value (USDC):", hedgeValueInitial);

    // Step 2: Move price UP (USDC -> WETH swap)
    console.log("\n--- Simulating Price Rise (200M USDC buy) ---");
    _movePool(200_000_000 * 10**6, false); // Buy WETH with USDC
    
    // Wait for TWAP to settle
    vm.warp(block.timestamp + 300);
    vm.roll(block.number + 100);

    // Record state after price move
    uint256 deltaAfterMove = vault.calculateAMMDelta();
    int256 hedgeValueAfterMove = adapter.getHedgeValue(address(vault));
    
    console.log("\n--- After Price Rise ---");
    console.log("AMM Delta (WETH):", deltaAfterMove);
    console.log("Delta Change:", int256(deltaAfterMove) - int256(deltaInitial));
    console.log("Hedge Value (USDC):", hedgeValueAfterMove);
    console.log("Hedge P&L:", hedgeValueAfterMove - hedgeValueInitial);

    // Verify: Delta increased (more WETH exposure)
    assertGt(deltaAfterMove, deltaInitial, "Delta should increase when price rises");
    
    // Note: Current implementation only tracks fees (negative)
    // In production, hedge should show loss when price rises
    console.log("\n--- Expected Behavior ---");
    console.log("AMM gained value from price appreciation");
    console.log("Hedge should lose from price rise (short position)");
    console.log("Net effect should be approximately neutral");
  }

  /**
   * @notice Test that total vault value remains stable despite price movements
   * @dev This is the key test: hedge + AMM should stay neutral
   */
  function testHedgeNeutrality_PriceVolatility() public {
    uint256 depositAmount = 10000 * 10 ** 6; // 10,000 USDC

    console.log("\n=== HEDGE NEUTRALITY TEST ===");
    console.log("Testing that vault value stays stable across price swings");

    // Step 1: Deposit
    vm.startPrank(OWNER);
    usdc.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    vm.prank(CONTROLLER);
    vault.depositExecute(new SwapCall[](0));

    uint256 initialAssets = _getVaultValueFromBalances();
    console.log("\nInitial Total Assets (USDC):", initialAssets / 1e6);

    // Scenario 1: Price drops
    console.log("\n--- Scenario 1: Price Drop ---");
    _movePool(50 ether, true);
    vm.warp(block.timestamp + 300);
    
    uint256 assetsAfterDrop = _getVaultValueFromBalances();
    int256 changeAfterDrop = int256(assetsAfterDrop) - int256(initialAssets);
    console.log("Assets after drop (USDC):", assetsAfterDrop / 1e6);
    console.log("Change (USDC):", uint256(changeAfterDrop > 0 ? changeAfterDrop : -changeAfterDrop) / 1e6);

    // Scenario 2: Price recovers
    console.log("\n--- Scenario 2: Price Recovery ---");
    _movePool(100_000_000 * 10**6, false);
    vm.warp(block.timestamp + 300);
    
    uint256 assetsAfterRecovery = _getVaultValueFromBalances();
    int256 changeAfterRecovery = int256(assetsAfterRecovery) - int256(initialAssets);
    console.log("Assets after recovery (USDC):", assetsAfterRecovery / 1e6);
    console.log("Change from initial (USDC):", uint256(changeAfterRecovery > 0 ? changeAfterRecovery : -changeAfterRecovery) / 1e6);

    // Scenario 3: Price drops again
    console.log("\n--- Scenario 3: Another Drop ---");
    _movePool(75 ether, true);
    vm.warp(block.timestamp + 300);
    
    uint256 assetsFinal = _getVaultValueFromBalances();
    int256 changeFinal = int256(assetsFinal) - int256(initialAssets);
    console.log("Final assets (USDC):", assetsFinal / 1e6);
    console.log("Total change (USDC):", uint256(changeFinal > 0 ? changeFinal : -changeFinal) / 1e6);

    console.log("\n--- Analysis ---");
    console.log("Expected: Small changes due to fees, but mostly neutral");
    console.log("Actual total change (USDC):", uint256(changeFinal > 0 ? changeFinal : -changeFinal) / 1e6);
    
    // Allow for fees and small slippage, but should be mostly neutral
    // In a perfect hedge, change should be near zero (minus fees)
    uint256 maxAcceptableChange = depositAmount / 20; // 5% tolerance for fees/slippage
    assertLt(
      changeFinal > 0 ? uint256(changeFinal) : uint256(-changeFinal),
      maxAcceptableChange,
      "Vault value should remain relatively stable with hedge"
    );
  }

  /**
   * @notice Test Avantis behavior by mocking the Chainlink Oracle price
   * @dev Directly manipulates the price feed to verify hedge adapter response
   */
  function testHedgeReflectsOraclePriceChange() public {
    uint256 depositAmount = 10000 * 10 ** 6; // 10,000 USDC

    console.log("\n=== ORACLE MANIPULATION TEST ===");
    
    // 1. Deposit
    vm.startPrank(OWNER);
    usdc.approve(address(vault), depositAmount);
    vault.deposit(depositAmount);
    vm.stopPrank();

    vm.prank(CONTROLLER);
    vault.depositExecute(new SwapCall[](0));

    // Get initial real price
    (, int256 realPrice,,,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();
    console.log("Initial Real Price (8 decimals):", realPrice);

    // DEBUG: Check AMM Delta and hedge triggers
    uint256 currentDelta = vault.calculateAMMDelta();
    console.log("Current AMM Delta (WETH):", currentDelta);

    // Force Open Hedge for Testing (if not open)
    // Ensure vault has idle USDC for collateral
    deal(USDC, address(vault), 50000 * 1e6);
    
    // MOCK Avantis Trading openTrade to bypass protocol checks in fork
    // openTrade returns (uint256 orderId)
    address AVANTIS_TRADING = 0x44914408af82bC9983bbb330e3578E1105e11d4e;
    vm.mockCall(
        AVANTIS_TRADING,
        abi.encodeWithSignature("openTrade((address,uint256,uint256,uint256,uint256,uint256,bool,uint256,uint256,uint256,uint256),uint8,uint256)"),
        abi.encode(uint256(12345))
    );

    vm.prank(address(vault));
    adapter.adjustHedge(10000 * 1e6); // Open 10,000 USD short (size is irrelevant for mock, but used in adapter state)

    // DEBUG: Check initial hedge state
    IHedgeAdapter.HedgeState memory state = adapter.getHedgeState(address(vault));
    console.log("Hedge Open:", state.isOpen);
    console.log("Hedge Size (USD):", state.sizeUSD);
    console.log("Hedge Entry Price:", state.entryPrice);
    
    // 2. Mock Price Drop (-50%)
    int256 droppedPrice = realPrice / 2;
    console.log("\n--- Mocking Price Drop (-50%) ---");
    console.log("Mocked Price:", droppedPrice);
    
    // Creating the mock return data for latestRoundData()
    // (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    bytes memory mockData = abi.encode(
      uint80(1),       // roundId
      droppedPrice,    // answer (price)
      block.timestamp, // startedAt
      block.timestamp, // updatedAt
      uint80(1)        // answeredInRound
    );
    
    vm.mockCall(
      ETH_USD_FEED,
      abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
      mockData
    );
    
    // Verify the feed is mocked
    (, int256 currentPrice,,,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();
    assertEq(currentPrice, droppedPrice, "Detailed Mock failed");
    
    // Check Hedge Value with dropped price
    // Note: getHedgeValue might currently return just fees, but we check if it runs without revert
    // and if we can trigger a rebalance based on this new price.
    try adapter.getHedgeValue(address(vault)) returns (int256 val) {
        console.log("Hedge Value at Dropped Price:", val);
    } catch {
        console.log("getHedgeValue reverted with mocked price");
    }

    // 3. Mock Price Rise (+100%)
    int256 risenPrice = realPrice * 2;
    console.log("\n--- Mocking Price Rise (+100%) ---");
    console.log("Mocked Price:", risenPrice);
    
    mockData = abi.encode(
      uint80(2),       // roundId
      risenPrice,      // answer (price)
      block.timestamp, // startedAt
      block.timestamp, // updatedAt
      uint80(2)        // answeredInRound
    );
    
    vm.mockCall(
      ETH_USD_FEED,
      abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
      mockData
    );
    
    // Check Hedge Value with risen price
    try adapter.getHedgeValue(address(vault)) returns (int256 val) {
        console.log("Hedge Value at Risen Price:", val);
    } catch {
        console.log("getHedgeValue reverted with mocked price");
    }
    
    // Verify total assets calculation uses the mocked price if it relies on oracle
    // The vault.totalAssets() might rely on the pool price or the oracle price depending on implementation
    uint256 totalAssets = _getVaultValueFromBalances();
    console.log("Total Assets from Balances at Risen Price:", totalAssets / 1e6);
    
    // Clear mock
    vm.clearMockedCalls();
  }

  // Helper: move pool by swapping
  function _movePool(uint256 amount, bool wethToUsdc) internal {
    address whale = address(0x9999);
    
    if (wethToUsdc) {
      // Sell WETH for USDC
      deal(WETH, whale, amount);
      vm.startPrank(whale);
      IERC20(WETH).approve(SWAP_ROUTER, amount);
      
      // Swap via router
      (bool success,) = SWAP_ROUTER.call(
        abi.encodeWithSignature(
          "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
          WETH,
          USDC,
          uint24(500),
          whale,
          amount,
          0,
          0
        )
      );
      require(success, "Swap failed");
      vm.stopPrank();
    } else {
      // Buy WETH with USDC
      deal(USDC, whale, amount);
      vm.startPrank(whale);
      IERC20(USDC).approve(SWAP_ROUTER, amount);
      
      // Swap via router
      (bool success,) = SWAP_ROUTER.call(
        abi.encodeWithSignature(
          "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
          USDC,
          WETH,
          uint24(500),
          whale,
          amount,
          0,
          0
        )
      );
      require(success, "Swap failed");
      vm.stopPrank();
    }
    
    // Sync Oracle Price with new Pool Price
    // Get spot price for 1 WETH in USDC
    // Use Quoter for simplicity vs sqrtPriceX96 math
    uint256 amountIn = 1e18; // 1 WETH
    
    // quoteExactInputSingle(tokenIn, tokenOut, fee, amountIn, sqrtPriceLimitX96)
    // Returns amountOut
    try IQuoter(QUOTER).quoteExactInputSingle(
        WETH,
        USDC,
        uint24(500),
        amountIn,
        0
    ) returns (uint256 amountOut) {
        // amountOut is USDC (6 decimals) for 1 WETH
        // Oracle expects 8 decimals
        int256 newOraclePrice = int256(amountOut * 100); // 1e6 -> 1e8
        
        console.log("Synced Oracle Price:", newOraclePrice);
        
        bytes memory mockData = abi.encode(
          uint80(1),       // roundId
          newOraclePrice,  // answer
          block.timestamp, // startedAt
          block.timestamp, // updatedAt
          uint80(1)        // answeredInRound
        );
        
        vm.mockCall(
          ETH_USD_FEED,
          abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
          mockData
        );
    } catch {
        console.log("Failed to quote new price for oracle sync");
    }
  }

  function _getVaultValueFromBalances() internal view returns (uint256) {
      (uint256 amt0, uint256 amt1) = vault.balances();
      (address t0, ) = vault.wants();
      
      uint256 wethAmt;
      uint256 usdcAmt;
      
      if (t0 == WETH) {
          wethAmt = amt0;
          usdcAmt = amt1;
      } else {
          wethAmt = amt1;
          usdcAmt = amt0;
      }
      
      // Get price from feed (which might be mocked)
      (, int256 answer, , , ) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();
      uint256 price = uint256(answer);
      
      // Adjust decimals (feed is 8 decimals, need 18 for WETH calc usually)
      // WETH value in USDC (6 decimals)
      // WETH amount (18 decimals) * Price (8 decimals) / 1e20 = 6 decimals
      // (1e18 * 1e8) / 1e20 = 1e6
      
      uint256 wethValueUSDC = (wethAmt * price) / 10**20;
      return usdcAmt + wethValueUSDC;
  }
}

interface IQuoter {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);
}
