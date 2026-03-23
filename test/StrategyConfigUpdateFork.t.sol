// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AnalogVault} from "../src/AnalogVault.sol";
import {AnalogVaultFactory} from "../src/AnalogVaultFactory.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {TestStrategyPassiveManagerUniswap} from "../src/TestStrategyPassiveManagerUniswap.sol";
import {StratFeeManagerInitializable as BStratFM} from "beefy-zk/strategies/StratFeeManagerInitializable.sol";

interface IUniswapV3PoolLike {
    function tickSpacing() external view returns (int24);
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick, uint16 observationIndex,
        uint16 observationCardinality, uint16 observationCardinalityNext,
        uint8 feeProtocol, bool unlocked
    );
    function observe(uint32[] calldata secondsAgos) external view returns (
        int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s
    );
}

/**
 * @title StrategyConfigUpdateForkTest
 * @notice Fork tests for strategy configuration updates (setPositionWidth, setDeviation, setTwapInterval).
 *         Uses a fully deployed vault+strategy with an active LP position.
 */
contract StrategyConfigUpdateForkTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address constant UNIROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    address constant CONTROLLER = address(0x1111111111111111111111111111111111111111);
    address constant USER = address(0x2222222222222222222222222222222222222222);
    address constant STRATEGIST = address(0x5555555555555555555555555555555555555555);

    string constant STRATEGY_NAME = "TestStrategyPassiveManagerUniswap";

    AnalogVaultFactory factory;
    StrategyFactory strategyFactory;
    AnalogVault vault;
    TestStrategyPassiveManagerUniswap strategy;

    function setUp() public {
        string memory rpcUrl = "https://mainnet.base.org";
        try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {}
        vm.createSelectFork(rpcUrl);

        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");
        vm.label(POOL, "UNIV3_POOL");
        vm.label(CONTROLLER, "CONTROLLER");
        vm.label(USER, "USER");

        vm.deal(USER, 10 ether);

        // Deploy infra
        strategyFactory = new StrategyFactory(WETH, address(this), address(this), address(0));
        TestStrategyPassiveManagerUniswap stratImpl = new TestStrategyPassiveManagerUniswap();
        strategyFactory.addStrategy(STRATEGY_NAME, address(stratImpl));

        AnalogVault vaultImpl = new AnalogVault(USDC);
        AnalogVaultFactory factoryImpl = new AnalogVaultFactory();
        bytes memory initData = abi.encodeWithSelector(
            AnalogVaultFactory.initialize.selector,
            address(this), USDC, address(strategyFactory), CONTROLLER, address(vaultImpl)
        );
        factory = AnalogVaultFactory(address(new ERC1967Proxy(address(factoryImpl), initData)));

        // Create vault + strategy
        (address vaultAddr, address stratAddr) = factory.createVault(USER, STRATEGY_NAME);
        AnalogVault(payable(vaultAddr)).transferOwnership(USER);

        vault = AnalogVault(payable(vaultAddr));
        strategy = TestStrategyPassiveManagerUniswap(stratAddr);

        // Initialize strategy
        BStratFM.CommonAddresses memory common = BStratFM.CommonAddresses({
            vault: vaultAddr,
            unirouter: UNIROUTER,
            strategist: STRATEGIST,
            factory: address(strategyFactory)
        });
        bytes memory lpToken0ToNativePath = "";
        bytes memory lpToken1ToNativePath = abi.encodePacked(USDC, uint24(500), WETH);
        strategy.initialize(POOL, QUOTER, int24(25), lpToken0ToNativePath, lpToken1ToNativePath, common);

        // Set deviation so calm check passes (max < tickSpacing*4 = 40)
        strategy.setDeviation(int56(39));

        // Deposit 1000 USDC and execute to create LP position
        uint256 depositAmount = 1000e6;
        deal(USDC, USER, depositAmount, true);
        vm.startPrank(USER);
        IERC20(USDC).approve(vaultAddr, depositAmount);
        vault.deposit(depositAmount);
        vm.stopPrank();

        vm.prank(CONTROLLER);
        vault.depositExecute();

        // Verify LP position exists
        (uint256 bal0, uint256 bal1) = vault.balances();
        assertTrue(bal0 > 0 || bal1 > 0, "Strategy should have an active LP position");

        vm.roll(block.number + 10);
    }

    function _isPoolCalm() internal view returns (bool) {
        (, int24 currentTick, , uint16 card, , , ) = IUniswapV3PoolLike(POOL).slot0();
        if (card < 2) return false;
        uint32 interval = strategy.twapInterval();
        uint32[] memory ago = new uint32[](2);
        ago[0] = interval;
        ago[1] = 0;
        try IUniswapV3PoolLike(POOL).observe(ago) returns (int56[] memory cums, uint160[] memory) {
            int56 twap = (cums[1] - cums[0]) / int56(uint56(interval));
            int56 dev = int56(currentTick) - twap;
            if (dev < 0) dev = -dev;
            return dev <= strategy.maxTickDeviation();
        } catch {
            return false;
        }
    }

    /// @notice Test setPositionWidth with active LP position
    function test_update_positionWidth_as_owner() public {
        if (!_isPoolCalm()) { vm.skip(true); return; }

        int24 newWidth = int24(50);
        vm.prank(strategy.owner());
        strategy.setPositionWidth(newWidth);
        assertEq(strategy.positionWidth(), newWidth, "Position width should be updated");
    }

    /// @notice Non-owner cannot call setPositionWidth
    function test_update_positionWidth_as_non_owner_reverts() public {
        if (!_isPoolCalm()) { vm.skip(true); return; }

        vm.prank(address(0xBAD));
        vm.expectRevert();
        strategy.setPositionWidth(int24(50));
    }

    /// @notice Test updating deviation, twap interval, and position width together
    function test_update_all_config_parameters() public {
        if (!_isPoolCalm()) { vm.skip(true); return; }

        address owner = strategy.owner();

        vm.startPrank(owner);

        // Update position width first (before changing twap, which shifts the TWAP calc
        // and can cause NotCalm with the new interval on a fork)
        int24 newWidth = int24(50);
        strategy.setPositionWidth(newWidth);
        assertEq(strategy.positionWidth(), newWidth, "Position width updated");

        // Update deviation
        int56 newDeviation = int56(30);
        strategy.setDeviation(newDeviation);
        assertEq(strategy.maxTickDeviation(), newDeviation, "Deviation updated");

        // Update twap interval last (changes TWAP calculation window)
        uint32 newTwap = uint32(300);
        strategy.setTwapInterval(newTwap);
        assertEq(strategy.twapInterval(), newTwap, "TWAP interval updated");

        vm.stopPrank();
    }

    /// @notice Calling strategy setters on a non-strategy contract should fail
    function test_update_on_vault_address_fails() public {
        address fakeTarget = address(new FakeVault());
        (bool success, ) = fakeTarget.call(
            abi.encodeWithSignature("setPositionWidth(int24)", int24(50))
        );
        assertFalse(success, "Call to non-strategy contract should fail");
    }

    /// @notice Verify strategy config is readable after deployment + deposit
    function test_update_deployed_strategy() public {
        // Strategy deployed via setUp with active LP
        assertEq(strategy.positionWidth(), int24(25), "Initial position width");
        assertEq(strategy.maxTickDeviation(), int56(39), "Deviation set after init");
        assertEq(strategy.twapInterval(), uint32(120), "Default TWAP interval");
        assertTrue(strategy.isCalm(), "Pool should be calm");
        assertEq(strategy.pool(), POOL, "Pool address");
        assertEq(strategy.lpToken0(), WETH, "Token0 is WETH");
        assertEq(strategy.lpToken1(), USDC, "Token1 is USDC");
    }
}

/// @notice Minimal contract without strategy functions, used to test misrouted calls
contract FakeVault {
    fallback() external payable { revert(); }
}
