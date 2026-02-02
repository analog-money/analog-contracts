// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AnalogBalancerVault} from "./AnalogBalancerVault.sol";

/**
 * @title AnalogBalancerVaultFactory
 * @notice Factory for deploying per-user AnalogBalancerVault instances
 * @dev Deploys deterministic vault addresses for each user using CREATE2
 */
contract AnalogBalancerVaultFactory is Ownable {
  // Immutable addresses
  address public immutable usdc;
  address public immutable balancerVault;
  address public immutable balancerRouter;
  address public immutable pool;
  address public immutable token0;
  address public immutable token1;
  address public immutable router;

  // Mutable state
  address public controller;

  // Mapping from user address to vault address
  mapping(address => address) public vaults;

  // Array of all deployed vaults
  address[] public allVaults;

  // Events
  event VaultCreated(address indexed user, address indexed vault);
  event ControllerUpdated(address indexed oldController, address indexed newController);

  // Errors
  error VaultAlreadyExists();
  error InvalidUser();
  error InvalidUSDC();
  error InvalidController();
  error InvalidBalancerVault();
  error InvalidBalancerRouter();
  error InvalidPool();
  error InvalidTokens();
  error InvalidRouter();

  /**
   * @notice Constructor sets immutable addresses and initial controller
   * @param _usdc USDC token address
   * @param _balancerVault Balancer v3 Vault address
   * @param _balancerRouter Balancer v3 Router address
   * @param _pool Balancer pool address
   * @param _token0 First pool token (e.g., GHO)
   * @param _token1 Second pool token (e.g., USDC)
   * @param _router 1inch router address
   * @param _controller Initial controller address
   */
  constructor(
    address _usdc,
    address _balancerVault,
    address _balancerRouter,
    address _pool,
    address _token0,
    address _token1,
    address _router,
    address _controller
  ) Ownable() {
    _transferOwnership(msg.sender);
    if (_usdc == address(0)) revert InvalidUSDC();
    if (_balancerVault == address(0)) revert InvalidBalancerVault();
    if (_balancerRouter == address(0)) revert InvalidBalancerRouter();
    if (_pool == address(0)) revert InvalidPool();
    if (_token0 == address(0) || _token1 == address(0)) revert InvalidTokens();
    if (_router == address(0)) revert InvalidRouter();
    if (_controller == address(0)) revert InvalidController();

    usdc = _usdc;
    balancerVault = _balancerVault;
    balancerRouter = _balancerRouter;
    pool = _pool;
    token0 = _token0;
    token1 = _token1;
    router = _router;
    controller = _controller;
  }

  /**
   * @notice Create a vault for a user
   * @param user User address who will own the vault
   * @param vaultName Name of the vault token
   * @param vaultSymbol Symbol of the vault token
   * @return vault Address of the deployed vault
   */
  function createVault(
    address user,
    string calldata vaultName,
    string calldata vaultSymbol
  ) external returns (address vault) {
    if (user == address(0)) revert InvalidUser();
    if (vaults[user] != address(0)) revert VaultAlreadyExists();

    // Deploy vault using CREATE2 with user address as salt
    bytes32 salt = bytes32(uint256(uint160(user)));

    // Deploy AnalogBalancerVault directly (not a proxy)
    vault = address(
      new AnalogBalancerVault{salt: salt}(
        user,
        usdc,
        balancerVault,
        balancerRouter,
        pool,
        token0,
        token1,
        router,
        vaultName,
        vaultSymbol
      )
    );

    // Verify that vault was created successfully
    AnalogBalancerVault vaultContract = AnalogBalancerVault(vault);
    address owner = vaultContract.owner();
    if (owner != user) revert InvalidUser();

    // Store vault only after successful deployment
    vaults[user] = vault;
    allVaults.push(vault);

    emit VaultCreated(user, vault);

    return vault;
  }

  /**
   * @notice Get vault address for a user (returns 0 if not deployed)
   * @param user User address
   * @return Address of the user's vault, or 0 if not deployed
   */
  function getVault(address user) external view returns (address) {
    return vaults[user];
  }

  /**
   * @notice Predict vault address for a user (before deployment)
   * @param user User address
   * @param vaultName Name of the vault token (needed for bytecode)
   * @param vaultSymbol Symbol of the vault token (needed for bytecode)
   * @return Predicted vault address
   */
  function predictVaultAddress(
    address user,
    string calldata vaultName,
    string calldata vaultSymbol
  ) external view returns (address) {
    bytes32 salt = bytes32(uint256(uint160(user)));

    // Calculate CREATE2 address for AnalogBalancerVault
    bytes memory creationCode = abi.encodePacked(
      type(AnalogBalancerVault).creationCode,
      abi.encode(
        user,
        usdc,
        balancerVault,
        balancerRouter,
        pool,
        token0,
        token1,
        router,
        vaultName,
        vaultSymbol
      )
    );

    bytes32 hash = keccak256(
      abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(creationCode))
    );
    return address(uint160(uint256(hash)));
  }

  /**
   * @notice Get total number of deployed vaults
   * @return Total vault count
   */
  function getVaultCount() external view returns (uint256) {
    return allVaults.length;
  }

  /**
   * @notice Update controller address (only owner)
   * @param _controller New controller address
   */
  function setController(address _controller) external onlyOwner {
    if (_controller == address(0)) revert InvalidController();
    address oldController = controller;
    controller = _controller;
    emit ControllerUpdated(oldController, _controller);
  }
  /**
   * @notice Get all deployed vault addresses
   * @return Array of vault addresses
   */
  function getAllVaults() external view returns (address[] memory) {
    return allVaults;
  }
}



