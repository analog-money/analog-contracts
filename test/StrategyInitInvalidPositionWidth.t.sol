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

contract StrategyInitInvalidPositionWidthTest is Test {
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address constant UNIROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant FACTORY = 0xf5628a987928B642620B9eA7A1648d280F3Cd035;
    address constant VAULT = 0x1882b6aEE341F1bE6552da986AD146e8F2188D0B;
    address constant STRATEGIST = 0x5811F3BDd678d68b2fA1e107750017b68D2aBD92;

    address deployer = 0x25e21aBcd8FF244914eb03dA2EBA7ea62EfF6821;

    function setUp() public {
        string memory rpcUrl = "https://mainnet.base.org";
        try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {}
        vm.createFork(rpcUrl);
        
        vm.deal(deployer, 100 ether);
        vm.deal(STRATEGIST, 100 ether);
    }

    function test_initialize_with_positionWidth_25_should_fail() public {
        vm.startPrank(deployer);

        address impl = IStrategyFactoryLike(FACTORY).getImplementation("StrategyPassiveManagerUniswap");
        require(impl != address(0), "Implementation not found");

        UpgradeableBeacon beacon = new UpgradeableBeacon(impl);
        BeaconProxy proxy = new BeaconProxy(address(beacon), "");
        address proxyAddr = address(proxy);

        address nativeToken = IStrategyFactoryLike(FACTORY).native();
        address token0 = IUniswapV3PoolLike(POOL).token0();
        address token1 = IUniswapV3PoolLike(POOL).token1();
        int24 tickSpacing = IUniswapV3PoolLike(POOL).tickSpacing();
        
        emit log_named_int("Tick spacing", tickSpacing);
        emit log_named_int("Position width", 25);
        emit log_named_string("Is multiple?", (25 % int(tickSpacing) == 0) ? "YES" : "NO");

        BStratFM.CommonAddresses memory common = BStratFM.CommonAddresses({
            vault: VAULT,
            unirouter: UNIROUTER,
            strategist: STRATEGIST,
            factory: FACTORY
        });

        bytes memory lpToken0ToNativePath = hex"";
        bytes memory lpToken1ToNativePath = hex"833589fCD6eDb6E08f4c7C32D4f71b54bdA029130001f44200000000000000000000000000000000000006";

        StrategyPassiveManagerUniswap strat = StrategyPassiveManagerUniswap(payable(proxyAddr));

        // This should revert with InvalidInput if positionWidth is not a multiple of tickSpacing
        strat.initialize(
            POOL,
            QUOTER,
            int24(25), // Not a multiple of tickSpacing (10)
            lpToken0ToNativePath,
            lpToken1ToNativePath,
            common
        );

        vm.stopPrank();
    }
}



