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
}

interface IBeefyVaultConcLiqLike {
    function initialize(address _strategy, string calldata _name, string calldata _symbol, uint256 _approvalDelay) external;
}

contract StrategyInitForkTest is Test {
    // Base Mainnet known addresses
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // USDC-WETH
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a; // Uniswap V3 Quoter
    address constant UNIROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481; // Swapper used by strat
    address constant STRATEGY_FACTORY = 0x09e98675dfB5518da0839bfa80a828AcEE527c80; // Our StrategyFactory
    // Existing vault (as used in server logs)
    address constant VAULT = 0x1f17cD1a0c4485f038bcEd68b8a66614df5E1132;

    // Deployer/key for broadcasting transactions on fork
    address deployer = address(0xdeadbeef);

    function setUp() public {
        // Label known addresses for nicer traces
        vm.label(POOL, "UNIV3_POOL_USDC_WETH");
        vm.label(QUOTER, "UNIV3_QUOTER");
        vm.label(UNIROUTER, "UNIROUTER");
        vm.label(STRATEGY_FACTORY, "STRATEGY_FACTORY");
        vm.label(VAULT, "BEEFY_VAULT");

        // Give deployer some ETH on fork for gas
        vm.deal(deployer, 100 ether);
    }

    function test_initialize_strategy_proxy() public {
        vm.startPrank(deployer);

        // 1) Deploy implementation
        StrategyPassiveManagerUniswap impl = new StrategyPassiveManagerUniswap();

        // 2) Deploy beacon and set implementation
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl));
        // Transfer beacon ownership to self to simulate factory control
        // (Beacon constructor owner is msg.sender per OZ; we are msg.sender)
        // No action needed; we own it already here.

        // 3) Deploy BeaconProxy
        BeaconProxy proxy = new BeaconProxy(address(beacon), "");
        address proxyAddr = address(proxy);
        vm.label(proxyAddr, "STRATEGY_PROXY");

        // Sanity: factory native
        address nativeToken = IStrategyFactoryLike(STRATEGY_FACTORY).native();
        emit log_address(nativeToken);

        // 4) Prepare initialize arguments
        BStratFM.CommonAddresses memory common = BStratFM.CommonAddresses({
            vault: VAULT,
            unirouter: UNIROUTER,
            strategist: deployer,
            factory: STRATEGY_FACTORY
        });

        // Validate pool looks sane
        address t0 = IUniswapV3PoolLike(POOL).token0();
        address t1 = IUniswapV3PoolLike(POOL).token1();
        assertTrue(t0 != address(0) && t1 != address(0), "pool tokens");

        // 5) Call initialize on proxy (delegatecall into impl)
        // Using interface type for clarity
        StrategyPassiveManagerUniswap strat = StrategyPassiveManagerUniswap(payable(proxyAddr));

        bytes memory emptyPath = hex"";

        // Expect no revert; if it reverts, -vvvv will show where
        strat.initialize(
            POOL,
            QUOTER,
            int24(25),
            emptyPath,
            emptyPath,
            common
        );

        // 6) Post conditions
        assertEq(strat.vault(), VAULT, "vault set");
        assertEq(strat.pool(), POOL, "pool set");
        assertEq(strat.owner(), deployer, "owner set");

        vm.stopPrank();
    }
}


