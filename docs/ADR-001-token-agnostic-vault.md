# ADR-001: Token-Agnostic Vault with 2-Step Deposit/Withdraw

**Status:** Accepted
**Date:** 2026-03-05
**Authors:** Fabo, Claude

## Context

The original AnalogVault design had several limitations:

1. **Token-specific state**: The vault stored `pool`, `priceFeed` (Chainlink), and `WETH` as immutables/state. Each new pool pair (ETH/USDC, BTC/USDC, etc.) required a different vault implementation or constructor configuration.

2. **Multi-step operations with external swap data**: Deposit required 3+ steps — `deposit()` → `swapAndDeploy(swapCalls, amt0, amt1)` → `executeDeploy()`. Withdraw required `withdraw()` → `executeWithdrawal()` → `executeSwap(swapCalls, minOut)`. Each step that took `SwapCall[]` required the backend to fetch 1inch API quotes and encode calldata, creating fragile dependencies on external pricing services.

3. **Large attack surface**: The `SwapCall[]` parameter passed to vault functions allowed arbitrary external calls to the 1inch router. While whitelisted to safe selectors, this added ~200 bytes of validation logic and introduced dstReceiver theft vectors that needed careful guarding.

4. **Contract size pressure**: With pool storage, Chainlink oracle, ERC20 token, WETH wrapping logic, and SwapExecutor, the vault was near the 24,576 byte EVM limit.

## Decision

Redesign the vault as **token-agnostic** with a **2-step deposit/withdraw** API that handles swaps internally via the pool.

### Architecture

```
User                    Controller              AnalogVault              Strategy (IStrategyConcLiq)
 |                         |                        |                         |
 |-- deposit(usdcAmt) ---->|                        |                         |
 |                         |-- depositExecute() --->|                         |
 |                         |                        |-- transfer tokens ----->|
 |                         |                        |-- strategy.deposit() -->|
 |                         |                        |                         |
 |-- withdraw(usdcAmt) --->|                        |                         |
 |                         |-- withdrawExecute(min)->|                        |
 |                         |                        |-- strategy.withdraw() ->|
 |                         |                        |-- _swapAllToUSDC() ---->| (via pool callback)
 |                         |                        |-- transfer USDC ------->|
```

### Key Design Choices

**1. Token pair comes from strategy, not vault**

The vault only knows about USDC (immutable). Token0, token1, pool address, and price all come from `IStrategyConcLiq`:

```solidity
constructor(address _usdc) BaseVault(_usdc) {}

function initialize(address _owner, address _controller, address _strategy) external initializer {
    BaseVault.initialize(_owner, _controller);
    strategy = IStrategyConcLiq(_strategy);
    factory = msg.sender;
}
```

One vault implementation works for ETH/USDC, BTC/USDC, or any X/USDC pool. The factory deploys the same implementation with different strategy addresses.

**2. Internal pool swaps via callback**

Instead of accepting external `SwapCall[]` arrays, the vault swaps non-USDC tokens directly through the underlying pool using `uniswapV3SwapCallback`:

```solidity
function _swapAllToUSDC() internal override {
    address otherToken = token0 == USDC ? strategy.lpToken1() : token0;
    uint256 balance = IERC20(otherToken).balanceOf(address(this));
    PoolSwapExecutor.swapExactIn(strategy.pool(), otherToken, balance);
}

function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
    PoolSwapExecutor.handleCallback(strategy.pool(), amount0Delta, amount1Delta);
}
```

This eliminates the need for 1inch API quotes, SwapExecutor validation, and multi-step swap flows.

**3. 2-step operations (down from 3-5 steps)**

| Operation | Old Flow | New Flow |
|-----------|----------|----------|
| Deposit | `deposit()` → `swapAndDeploy(swapCalls, a0, a1)` → `executeDeploy()` | `deposit(usdcAmt)` → `depositExecute()` |
| Withdraw | `withdraw()` → `executeWithdrawal()` → `executeSwap(swapCalls, min)` | `withdraw(usdcAmt)` → `withdrawExecute(minOut)` |

