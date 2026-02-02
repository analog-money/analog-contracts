// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title SetImplementationSlot
 * @notice Contract that can set the implementation slot for a vault
 */
contract SetImplementationSlot {
  // ERC1967 implementation slot
  bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

  // Target vault
  address constant VAULT = 0x69437064aCC9F8408A198315267684bc34fA0AE4;

  // New implementation
  address constant NEW_IMPL = 0x94830d3645B9A0e2d0E6986536Eb7400E8f66A82;

  constructor() {
    // Set the implementation slot directly
    bytes32 slotValue = bytes32(uint256(uint160(NEW_IMPL)));
    assembly {
      sstore(IMPLEMENTATION_SLOT, slotValue)
    }
  }

  function verify() external view returns (address currentImpl, address expectedImpl, bool isSet) {
    bytes32 slotValue;
    assembly {
      slotValue := sload(IMPLEMENTATION_SLOT)
    }
    currentImpl = address(uint160(uint256(slotValue)));
    expectedImpl = NEW_IMPL;
    isSet = currentImpl == expectedImpl;
  }
}