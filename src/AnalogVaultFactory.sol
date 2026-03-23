// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AnalogVault} from "./AnalogVault.sol";
import {StrategyFactory} from "./StrategyFactory.sol";
import {IStrategyConcLiq} from "beefy-zk/interfaces/beefy/IStrategyConcLiq.sol";

/**
 * @title AnalogVaultFactory
 * @notice Factory for deploying per-user AnalogVault instances (combined vault + wrapper)
 * @dev Deploys deterministic vault addresses for each user using CREATE2
 */
contract AnalogVaultFactory is Ownable {
    // Immutable addresses
    address public immutable usdc;
    address public immutable strategyFactory;

    // Mutable state
    address public controller;
    address public latestImplementation;

    // Mapping from user address to vault address
    mapping(address => address) public vaults;

    // Array of all deployed vaults
    address[] public allVaults;

    // Events
    event VaultCreated(
        address indexed user,
        address indexed vault,
        address indexed strategy
    );
    event ControllerUpdated(
        address indexed oldController,
        address indexed newController
    );
    event ImplementationUpdated(
        address indexed oldImplementation,
        address indexed newImplementation
    );

    // Errors
    error VaultAlreadyExists();
    error InvalidUser();
    error InvalidUSDC();
    error InvalidController();
    error InvalidStrategyFactory();
    error StrategyCreationFailed();
    error InvalidImplementation();
    error InitializationFailed();
    error VaultNotInitialized();

    /**
     * @notice Constructor sets immutable addresses and initial controller
     * @param _usdc USDC token address
     * @param _strategyFactory StrategyFactory address for creating strategies
     * @param _controller Initial controller address
     */
    constructor(
        address _usdc,
        address _strategyFactory,
        address _controller,
        address _implementation
    ) Ownable() {
        _transferOwnership(msg.sender);
        if (_usdc == address(0)) revert InvalidUSDC();
        if (_strategyFactory == address(0)) revert InvalidStrategyFactory();
        if (_controller == address(0)) revert InvalidController();
        if (_implementation == address(0)) revert InvalidImplementation();

        usdc = _usdc;
        strategyFactory = _strategyFactory;
        controller = _controller;
        latestImplementation = _implementation;
    }

    /**
     * @notice Create a vault and strategy for a user
     * @param user User address who will own the vault
     * @param strategyName Name of the strategy to create (e.g., "StrategyPassiveManagerUniswap")
     * @param vaultName Name of the vault token
     * @param vaultSymbol Symbol of the vault token
     * @return vault Address of the deployed vault
     * @return strategy Address of the deployed strategy
     */
    function createVault(
        address user,
        string calldata strategyName,
        string calldata vaultName,
        string calldata vaultSymbol
    ) external returns (address vault, address strategy) {
        if (user == address(0)) revert InvalidUser();
        if (vaults[user] != address(0)) revert VaultAlreadyExists();

        // Create strategy using StrategyFactory
        StrategyFactory factory = StrategyFactory(strategyFactory);
        strategy = factory.createStrategy(strategyName);
        if (strategy == address(0)) revert StrategyCreationFailed();

        // Deploy vault as UUPSProxy using CREATE2 with user address as salt
        bytes32 salt = bytes32(uint256(uint160(user)));

        // Deploy UUPSProxy pointing to latest implementation
        bytes memory initData = abi.encodeWithSelector(
            AnalogVault.initialize.selector,
            strategy,
            vaultName,
            vaultSymbol,
            controller,
            user
        );

        vault = address(
            new ERC1967Proxy{salt: salt}(latestImplementation, initData)
        );

        // Verify that initialization succeeded by checking vault state
        AnalogVault vaultContract = AnalogVault(payable(vault));
        address owner = vaultContract.owner();
        IStrategyConcLiq vaultStrategy = vaultContract.strategy();
        
        if (owner == address(0) || address(vaultStrategy) == address(0)) {
            revert InitializationFailed();
        }

        // Store vault only after successful initialization
        vaults[user] = vault;
        allVaults.push(vault);

        emit VaultCreated(user, vault, strategy);

        return (vault, strategy);
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
     * @notice Predict vault address for a user before deployment
     * @param user User address
     * @param strategyName Name of the strategy (needed for init data)
     * @param vaultName Name of the vault token (needed for init data)
     * @param vaultSymbol Symbol of the vault token (needed for init data)
     * @return Predicted vault address
     */
    function predictVaultAddress(
        address user,
        string calldata strategyName,
        string calldata vaultName,
        string calldata vaultSymbol
    ) external view returns (address) {
        bytes32 salt = bytes32(uint256(uint160(user)));

        // Note: We need to know the strategy address to predict the vault address
        // Since strategy creation is dynamic, we can't predict without creating the strategy first
        // This is a placeholder that assumes strategy address is known
        // In practice, you'd need to predict or know the strategy address

        // Calculate CREATE2 address for UUPSProxy
        bytes memory initData = abi.encodeWithSelector(
            AnalogVault.initialize.selector,
            address(0), // strategy - placeholder
            vaultName,
            vaultSymbol,
            controller,
            user
        );

        bytes memory proxyCreationCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(latestImplementation, initData)
        );

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(proxyCreationCode)
            )
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
     * @notice Get all deployed vault addresses
     * @return Array of vault addresses
     */
    function getAllVaults() external view returns (address[] memory) {
        return allVaults;
    }

    /**
     * @notice Update controller address for all future vaults
     * @param _controller New controller address
     */
    function setController(address _controller) external onlyOwner {
        if (_controller == address(0)) revert InvalidController();

        address oldController = controller;
        controller = _controller;

        emit ControllerUpdated(oldController, _controller);
    }

    /**
     * @notice Update controller for a specific vault
     * @param vault Vault address
     * @param _controller New controller address
     */
    function updateVaultController(
        address vault,
        address _controller
    ) external onlyOwner {
        if (_controller == address(0)) revert InvalidController();

        AnalogVault(payable(vault)).setController(_controller);
    }

    /**
     * @notice Batch update controller for multiple vaults
     * @param vaultAddresses Array of vault addresses
     * @param _controller New controller address
     */
    function batchUpdateVaultController(
        address[] calldata vaultAddresses,
        address _controller
    ) external onlyOwner {
        if (_controller == address(0)) revert InvalidController();

        uint256 count = vaultAddresses.length;
        for (uint256 i = 0; i < count; i++) {
            AnalogVault(payable(vaultAddresses[i])).setController(_controller);
        }
    }

    /**
     * @notice Batch upgrade controller for all deployed vaults
     * @param _controller New controller address
     */
    function batchUpdateAllVaultControllers(
        address _controller
    ) external onlyOwner {
        if (_controller == address(0)) revert InvalidController();

        uint256 count = allVaults.length;
        for (uint256 i = 0; i < count; i++) {
            AnalogVault(payable(allVaults[i])).setController(_controller);
        }
    }

    /**
     * @notice Set the latest implementation address for vault upgrades
     * @param _implementation Address of the new AnalogVault implementation
     */
    function setLatestImplementation(
        address _implementation
    ) external onlyOwner {
        if (_implementation == address(0)) revert InvalidImplementation();

        address oldImplementation = latestImplementation;
        latestImplementation = _implementation;

        emit ImplementationUpdated(oldImplementation, _implementation);
    }

    /**
     * @notice Get list of vaults that need upgrading to latest implementation
     * @dev Useful for identifying vaults that should be upgraded to get bug fixes
     * @dev Each vault owner must call upgradeToLatest() on their vault to upgrade
     * @return Array of vault addresses that are not on the latest implementation
     */
    function getVaultsNeedingUpgrade()
        external
        view
        returns (address[] memory)
    {
        address latest = latestImplementation;
        if (latest == address(0)) return new address[](0);

        address[] memory needingUpgrade = new address[](allVaults.length);
        uint256 count = 0;

        for (uint256 i = 0; i < allVaults.length; i++) {
            AnalogVault vault = AnalogVault(payable(allVaults[i]));
            address currentImpl = vault.getImplementation();

            if (currentImpl != latest) {
                needingUpgrade[count] = allVaults[i];
                count++;
            }
        }

        // Resize array to actual count
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = needingUpgrade[i];
        }

        return result;
    }

    /**
     * @notice Clear a broken/uninitialized vault from the factory mapping
     * @dev Allows overwriting a vault that failed to initialize properly
     * @dev Only owner can call this function
     * @param user User address whose vault should be cleared
     */
    function clearBrokenVault(address user) external onlyOwner {
        if (user == address(0)) revert InvalidUser();
        
        address existingVault = vaults[user];
        if (existingVault == address(0)) {
            // No vault to clear
            return;
        }

        // Verify vault is actually broken (uninitialized)
        try AnalogVault(payable(existingVault)).owner() returns (address owner) {
            if (owner != address(0)) {
                // Vault is initialized, don't allow clearing
                revert VaultNotInitialized();
            }
        } catch {
            // If call fails, vault is likely broken/uninitialized
        }

        // Clear the mapping
        delete vaults[user];
        
        // Note: We don't remove from allVaults array to maintain historical record
        // The array is only used for enumeration, not for preventing re-deployment
    }

    /**
     * @notice Check if a vault is properly initialized
     * @param vaultAddress Vault address to check
     * @return true if vault is initialized (has owner and strategy), false otherwise
     */
    function isVaultInitialized(address vaultAddress) external view returns (bool) {
        if (vaultAddress == address(0)) return false;
        
        try AnalogVault(payable(vaultAddress)).owner() returns (address owner) {
            if (owner == address(0)) return false;
            
            try AnalogVault(payable(vaultAddress)).strategy() returns (IStrategyConcLiq strategy) {
                return address(strategy) != address(0);
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }
}
