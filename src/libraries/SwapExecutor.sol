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
    error SwapFail();

    /// @notice Execute swap calls via 1inch router
    /// @dev For non-router targets, only approve(address,uint256) is allowed
    ///      and the spender must be the router itself (prevents approving tokens
    ///      to arbitrary addresses if the controller key is compromised).
    /// @param calls Array of swap calls to execute
    /// @param router Address of 1inch router
    function executeSwaps(
        SwapCall[] calldata calls,
        address router
    ) internal {
        for (uint256 i; i < calls.length;) {
            if (calls[i].target == router) {
                // Direct router calls are valid (swaps)
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
