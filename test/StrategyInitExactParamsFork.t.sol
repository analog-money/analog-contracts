// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {StrategyPassiveManagerUniswap} from "beefy-zk/strategies/uniswap/StrategyPassiveManagerUniswap.sol";
import {StratFeeManagerInitializable as BStratFM} from "beefy-zk/strategies/StratFeeManagerInitializable.sol";

interface IUniswapV3PoolLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
}

interface IStrategyFactoryLike {
    function native() external view returns (address);
    function getImplementation(string calldata) external view returns (address);
}

contract StrategyInitExactParamsForkTest is Test {
    // EXACT PARAMETERS FROM THE ERROR
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address constant UNIROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant FACTORY = 0xf5628a987928B642620B9eA7A1648d280F3Cd035;
    address constant VAULT = 0x1882b6aEE341F1bE6552da986AD146e8F2188D0B; // NEW VAULT FROM ERROR
    address constant STRATEGIST = 0x5811F3BDd678d68b2fA1e107750017b68D2aBD92;
    int24 constant POSITION_WIDTH = 10; // CURRENT VALUE FROM ERROR (tickSpacing=10, so this is valid)

    // Use the actual deployer from the factory or a test account
    address deployer = 0x25e21aBcd8FF244914eb03dA2EBA7ea62EfF6821;

    function setUp() public {
        // Fork Base mainnet - use default RPC if env var not set
        string memory rpcUrl = "https://mainnet.base.org";
        try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {}
        vm.createFork(rpcUrl);
        
        vm.deal(deployer, 100 ether);
        vm.deal(STRATEGIST, 100 ether);
        
        vm.label(POOL, "UNIV3_POOL");
        vm.label(QUOTER, "UNIV3_QUOTER");
        vm.label(UNIROUTER, "UNIROUTER");
        vm.label(FACTORY, "STRATEGY_FACTORY");
        vm.label(VAULT, "VAULT");
        vm.label(STRATEGIST, "STRATEGIST");
    }

    function test_initialize_exact_params() public {
        vm.startPrank(deployer);

        // Get the implementation from factory
        address impl = IStrategyFactoryLike(FACTORY).getImplementation(
            "StrategyPassiveManagerUniswap"
        );
        emit log_address(impl);
        require(impl != address(0), "Implementation not found");

        // Create beacon and proxy (simulating factory deployment)
        UpgradeableBeacon beacon = new UpgradeableBeacon(impl);
        BeaconProxy proxy = new BeaconProxy(address(beacon), "");
        address proxyAddr = address(proxy);
        vm.label(proxyAddr, "STRATEGY_PROXY");

        // Get native token from factory
        address nativeToken = IStrategyFactoryLike(FACTORY).native();
        emit log_address(nativeToken);
        emit log_named_address("Native token", nativeToken);

        // Get pool tokens
        address token0 = IUniswapV3PoolLike(POOL).token0();
        address token1 = IUniswapV3PoolLike(POOL).token1();
        int24 tickSpacing = IUniswapV3PoolLike(POOL).tickSpacing();
        
        emit log_named_address("Pool token0", token0);
        emit log_named_address("Pool token1", token1);
        emit log_named_int("Tick spacing", tickSpacing);
        emit log_named_int("Position width", POSITION_WIDTH);

        // Build CommonAddresses
        BStratFM.CommonAddresses memory common = BStratFM.CommonAddresses({
            vault: VAULT,
            unirouter: UNIROUTER,
            strategist: STRATEGIST,
            factory: FACTORY
        });

        // Determine swap paths based on pool tokens and native token
        bytes memory lpToken0ToNativePath;
        bytes memory lpToken1ToNativePath;

        // If token0 is native, path is empty
        if (token0 == nativeToken) {
            lpToken0ToNativePath = hex"";
            emit log("token0 is native, using empty path");
        } else {
            // token0 -> native path needed
            // For USDC -> WETH: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 (USDC) + fee (0.05% = 500) + 0x4200000000000000000000000000000000000006 (WETH)
            // Format: token0 (20 bytes) + fee (3 bytes) + native (20 bytes)
            if (token0 == 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) { // USDC
                lpToken0ToNativePath = hex"833589fCD6eDb6E08f4c7C32D4f71b54bdA029130001f44200000000000000000000000000000000000006";
                emit log("token0 is USDC, using USDC->WETH path");
            } else {
                lpToken0ToNativePath = hex"";
                emit log("token0 path unknown, using empty");
            }
        }

        // If token1 is native, path is empty
        if (token1 == nativeToken) {
            lpToken1ToNativePath = hex"";
            emit log("token1 is native, using empty path");
        } else {
            // token1 -> native path needed
            if (token1 == 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) { // USDC
                lpToken1ToNativePath = hex"833589fCD6eDb6E08f4c7C32D4f71b54bdA029130001f44200000000000000000000000000000000000006";
                emit log("token1 is USDC, using USDC->WETH path");
            } else {
                lpToken1ToNativePath = hex"";
                emit log("token1 path unknown, using empty");
            }
        }

        // Initialize strategy
        StrategyPassiveManagerUniswap strat = StrategyPassiveManagerUniswap(
            payable(proxyAddr)
        );

        emit log("Attempting initialize with:");
        emit log_named_address("Pool", POOL);
        emit log_named_address("Quoter", QUOTER);
        emit log_named_int("Position width", POSITION_WIDTH);
        emit log_named_address("Vault", VAULT);
        emit log_named_address("Unirouter", UNIROUTER);
        emit log_named_address("Strategist", STRATEGIST);
        emit log_named_address("Factory", FACTORY);
        emit log_named_bytes("lpToken0ToNativePath", lpToken0ToNativePath);
        emit log_named_bytes("lpToken1ToNativePath", lpToken1ToNativePath);

        // This will revert with -vvvv showing the exact reason
        strat.initialize(
            POOL,
            QUOTER,
            POSITION_WIDTH,
            lpToken0ToNativePath,
            lpToken1ToNativePath,
            common
        );

        // Post checks
        assertEq(strat.vault(), VAULT, "vault set");
        assertEq(strat.pool(), POOL, "pool set");
        assertEq(strat.owner(), deployer, "owner set");

        vm.stopPrank();
    }
}

