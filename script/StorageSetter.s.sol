// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title StorageSetter
 * @notice Simple contract to set storage slots for emergency recovery
 */
contract StorageSetter {
  // ERC1967 implementation slot
  bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

  /**
   * @notice Set the implementation slot for a proxy contract
   * @param proxyAddress The proxy contract address
   * @param implementationAddress The implementation contract address
   */
  function setImplementation(address proxyAddress, address implementationAddress) external {
    bytes32 slotValue = bytes32(uint256(uint160(implementationAddress)));
    assembly {
      sstore(IMPLEMENTATION_SLOT, slotValue)
    }
  }

  /**
   * @notice Get the current implementation for a proxy
   * @param proxyAddress The proxy contract address
   * @return The implementation address
   */
  function getImplementation(address proxyAddress) external view returns (address) {
    bytes32 slotValue;
    assembly {
      slotValue := sload(IMPLEMENTATION_SLOT)
    }
    return address(uint160(uint256(slotValue)));
  }
}