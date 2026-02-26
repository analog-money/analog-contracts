// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IUniswapV3PoolSwap {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @title PoolSwapExecutor
 * @notice Library for executing swaps directly via a Uniswap V3-compatible pool
 * @dev Works with Uniswap V3 and Aerodrome Slipstream (identical swap interface).
 *      Callers must implement `uniswapV3SwapCallback` and route it to `handleCallback`.
 */
library PoolSwapExecutor {
    using SafeERC20 for IERC20;

    // Uniswap V3 sqrt price bounds — used to accept any price (no limit)
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    error NotPool();
    error InvalidSwapPool();

    /**
     * @notice Swap the full balance of `tokenIn` to `tokenOut` via the given pool.
     * @dev Uses exact-input swap with no price limit (slippage is enforced by the
     *      caller checking the resulting USDC balance against `minAmountOut`).
     *      The caller contract must implement `uniswapV3SwapCallback`.
     * @param pool    Uniswap V3-compatible pool address
     * @param tokenIn Token to sell (must be one of the pool's tokens)
     * @param amount  Amount of tokenIn to sell
     */
    function swapExactIn(address pool, address tokenIn, uint256 amount) internal {
        if (amount == 0) return;
        if (pool == address(0)) revert InvalidSwapPool();

        address t0 = IUniswapV3PoolSwap(pool).token0();
        bool zeroForOne = tokenIn == t0;

        IUniswapV3PoolSwap(pool).swap(
            address(this),
            zeroForOne,
            int256(amount),
            zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            "" // empty data — callback only needs to identify the pool via msg.sender
        );
    }

    /**
     * @notice Handle the `uniswapV3SwapCallback` from the pool.
     * @dev Must be called from the vault's `uniswapV3SwapCallback`.
     *      Validates that `msg.sender == pool` and pays the owed amount.
     * @param pool         Expected pool address (used for auth)
     * @param amount0Delta Signed delta for token0 (positive = vault owes pool)
     * @param amount1Delta Signed delta for token1 (positive = vault owes pool)
     */
    function handleCallback(
        address pool,
        int256 amount0Delta,
        int256 amount1Delta
    ) internal {
        if (msg.sender != pool) revert NotPool();
        address t0 = IUniswapV3PoolSwap(pool).token0();
        address t1 = IUniswapV3PoolSwap(pool).token1();
        if (amount0Delta > 0) IERC20(t0).safeTransfer(pool, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(t1).safeTransfer(pool, uint256(amount1Delta));
    }
}
