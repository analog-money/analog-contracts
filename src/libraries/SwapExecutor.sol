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
    error SwapFail();

    /// @notice Execute swap calls via 1inch router
    /// @param calls Array of swap calls to execute
    /// @param router Address of 1inch router
    function executeSwaps(
        SwapCall[] calldata calls,
        address router
    ) internal {
        for (uint256 i; i < calls.length;) {
            // Allow calls to router OR approve calls to any token
            if (calls[i].target == router) {
                // All calls to router are valid
            } else {
                // Calls to other targets must be approve(address,uint256)
                bytes4 selector = bytes4(calls[i].data[:4]);
                if (selector != 0x095ea7b3) {
                     // Debug: if target detection failed but it SHOULD have been router?
                     // No, if we are here, target != router.
                     revert Invalid(selector);
                }
            }
            
            (bool success,) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!success) revert SwapFail();
            unchecked { ++i; }
        }
    }
}
