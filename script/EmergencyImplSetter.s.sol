// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title EmergencyImplSetter
 * @notice Emergency contract to set implementation slot for broken proxies
 */
contract EmergencyImplSetter {
  // ERC1967 implementation slot
  bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

  // Factory latest implementation (from deployment logs)
  address constant LATEST_IMPL = 0xf4273487854676f1e92D8199c25c7E4FaB1Bc653;

  // Target vault
  address constant VAULT = 0x69437064aCC9F8408A198315267684bc34fA0AE4;

  constructor() {
    // Set the implementation slot for the vault
    setImplementation();
  }

  function setImplementation() internal {
    // Use assembly to set the storage slot
    bytes32 slotValue = bytes32(uint256(uint160(LATEST_IMPL)));
    assembly {
      sstore(IMPLEMENTATION_SLOT, slotValue)
    }
  }

  function verify() external view returns (address currentImpl, address expectedImpl) {
    bytes32 slotValue;
    assembly {
      slotValue := sload(IMPLEMENTATION_SLOT)
    }
    currentImpl = address(uint160(uint256(slotValue)));
    expectedImpl = LATEST_IMPL;
  }
}