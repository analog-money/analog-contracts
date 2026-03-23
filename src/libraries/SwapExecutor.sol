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
    error Invalid();
    error SwapFail();

    /// @notice Execute swap calls via 1inch router
    /// @param calls Array of swap calls to execute
    /// @param router Address of 1inch router
    function executeSwaps(
        SwapCall[] calldata calls,
        address router
    ) internal {
        for (uint256 i; i < calls.length;) {
            if (calls[i].target != router) revert Invalid();
            (bool success,) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!success) revert SwapFail();
            unchecked { ++i; }
        }
    }
}
