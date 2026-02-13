// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {AnalogVaultFactory} from "../src/AnalogVaultFactory.sol";
import {AnalogVault} from "../src/AnalogVault.sol";
import {AnalogBalancerVaultFactory} from "../src/AnalogBalancerVaultFactory.sol";
import {AnalogBalancerVault} from "../src/AnalogBalancerVault.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title UpgradeSecurityHardening
 * @notice Deploys new implementations with SwapExecutor security hardening
 *         and upgrades production UUPS proxies on Base mainnet.
 *
 * What this script does:
 *   1. Deploy new AnalogVault implementation (SwapExecutor selector whitelist)
 *   2. Deploy new AnalogVaultFactory implementation (createVault access control)
 *   3. Upgrade AnalogVaultFactory proxy to new implementation
 *   4. Set new AnalogVault as latestImplementation on factory
 *   5. Deploy new AnalogBalancerVaultFactory (non-upgradeable, fresh deploy)
 *
 * Run (dry-run):
 *   forge script script/UpgradeSecurityHardening.s.sol --rpc-url $BASE_RPC_URL -vvv
 *
 * Run (broadcast):
 *   forge script script/UpgradeSecurityHardening.s.sol --rpc-url $BASE_RPC_URL --broadcast -vvv
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY - Must be the factory owner
 *   BALANCER_VAULT       - Balancer v3 Vault on Base
 *   BALANCER_ROUTER      - Balancer v3 Router on Base
 *   BALANCER_POOL        - Balancer pool address (also BPT token)
 *   BALANCER_TOKEN0      - First pool token
 *   BALANCER_TOKEN1      - Second pool token
 */
contract UpgradeSecurityHardening is Script {
    // ── Production addresses on Base mainnet ──
    address constant ANALOG_VAULT_FACTORY_PROXY = 0x6eD8b0511742c0208Bc6Be15B97b2923C52C0e9D;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("AnalogVaultFactory proxy:", ANALOG_VAULT_FACTORY_PROXY);

        // Verify deployer is the factory owner
        AnalogVaultFactory factory = AnalogVaultFactory(ANALOG_VAULT_FACTORY_PROXY);
        address currentOwner = factory.owner();
        console.log("Factory owner:", currentOwner);
        require(deployer == currentOwner, "Deployer must be factory owner");

        address oldVaultImpl = factory.latestImplementation();
        console.log("Current vault implementation:", oldVaultImpl);

        vm.startBroadcast(deployerPrivateKey);

        // ── Step 1: Deploy new AnalogVault implementation ──
        AnalogVault newVaultImpl = new AnalogVault();
        console.log("New AnalogVault implementation:", address(newVaultImpl));

        // ── Step 2: Deploy new AnalogVaultFactory implementation ──
        AnalogVaultFactory newFactoryImpl = new AnalogVaultFactory();
        console.log("New AnalogVaultFactory implementation:", address(newFactoryImpl));

        // ── Step 3: Upgrade factory proxy to new implementation ──
        UUPSUpgradeable(ANALOG_VAULT_FACTORY_PROXY).upgradeTo(address(newFactoryImpl));
        console.log("Factory proxy upgraded");

        // ── Step 4: Set new vault implementation ──
        factory.setLatestImplementation(address(newVaultImpl));
        console.log("latestImplementation updated");

        // ── Step 5: Deploy new AnalogBalancerVaultFactory ──
        address balVault = vm.envAddress("BALANCER_VAULT");
        address balRouter = vm.envAddress("BALANCER_ROUTER");
        address balPool = vm.envAddress("BALANCER_POOL");
        address token0 = vm.envAddress("BALANCER_TOKEN0");
        address token1 = vm.envAddress("BALANCER_TOKEN1");

        AnalogBalancerVaultFactory newBalancerFactory = new AnalogBalancerVaultFactory(
            deployer, // owner
            USDC,
            balVault,
            balRouter,
            balPool,
            token0,
            token1,
            ONEINCH_ROUTER,
            deployer // controller
        );
        console.log("New AnalogBalancerVaultFactory:", address(newBalancerFactory));

        vm.stopBroadcast();

        // ── Summary ──
        console.log("\n=== Upgrade Summary ===");
        console.log("AnalogVaultFactory proxy:     ", ANALOG_VAULT_FACTORY_PROXY);
        console.log("  New factory impl:           ", address(newFactoryImpl));
        console.log("  New vault impl:             ", address(newVaultImpl));
        console.log("  Old vault impl:             ", oldVaultImpl);
        console.log("New AnalogBalancerVaultFactory:", address(newBalancerFactory));
        console.log("\nNext steps:");
        console.log("  1. Verify contracts on Basescan");
        console.log("  2. Update server config with new BalancerFactory address");
        console.log("  3. Call upgradeToLatest() on existing vaults");
    }
}
