// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Re-export BeefyVaultConcLiq from beefy-zk for compilation
import {BeefyVaultConcLiq} from "beefy-zk/vault/BeefyVaultConcLiq.sol";

/**
 * @notice NOTE: The BeefyVaultConcLiq contract's initialize() function calls __Ownable_init()
 * but does NOT set ownership to msg.sender. The owner will be address(0) after initialization.
 *
 * The server code MUST set ownership after initializing the vault by calling transferOwnership().
 *
 * Since initialize() is not virtual, we cannot override it to set ownership automatically.
 * The deployment service should check and set ownership after vault initialization.
 */
