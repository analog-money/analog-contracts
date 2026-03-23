// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VaultWrapper} from "./VaultWrapper.sol";

/**
 * @title VaultWrapperFactory
 * @notice Factory for deploying per-user VaultWrapper instances using CREATE2
 * @dev Deploys deterministic wrapper addresses for each user
 */
contract VaultWrapperFactory is Ownable {
    // USDC address (Base mainnet)
    address public immutable usdc;
    
    // Controller address that can trigger swaps/deposits
    address public controller;
    
    // Mapping from user address to wrapper address
    mapping(address => address) public wrappers;
    
    // Array of all deployed wrappers
    address[] public allWrappers;
    
    // Events
    event WrapperCreated(address indexed user, address indexed wrapper);
    event ControllerUpdated(address indexed oldController, address indexed newController);
    
    // Errors
    error WrapperAlreadyExists();
    error InvalidUser();
    error InvalidController();
    
    /**
     * @notice Constructor sets USDC address and initial controller
     * @param _usdc USDC token address
     * @param _controller Initial controller address
     */
    constructor(address _usdc, address _controller) Ownable() {
        _transferOwnership(msg.sender);
        usdc = _usdc;
        controller = _controller;
    }
    
    /**
     * @notice Deploy a wrapper for a user using CREATE2 for deterministic address
     * @param user User address who will own the wrapper
     * @return wrapper Address of the deployed wrapper
     */
    function createWrapper(address user) external returns (address wrapper) {
        if (user == address(0)) revert InvalidUser();
        if (wrappers[user] != address(0)) revert WrapperAlreadyExists();
        
        // Deploy wrapper using CREATE2 with user address as salt
        bytes32 salt = bytes32(uint256(uint160(user)));
        wrapper = address(new VaultWrapper{salt: salt}(user, usdc));
        
        // Initialize wrapper with controller
        VaultWrapper(payable(wrapper)).initialize(controller);
        
        // Store wrapper
        wrappers[user] = wrapper;
        allWrappers.push(wrapper);
        
        emit WrapperCreated(user, wrapper);
        
        return wrapper;
    }
    
    /**
     * @notice Get wrapper address for a user (returns 0 if not deployed)
     * @param user User address
     * @return Address of the user's wrapper, or 0 if not deployed
     */
    function getWrapper(address user) external view returns (address) {
        return wrappers[user];
    }
    
    /**
     * @notice Predict wrapper address for a user before deployment
     * @param user User address
     * @return Predicted wrapper address
     */
    function predictWrapperAddress(address user) external view returns (address) {
        bytes32 salt = bytes32(uint256(uint160(user)));
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(abi.encodePacked(
                    type(VaultWrapper).creationCode,
                    abi.encode(user, usdc)
                ))
            )
        );
        return address(uint160(uint256(hash)));
    }
    
    /**
     * @notice Get total number of deployed wrappers
     * @return Total wrapper count
     */
    function getWrapperCount() external view returns (uint256) {
        return allWrappers.length;
    }
    
    /**
     * @notice Get all deployed wrapper addresses
     * @return Array of wrapper addresses
     */
    function getAllWrappers() external view returns (address[] memory) {
        return allWrappers;
    }
    
    /**
     * @notice Update controller address for all future wrappers
     * @param _controller New controller address
     */
    function setController(address _controller) external onlyOwner {
        if (_controller == address(0)) revert InvalidController();
        
        address oldController = controller;
        controller = _controller;
        
        emit ControllerUpdated(oldController, _controller);
    }
    
    /**
     * @notice Update controller for a specific wrapper
     * @param wrapper Wrapper address
     * @param _controller New controller address
     */
    function updateWrapperController(address wrapper, address _controller) external onlyOwner {
        if (_controller == address(0)) revert InvalidController();
        
        VaultWrapper(payable(wrapper)).setController(_controller);
    }
    
    /**
     * @notice Batch update controller for multiple wrappers
     * @param wrapperAddresses Array of wrapper addresses
     * @param _controller New controller address
     */
    function batchUpdateWrapperController(
        address[] calldata wrapperAddresses,
        address _controller
    ) external onlyOwner {
        if (_controller == address(0)) revert InvalidController();
        
        uint256 count = wrapperAddresses.length;
        for (uint256 i = 0; i < count; i++) {
            VaultWrapper(payable(wrapperAddresses[i])).setController(_controller);
        }
    }
}

