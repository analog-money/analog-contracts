// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AnalogVault} from "../src/AnalogVault.sol";
import {AnalogVaultFactory} from "../src/AnalogVaultFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Minimal mock strategy so initialize() doesn't revert on address(0)
contract MockStrategy {
    function lpToken0() external pure returns (address) { return address(0); }
    function lpToken1() external pure returns (address) { return address(0); }
}

contract AnalogVaultUpgradeAuthTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant FACTORY_ADDR = 0x6eD8b0511742c0208Bc6Be15B97b2923C52C0e9D;

    AnalogVaultFactory factory;
    AnalogVault vault;
    address owner;

    function setUp() public {
        string memory rpcUrl = "https://api.developer.coinbase.com/rpc/v1/base/SF6TF2InaVNiSGPhP3Up4b62uEhp1qme";
        try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {}
        vm.createSelectFork(rpcUrl);

        factory = AnalogVaultFactory(FACTORY_ADDR);
        owner = factory.owner();

        AnalogVault goodImpl = new AnalogVault(USDC);

        vm.prank(owner);
        factory.setLatestImplementation(address(goodImpl));

        MockStrategy mockStrategy = new MockStrategy();
        bytes memory initData = abi.encodeCall(
            AnalogVault.initialize,
            (owner, owner, address(mockStrategy))
        );
        vm.prank(address(factory));
        ERC1967Proxy proxy = new ERC1967Proxy(address(goodImpl), initData);
        vault = AnalogVault(payable(address(proxy)));
    }

    function test_upgrade_with_valid_implementation() public {
        AnalogVault newImpl = new AnalogVault(USDC);

        vm.prank(owner);
        factory.setLatestImplementation(address(newImpl));

        vm.prank(owner);
        vault.upgradeToLatest();
    }

    function test_upgrade_rejects_non_owner() public {
        AnalogVault newImpl = new AnalogVault(USDC);

        vm.prank(owner);
        factory.setLatestImplementation(address(newImpl));

        address rando = address(0xdead);
        vm.prank(rando);
        vm.expectRevert(); // OwnableUpgradeable: caller is not the owner
        vault.upgradeToLatest();
    }

    function test_upgrade_rejects_non_factory_implementation() public {
        // Deploy impl but don't set it as factory latest
        AnalogVault newImpl = new AnalogVault(USDC);

        // Try to upgrade directly (bypassing factory)
        vm.prank(owner);
        vm.expectRevert(AnalogVault.InvalidStrategy.selector);
        vault.upgradeTo(address(newImpl));
    }

    function test_upgrade_noop_when_already_latest() public {
        // Vault is already on latest — upgradeToLatest should be a no-op
        vm.prank(owner);
        vault.upgradeToLatest(); // Should not revert
    }
}
