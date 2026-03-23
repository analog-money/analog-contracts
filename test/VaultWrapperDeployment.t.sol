// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {VaultWrapper} from "../src/VaultWrapper.sol";
import {VaultWrapperFactory} from "../src/VaultWrapperFactory.sol";

/**
 * @title VaultWrapperDeployment Test
 * @notice Fork test for VaultWrapperFactory and VaultWrapper deployment
 * 
 * To run this test:
 *   forge test --match-contract VaultWrapperDeploymentTest -vvv --fork-url $BASE_HTTP_RPC_URL
 */
contract VaultWrapperDeploymentTest is Test {
    // Base Mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    
    // Test addresses
    address constant CONTROLLER = address(0x1111111111111111111111111111111111111111);
    address constant USER1 = address(0x2222222222222222222222222222222222222222);
    address constant USER2 = address(0x3333333333333333333333333333333333333333);
    
    VaultWrapperFactory factory;
    
    function setUp() public {
        // Fork Base mainnet
        string memory rpcUrl = "https://mainnet.base.org";
        try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {}
        vm.createSelectFork(rpcUrl);
        
        // Label addresses
        vm.label(USDC, "USDC");
        vm.label(CONTROLLER, "CONTROLLER");
        vm.label(USER1, "USER1");
        vm.label(USER2, "USER2");
        
        // Deploy factory
        factory = new VaultWrapperFactory(USDC, CONTROLLER);
        vm.label(address(factory), "FACTORY");
    }
    
    function test_factory_deployment() public view {
        // Verify factory state
        assertEq(factory.usdc(), USDC, "USDC address should be set");
        assertEq(factory.controller(), CONTROLLER, "Controller should be set");
        assertEq(factory.getWrapperCount(), 0, "Initial wrapper count should be 0");
    }
    
    function test_create_wrapper_for_user() public {
        // Create wrapper for USER1
        address wrapperAddr = factory.createWrapper(USER1);
        
        // Verify wrapper was created
        assertTrue(wrapperAddr != address(0), "Wrapper should be created");
        assertEq(factory.getWrapper(USER1), wrapperAddr, "Factory should track wrapper");
        assertEq(factory.getWrapperCount(), 1, "Wrapper count should be 1");
        
        // Verify wrapper state
        VaultWrapper wrapper = VaultWrapper(payable(wrapperAddr));
        assertEq(wrapper.owner(), USER1, "Wrapper owner should be USER1");
        assertEq(wrapper.factory(), address(factory), "Wrapper factory should be set");
        assertEq(wrapper.usdc(), USDC, "Wrapper USDC should be set");
        assertEq(wrapper.controller(), CONTROLLER, "Wrapper controller should be set");
        
        console.log("Wrapper created at:", wrapperAddr);
    }
    
    function test_create_multiple_wrappers() public {
        // Create wrappers for two users
        address wrapper1 = factory.createWrapper(USER1);
        address wrapper2 = factory.createWrapper(USER2);
        
        // Verify different addresses
        assertTrue(wrapper1 != wrapper2, "Wrappers should have different addresses");
        
        // Verify both tracked
        assertEq(factory.getWrapper(USER1), wrapper1, "USER1 wrapper should be tracked");
        assertEq(factory.getWrapper(USER2), wrapper2, "USER2 wrapper should be tracked");
        assertEq(factory.getWrapperCount(), 2, "Wrapper count should be 2");
        
        // Verify getAllWrappers
        address[] memory allWrappers = factory.getAllWrappers();
        assertEq(allWrappers.length, 2, "getAllWrappers should return 2 wrappers");
        assertEq(allWrappers[0], wrapper1, "First wrapper should be USER1's");
        assertEq(allWrappers[1], wrapper2, "Second wrapper should be USER2's");
        
        console.log("Wrapper 1 created at:", wrapper1);
        console.log("Wrapper 2 created at:", wrapper2);
    }
    
    function test_cannot_create_duplicate_wrapper() public {
        // Create wrapper for USER1
        factory.createWrapper(USER1);
        
        // Try to create another wrapper for USER1
        vm.expectRevert(VaultWrapperFactory.WrapperAlreadyExists.selector);
        factory.createWrapper(USER1);
    }
    
    function test_cannot_create_wrapper_for_zero_address() public {
        vm.expectRevert(VaultWrapperFactory.InvalidUser.selector);
        factory.createWrapper(address(0));
    }
    
    function test_predict_wrapper_address() public {
        // Predict address before deployment
        address predicted = factory.predictWrapperAddress(USER1);
        
        // Deploy wrapper
        address actual = factory.createWrapper(USER1);
        
        // Verify prediction matches actual
        assertEq(predicted, actual, "Predicted address should match actual");
        
        console.log("Predicted address:", predicted);
        console.log("Actual address:", actual);
    }
    
    function test_update_controller() public {
        address newController = address(0x4444444444444444444444444444444444444444);
        
        // Update controller
        factory.setController(newController);
        
        // Verify updated
        assertEq(factory.controller(), newController, "Controller should be updated");
    }
    
    function test_update_wrapper_controller() public {
        // Create wrapper
        address wrapperAddr = factory.createWrapper(USER1);
        VaultWrapper wrapper = VaultWrapper(payable(wrapperAddr));
        
        // Verify initial controller
        assertEq(wrapper.controller(), CONTROLLER, "Initial controller should be set");
        
        // Update wrapper controller
        address newController = address(0x4444444444444444444444444444444444444444);
        factory.updateWrapperController(wrapperAddr, newController);
        
        // Verify updated
        assertEq(wrapper.controller(), newController, "Wrapper controller should be updated");
    }
    
    function test_batch_update_wrapper_controller() public {
        // Create multiple wrappers
        address wrapper1 = factory.createWrapper(USER1);
        address wrapper2 = factory.createWrapper(USER2);
        
        // Prepare batch update
        address[] memory wrappers = new address[](2);
        wrappers[0] = wrapper1;
        wrappers[1] = wrapper2;
        
        address newController = address(0x4444444444444444444444444444444444444444);
        
        // Batch update
        factory.batchUpdateWrapperController(wrappers, newController);
        
        // Verify both updated
        assertEq(
            VaultWrapper(payable(wrapper1)).controller(),
            newController,
            "Wrapper 1 controller should be updated"
        );
        assertEq(
            VaultWrapper(payable(wrapper2)).controller(),
            newController,
            "Wrapper 2 controller should be updated"
        );
    }
    
    function test_only_owner_can_update_controller() public {
        // Try to update controller as non-owner
        address newController = address(0x4444444444444444444444444444444444444444);
        
        vm.prank(USER1);
        vm.expectRevert();
        factory.setController(newController);
    }
    
    function test_cannot_set_zero_controller() public {
        vm.expectRevert(VaultWrapperFactory.InvalidController.selector);
        factory.setController(address(0));
    }
}







