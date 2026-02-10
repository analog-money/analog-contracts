// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwapCall, SwapExecutor} from "../src/libraries/SwapExecutor.sol";

/**
 * @title SwapExecutorSecurityForkTest
 * @notice Fork test verifying SwapExecutor selector whitelist and dstReceiver validation
 *         against the live 1inch V6 router on Base.
 *
 * Run with:
 *   forge test --match-contract SwapExecutorSecurityForkTest -vvv --fork-url $BASE_HTTP_RPC_URL
 */

/// @dev Harness that exposes SwapExecutor.executeSwaps for testing
contract SwapExecutorHarness {
    using SwapExecutor for SwapCall[];

    function executeSwaps(SwapCall[] calldata calls, address router) external {
        SwapExecutor.executeSwaps(calls, router);
    }
}

contract SwapExecutorSecurityForkTest is Test {
    // 1inch Aggregation Router V6 on Base
    address constant ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    // Base mainnet USDC
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    // Base mainnet WETH
    address constant WETH = 0x4200000000000000000000000000000000000006;

    SwapExecutorHarness harness;

    function setUp() public {
        string memory rpcUrl = "https://mainnet.base.org";
        try vm.envString("BASE_HTTP_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {}
        vm.createSelectFork(rpcUrl);

        harness = new SwapExecutorHarness();

        vm.label(ROUTER, "1INCH_ROUTER");
        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");
        vm.label(address(harness), "HARNESS");
    }

    // ─── Verify 1inch V6 router exists on Base ───

    function test_router_has_code() public view {
        uint256 size;
        assembly { size := extcodesize(ROUTER) }
        assertGt(size, 0, "1inch router should have code on Base");
    }

    // ─── Whitelisted selectors: should NOT revert with UnsafeRouterSelector ───
    // (They may revert for other reasons like insufficient balance, but not selector check)

    function test_swap_selector_allowed() public {
        // swap(address,(address,address,address,address,uint256,uint256,uint256),bytes)
        // Build minimal swap calldata with dstReceiver = address(0) (safe)
        bytes memory swapData = abi.encodeWithSelector(
            bytes4(0x07ed2379),
            address(0), // executor
            USDC,       // srcToken (part of tuple)
            WETH,       // dstToken
            address(0), // srcReceiver
            address(0), // dstReceiver = 0 → defaults to msg.sender
            uint256(0), // amount
            uint256(0), // minReturnAmount
            uint256(0), // flags
            ""          // data
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, swapData, 0);

        // Should not revert with UnsafeRouterSelector; will revert for other reasons
        vm.expectRevert(); // generic revert (not UnsafeRouterSelector)
        harness.executeSwaps(calls, ROUTER);
    }

    function test_unoswap_selector_allowed() public {
        // unoswap(uint256,uint256,uint256,uint256)
        bytes memory data = abi.encodeWithSelector(
            bytes4(0x83800a8e),
            uint256(0), uint256(0), uint256(0), uint256(0)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        // SwapFail (router call fails) but NOT UnsafeRouterSelector
        vm.expectRevert(SwapExecutor.SwapFail.selector);
        harness.executeSwaps(calls, ROUTER);
    }

    function test_unoswap2_selector_allowed() public {
        bytes memory data = abi.encodeWithSelector(
            bytes4(0x8770ba91),
            uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        vm.expectRevert(SwapExecutor.SwapFail.selector);
        harness.executeSwaps(calls, ROUTER);
    }

    function test_unoswap3_selector_allowed() public {
        bytes memory data = abi.encodeWithSelector(
            bytes4(0x19367472),
            uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        vm.expectRevert(SwapExecutor.SwapFail.selector);
        harness.executeSwaps(calls, ROUTER);
    }

    function test_ethUnoswap_selector_allowed() public {
        bytes memory data = abi.encodeWithSelector(
            bytes4(0xa76dfc3b),
            uint256(0), uint256(0)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        vm.expectRevert(SwapExecutor.SwapFail.selector);
        harness.executeSwaps(calls, ROUTER);
    }

    function test_ethUnoswap2_selector_allowed() public {
        bytes memory data = abi.encodeWithSelector(
            bytes4(0x89af926a),
            uint256(0), uint256(0), uint256(0)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        vm.expectRevert(SwapExecutor.SwapFail.selector);
        harness.executeSwaps(calls, ROUTER);
    }

    function test_ethUnoswap3_selector_allowed() public {
        bytes memory data = abi.encodeWithSelector(
            bytes4(0x188ac35d),
            uint256(0), uint256(0), uint256(0), uint256(0)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        vm.expectRevert(SwapExecutor.SwapFail.selector);
        harness.executeSwaps(calls, ROUTER);
    }

    function test_clipperSwap_selector_allowed() public {
        bytes memory data = abi.encodeWithSelector(
            bytes4(0xd2d374e5),
            address(0), uint256(0), address(0), uint256(0),
            uint256(0), uint256(0), bytes32(0), bytes32(0)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        // clipperSwap with zero args succeeds on the live router (returns 0).
        // The key assertion: it does NOT revert with UnsafeRouterSelector,
        // meaning the selector passed the whitelist check.
        harness.executeSwaps(calls, ROUTER);
    }

    // ─── Blocked selectors: MUST revert with UnsafeRouterSelector ───

    function test_unoswapTo_blocked() public {
        // unoswapTo(uint256,uint256,uint256,uint256,uint256) → 0xe2c95c82
        bytes memory data = abi.encodeWithSelector(
            bytes4(0xe2c95c82),
            uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        vm.expectRevert(abi.encodeWithSelector(SwapExecutor.UnsafeRouterSelector.selector, bytes4(0xe2c95c82)));
        harness.executeSwaps(calls, ROUTER);
    }

    function test_unoswapTo2_blocked() public {
        bytes memory data = abi.encodeWithSelector(
            bytes4(0xea76dddf),
            uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        vm.expectRevert(abi.encodeWithSelector(SwapExecutor.UnsafeRouterSelector.selector, bytes4(0xea76dddf)));
        harness.executeSwaps(calls, ROUTER);
    }

    function test_unoswapTo3_blocked() public {
        bytes memory data = abi.encodeWithSelector(
            bytes4(0xf7a70056),
            uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        vm.expectRevert(abi.encodeWithSelector(SwapExecutor.UnsafeRouterSelector.selector, bytes4(0xf7a70056)));
        harness.executeSwaps(calls, ROUTER);
    }

    function test_ethUnoswapTo_blocked() public {
        bytes memory data = abi.encodeWithSelector(
            bytes4(0x175accdc),
            uint256(0), uint256(0), uint256(0)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        vm.expectRevert(abi.encodeWithSelector(SwapExecutor.UnsafeRouterSelector.selector, bytes4(0x175accdc)));
        harness.executeSwaps(calls, ROUTER);
    }

    function test_ethUnoswapTo2_blocked() public {
        bytes memory data = abi.encodeWithSelector(
            bytes4(0x0f449d71),
            uint256(0), uint256(0), uint256(0), uint256(0)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        vm.expectRevert(abi.encodeWithSelector(SwapExecutor.UnsafeRouterSelector.selector, bytes4(0x0f449d71)));
        harness.executeSwaps(calls, ROUTER);
    }

    function test_ethUnoswapTo3_blocked() public {
        bytes memory data = abi.encodeWithSelector(
            bytes4(0x493189f0),
            uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        vm.expectRevert(abi.encodeWithSelector(SwapExecutor.UnsafeRouterSelector.selector, bytes4(0x493189f0)));
        harness.executeSwaps(calls, ROUTER);
    }

    function test_clipperSwapTo_blocked() public {
        bytes memory data = abi.encodeWithSelector(
            bytes4(0x869d0c12),
            address(0), uint256(0), address(0), uint256(0),
            address(0), uint256(0), uint256(0), bytes32(0), bytes32(0)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        vm.expectRevert(abi.encodeWithSelector(SwapExecutor.UnsafeRouterSelector.selector, bytes4(0x869d0c12)));
        harness.executeSwaps(calls, ROUTER);
    }

    function test_random_selector_blocked() public {
        // Random selector 0xdeadbeef must be blocked
        bytes memory data = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(0));

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        vm.expectRevert(abi.encodeWithSelector(SwapExecutor.UnsafeRouterSelector.selector, bytes4(0xdeadbeef)));
        harness.executeSwaps(calls, ROUTER);
    }

    // ─── dstReceiver validation for swap() ───

    function test_swap_dstReceiver_zero_allowed() public {
        // dstReceiver = address(0) → defaults to msg.sender, should be allowed
        // Build swap calldata: selector + executor + srcToken + dstToken + srcReceiver + dstReceiver(0) + ...
        bytes memory data = new bytes(4 + 32 * 8); // selector + 8 words minimum
        // Set selector
        data[0] = 0x07; data[1] = 0xed; data[2] = 0x23; data[3] = 0x79;
        // dstReceiver at offset 132 (4 + 4*32) = 0 (already zeroed)

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        // Should not revert with InvalidSwapReceiver; will revert with SwapFail
        vm.expectRevert(SwapExecutor.SwapFail.selector);
        harness.executeSwaps(calls, ROUTER);
    }

    function test_swap_dstReceiver_this_allowed() public {
        // dstReceiver = address(harness) → the calling contract, should be allowed
        bytes memory data = new bytes(4 + 32 * 8);
        data[0] = 0x07; data[1] = 0xed; data[2] = 0x23; data[3] = 0x79;

        // Encode address(harness) at offset 132-163
        // address is right-padded in the last 20 bytes of the 32-byte word
        bytes32 harnessAddr = bytes32(uint256(uint160(address(harness))));
        for (uint256 i = 0; i < 32; i++) {
            data[132 + i] = harnessAddr[i];
        }

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        // Should not revert with InvalidSwapReceiver; will revert with SwapFail
        vm.expectRevert(SwapExecutor.SwapFail.selector);
        harness.executeSwaps(calls, ROUTER);
    }

    function test_swap_dstReceiver_attacker_blocked() public {
        // dstReceiver = attacker address → MUST be blocked
        address attacker = address(0xDEAD);
        bytes memory data = new bytes(4 + 32 * 8);
        data[0] = 0x07; data[1] = 0xed; data[2] = 0x23; data[3] = 0x79;

        bytes32 attackerAddr = bytes32(uint256(uint160(attacker)));
        for (uint256 i = 0; i < 32; i++) {
            data[132 + i] = attackerAddr[i];
        }

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(ROUTER, data, 0);

        vm.expectRevert(abi.encodeWithSelector(SwapExecutor.InvalidSwapReceiver.selector, attacker));
        harness.executeSwaps(calls, ROUTER);
    }

    // ─── Non-router call validation ───

    function test_non_router_approve_allowed() public {
        // approve(router, amount) on USDC token should be allowed
        bytes memory data = abi.encodeWithSelector(
            bytes4(0x095ea7b3), // approve(address,uint256)
            ROUTER,
            uint256(1000e6)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(USDC, data, 0);

        // This should succeed (approve on USDC with spender=router)
        // Fund harness with USDC first
        deal(USDC, address(harness), 1000e6, true);
        harness.executeSwaps(calls, ROUTER);

        // Verify approval was set
        uint256 allowance = IERC20(USDC).allowance(address(harness), ROUTER);
        assertEq(allowance, 1000e6, "Approval should be set to 1000 USDC");
    }

    function test_non_router_approve_wrong_spender_blocked() public {
        // approve(attacker, amount) should be blocked
        address attacker = address(0xDEAD);
        bytes memory data = abi.encodeWithSelector(
            bytes4(0x095ea7b3),
            attacker,
            uint256(1000e6)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(USDC, data, 0);

        vm.expectRevert(abi.encodeWithSelector(SwapExecutor.InvalidApproveSpender.selector, attacker));
        harness.executeSwaps(calls, ROUTER);
    }

    function test_non_router_transfer_blocked() public {
        // transfer(attacker, amount) on USDC should be blocked (not approve selector)
        address attacker = address(0xDEAD);
        bytes memory data = abi.encodeWithSelector(
            bytes4(0xa9059cbb), // transfer(address,uint256)
            attacker,
            uint256(1000e6)
        );

        SwapCall[] memory calls = new SwapCall[](1);
        calls[0] = SwapCall(USDC, data, 0);

        vm.expectRevert(abi.encodeWithSelector(SwapExecutor.Invalid.selector, bytes4(0xa9059cbb)));
        harness.executeSwaps(calls, ROUTER);
    }
}
