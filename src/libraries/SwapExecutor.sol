// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

struct SwapCall {
    address target;
    bytes data;
    uint256 value;
}

library SwapExecutor {
    error Invalid(bytes4 selector);
    error InvalidTarget(address expected, address actual);
    error InvalidApproveSpender(address spender);
    error UnsafeRouterSelector(bytes4 selector);
    error InvalidSwapReceiver(address receiver);
    error SwapFail();

    // ── 1inch Aggregation Router V6 whitelisted selectors ──
    // Only selectors where swap output defaults to msg.sender (the vault).
    // "To" variants (unoswapTo, clipperSwapTo, ethUnoswapTo, etc.) are
    // BLOCKED because they let the caller redirect output to an arbitrary
    // address, enabling the dstReceiver theft vector.
    bytes4 private constant _SWAP         = 0x07ed2379;
    bytes4 private constant _UNOSWAP      = 0x83800a8e;
    bytes4 private constant _UNOSWAP2     = 0x8770ba91;
    bytes4 private constant _UNOSWAP3     = 0x19367472;
    bytes4 private constant _ETH_UNOSWAP  = 0xa76dfc3b;
    bytes4 private constant _ETH_UNOSWAP2 = 0x89af926a;
    bytes4 private constant _ETH_UNOSWAP3 = 0x188ac35d;
    bytes4 private constant _CLIPPER_SWAP = 0xd2d374e5;

    // Offset of dstReceiver in swap() calldata:
    // 4 (selector) + 32 (executor) + 32 (srcToken) + 32 (dstToken) + 32 (srcReceiver) = 132
    uint256 private constant _DST_RECEIVER_OFFSET = 132;

    /// @notice Execute swap calls via 1inch router
    /// @dev Security layers:
    ///   1. Non-router targets: only approve(router, amount) allowed
    ///   2. Router targets: only whitelisted selectors that default output
    ///      to msg.sender. "To" variants are blocked entirely.
    ///   3. For swap(): dstReceiver in SwapDescription must be address(0)
    ///      (defaults to msg.sender) or address(this).
    /// @param calls Array of swap calls to execute
    /// @param router Address of 1inch router
    function executeSwaps(
        SwapCall[] calldata calls,
        address router
    ) internal {
        for (uint256 i; i < calls.length;) {
            if (calls[i].target == router) {
                // Router call — whitelist selector
                bytes4 sel = bytes4(calls[i].data[:4]);
                if (sel == _SWAP) {
                    // swap(address,(address,address,address,address,uint256,uint256,uint256),bytes)
                    // Validate dstReceiver (4th field of SwapDescription tuple) is safe
                    address dstReceiver = address(uint160(uint256(bytes32(
                        calls[i].data[_DST_RECEIVER_OFFSET:_DST_RECEIVER_OFFSET + 32]
                    ))));
                    if (dstReceiver != address(0) && dstReceiver != address(this)) {
                        revert InvalidSwapReceiver(dstReceiver);
                    }
                } else if (
                    sel != _UNOSWAP &&
                    sel != _UNOSWAP2 &&
                    sel != _UNOSWAP3 &&
                    sel != _ETH_UNOSWAP &&
                    sel != _ETH_UNOSWAP2 &&
                    sel != _ETH_UNOSWAP3 &&
                    sel != _CLIPPER_SWAP
                ) {
                    revert UnsafeRouterSelector(sel);
                }
            } else {
                // Non-router targets must be approve(address,uint256)
                bytes4 selector = bytes4(calls[i].data[:4]);
                if (selector != 0x095ea7b3) {
                    revert Invalid(selector);
                }
                // Validate the spender (first arg) is the router
                address spender = abi.decode(calls[i].data[4:36], (address));
                if (spender != router) {
                    revert InvalidApproveSpender(spender);
                }
            }

            (bool success,) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!success) revert SwapFail();
            unchecked { ++i; }
        }
    }
}
