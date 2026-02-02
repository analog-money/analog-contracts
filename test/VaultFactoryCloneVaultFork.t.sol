// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

interface IBeefyVaultConcLiqFactory {
    function cloneVault() external returns (address);
}

contract VaultFactoryCloneVaultForkTest is Test {
    // Current on-chain addresses
    address constant VAULT_FACTORY = 0x433ef25B875dAecf47d2DbD648D2438bbAea0C5C; // Newly deployed factory
    address constant DEPLOYER = 0x25e21aBcd8FF244914eb03dA2EBA7ea62EfF6821; // Deployer address

    function setUp() public {
        vm.label(VAULT_FACTORY, "VAULT_FACTORY");
        vm.label(DEPLOYER, "DEPLOYER");
        vm.deal(DEPLOYER, 100 ether);
    }

    function test_cloneVault_on_fork() public {
        vm.startPrank(DEPLOYER);

        IBeefyVaultConcLiqFactory factory = IBeefyVaultConcLiqFactory(VAULT_FACTORY);

        emit log_address(VAULT_FACTORY);
        emit log_address(DEPLOYER);
        
        console.log("Factory address:", VAULT_FACTORY);
        console.log("Caller (deployer):", DEPLOYER);

        // Try to clone vault - this will show the exact revert reason with -vvvv
        // The -vvvv flag will show the full trace and revert reason
        console.log("Calling cloneVault()...");
        address vault = factory.cloneVault();
        
        console.log("Vault cloned successfully!");
        console.log("Vault address:", vault);
        
        assertTrue(vault != address(0), "Vault address should not be zero");
        
        vm.stopPrank();
    }
}