The controller no longer needs to provide swap calldata. `depositExecute()` transfers idle USDC + other tokens to the strategy and calls `strategy.deposit()`. `withdrawExecute()` withdraws from the strategy, swaps non-USDC tokens via the pool, and sends all USDC to the user.

**4. Price from strategy, not Chainlink**

`strategy.price()` returns the pool spot price of token0 in token1, scaled by 1e36. This is used for vault equity calculation and proportional withdrawal:

```solidity
function getVaultEquity() public view override returns (uint256) {
    (uint256 amt0, uint256 amt1) = _balances();
    uint256 price = strategy.price();
    if (strategy.lpToken0() == USDC) {
        return amt0 + (amt1 * 1e36) / price;
    } else {
        return amt1 + (amt0 * price) / 1e36;
    }
}
```

**5. No ERC20 — single-owner vault**

The vault uses internal `uint256 totalShares` accounting instead of ERC20. Shares are not tradable. Each vault has exactly one owner (enforced by OwnableUpgradeable). This simplifies the contract and avoids ERC20 approval/transfer attack surface.

**6. UUPS upgradeable via factory**

The vault is UUPS upgradeable. `upgradeToLatest()` checks `factory.latestImplementation()` and also attempts to upgrade the underlying strategy via `IUUPS(strategy).upgradeToLatest()`.

## Storage Layout

```
BaseVault (abstract):
  USDC              immutable address
  controller        address
  maxTotalAssets     uint256
  minDeposit         uint256
  totalShares        uint256
  _reserved[5]       uint256[5]    // reserved for hedge-layer extensions
  pending            PendingOps    // {depositAmount, withdrawAmount, withdrawRecipient, flags}
  emergencyExitTriggered  bool

AnalogVault (concrete):
  strategy           IStrategyConcLiq
  factory            address
  pendingConfig      PendingConfig  // {changeType, value, isPending}
```

## Consequences

### Positive

- **Single implementation** for all pool pairs — deploy same bytecode, different strategy
- **No external swap dependencies** — swaps happen through the pool directly
- **Smaller contract** — removed Chainlink, ERC20, WETH, SwapExecutor (~1,500 bytes saved)
- **Simpler backend** — controller calls `depositExecute()`/`withdrawExecute(min)` with no swap calldata
- **Reduced attack surface** — no arbitrary external calls, no SwapCall validation needed

### Negative

- **Pool-only swaps** — swaps use the underlying pool instead of 1inch aggregation, so may get worse execution on large trades. For our vault sizes ($100-$50K per user), pool liquidity is more than sufficient.
- **strategy.price() dependency** — vault equity depends on pool spot price via the strategy. A manipulated pool price could affect equity calculation. Mitigated by `isCalm()` check (TWAP deviation guard) before rebalancing.
- **USDC-only base currency** — the vault assumes one side of every pool is USDC. Non-USDC pairs would need a different vault type.

### Migration

- Existing vaults on the old implementation can upgrade via `upgradeToLatest()` once the factory's `latestImplementation` is updated
- The backend deposit/withdraw handlers need updating to use the 2-step API instead of multi-step SwapCall flows
- No storage layout changes to BaseVault slots — the `_reserved[5]` array preserves compatibility with hedge-layer extensions

## Alternatives Considered

1. **Keep SwapCall but simplify steps**: Still requires 1inch API dependency and SwapExecutor validation. Rejected for complexity.

2. **Use a DEX aggregator on-chain (e.g., Paraswap)**: Still external dependency, still needs calldata from off-chain. Doesn't solve the core problem.

3. **Two separate contracts (vault + router)**: The router would handle swaps and call the vault. Adds gas overhead for cross-contract calls and approval management. Rejected for unnecessary complexity at our scale.

## References

- `src/AnalogVault.sol` — concrete vault implementation
- `src/BaseVault.sol` — abstract base with deposit/withdraw logic
- `src/libraries/PoolSwapExecutor.sol` — direct pool swap library
- `src/AnalogVaultFactory.sol` — factory deploying vault proxies
- `src/interfaces/IHedgedVault.sol` — interface definition
