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
}

interface IStrategyFactoryLike {
    function native() external view returns (address);
    function getImplementation(string calldata) external view returns (address);
}

contract StrategyInitCurrentTest is Test {
    // Current on-chain addresses we use in prod path
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address constant UNIROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant FACTORY = 0xf5628a987928B642620B9eA7A1648d280F3Cd035; // StrategyFactory
    address constant VAULT = 0x1f17cD1a0c4485f038bcEd68b8a66614df5E1132; // Vault
    address constant STRATEGIST = 0x5811F3BDd678d68b2fA1e107750017b68D2aBD92; // user
    int24 constant POSITION_WIDTH = 70; // match current attempt

    address deployer = 0x25e21aBcd8FF244914eb03dA2EBA7ea62EfF6821;

    function setUp() public {
        // Fork Base mainnet to get real contracts
        string memory rpcUrl = "https://mainnet.base.org";
        try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {}
        vm.createSelectFork(rpcUrl);

        vm.deal(deployer, 100 ether);
        vm.label(POOL, "UNIV3_POOL");
        vm.label(QUOTER, "UNIV3_QUOTER");
        vm.label(UNIROUTER, "UNIROUTER");
        vm.label(FACTORY, "STRATEGY_FACTORY");
        vm.label(VAULT, "VAULT");
    }

    function test_initialize_current_setup() public {
        vm.startPrank(deployer);

        // Use the implementation registered in the StrategyFactory
        address impl = IStrategyFactoryLike(FACTORY).getImplementation(
            "StrategyPassiveManagerUniswap"
        );
        emit log_address(impl);

        // Create a beacon that points to that implementation, then a proxy
        UpgradeableBeacon beacon = new UpgradeableBeacon(impl);
        BeaconProxy proxy = new BeaconProxy(address(beacon), "");
        address proxyAddr = address(proxy);
        vm.label(proxyAddr, "STRATEGY_PROXY");

        // Sanity
        emit log_address(IStrategyFactoryLike(FACTORY).native());
        assertTrue(
            IUniswapV3PoolLike(POOL).token0() != address(0),
            "pool token0"
        );
        assertTrue(
            IUniswapV3PoolLike(POOL).token1() != address(0),
            "pool token1"
        );

        // Build CommonAddresses with Beefy's layout
        BStratFM.CommonAddresses memory common = BStratFM.CommonAddresses({
            vault: VAULT,
            unirouter: UNIROUTER,
            strategist: STRATEGIST,
            factory: FACTORY
        });

        // Initialize with exact params currently used by server
        StrategyPassiveManagerUniswap strat = StrategyPassiveManagerUniswap(
            payable(proxyAddr)
        );
        
        // Pool has: token0=WETH, token1=USDC
        // lpToken0ToNativePath: token0 (WETH) -> native (WETH is native, so empty)
        // lpToken1ToNativePath: token1 (USDC) -> native (WETH) = USDC -> WETH path
        bytes memory lpToken0ToNativePath = hex""; // WETH is already native
        bytes memory lpToken1ToNativePath = hex"833589fCD6eDb6E08f4c7C32D4f71b54bdA029130001f44200000000000000000000000000000000000006"; // USDC -> WETH

        // Try initialize - will revert with InvalidInput if something is wrong
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
        vm.stopPrank();
    }
}
