## AnalogVault Accounting and Queue Management

### Overview
AnalogVault is a per-user vault that accepts USDC deposits, optionally swaps to pool tokens, and deposits into a concentrated-liquidity strategy. Withdrawals remove liquidity, withdraw the requested share of pool tokens, optionally swap them back to USDC, and transfer the USDC delta to the owner. Market volatility, calm-gating, and swap failures can create periods where deposits and withdrawals are both “waiting to be swapped.” This document proposes a simple, robust accounting model and an off-chain queue management policy to coordinate operations without changing on-chain contracts.

Goals:
- Prioritize safety and determinism over throughput.
- Avoid unnecessary swaps and price churn.
- Keep user funds accounted for at all times across USDC, pool tokens, and strategy balances.
- Minimize new contract surface area; solve with an off-chain controller/queue.

Non-goals:
- Cross-vault netting or matching. Each AnalogVault is per-user and isolated.
- Complex batch auctions or solver-style netting.


### Terms and Components
- Vault (AnalogVault): Per-user wrapper around the strategy.
- Controller: Off-chain service authorized by the vault to execute swaps/deposits when calm; also executes queued config changes.
- Strategy: Concentrated-liquidity strategy where balances() reflect token balances associated with the vault.
- Calm: Strategy pool condition that must be true for deposit/re-deposit/config execution.
- USDC Buffer: USDC held by the vault contract awaiting swaps/deposit.
- Pool Token Buffer: Token0/token1 held by the vault contract (not in strategy).
- Strategy Balances: Token amounts in the strategy reported by `balances()`.
- Operations:
  - deposit(amount): Owner deposits USDC into the vault.
  - executeSwapsAndDeposit(calls, amount0, amount1): Controller swaps and deposits to strategy.
  - depositToVault(amount0, amount1): Controller deposits already-held pool tokens.
  - withdraw(a0, a1, minA0, minA1, swapCalls): Owner withdraws share, swaps back to USDC, sends USDC delta.
  - cancelDeposit(swapCalls?): Owner cancels pending deposit and receives USDC.
  - queue/execute config change: Already implemented calm-gated flow.


### Accounting Model
Track funds in three buckets at all times:
- USDC Buffer: `IERC20(USDC).balanceOf(vault)`
- Pool Token Buffer: `IERC20(token0).balanceOf(vault)`, `IERC20(token1).balanceOf(vault)`
- Strategy Balances: `vault.balances()` returning `(bal0, bal1)`

Invariants:
- Conservation: Total assets of the vault owner equal the sum of the three buckets valued consistently. The contract already enforces transfer semantics; off-chain views must not “double count.”
- Withdraw Delta Rule: Withdraw transfers only the USDC delta produced by swap(s) of the withdrawn token deltas.
- Calm Gating: Any operation that modifies the strategy position (deposit, re-deposit, execute config change) must pass `isCalm()`.

Implications when both deposits and withdrawals are “waiting to be swapped”:
- Processing order directly affects how much swapping occurs. Prefer processing withdrawals first to free USDC, then deposit, minimizing back-and-forth conversion.
- If swaps fail during withdrawal, pool tokens remain in the vault; the Withdraw Delta Rule ensures no USDC is incorrectly transferred.


### Queue Management Concept
Off-chain, maintain a per-vault operation queue. Only one in-flight operation per vault at a time (mutex). The queue is persisted (e.g. DB table) with idempotency keys.

Proposed minimal schema (conceptual):
- id (uuid)
- vaultAddress (address)
- chainId (int)
- type (enum): withdraw_request, deposit_deploy, cancel_deposit, exec_config_change
- payload (json): parameters needed (e.g., swap calldata hints, target amounts)
- priority (int): higher runs first (see below)
- status (enum): pending, running, succeeded, failed, cancelled
- createdAt, updatedAt (timestamps)
- attemptCount (int), lastError (string)
- notBefore (timestamp) — backoff scheduling

Priority order (highest to lowest):
1) withdraw_request
2) cancel_deposit
3) exec_config_change
4) deposit_deploy

Rationale: prioritize user exits (withdraw), then ensure users can reclaim funds from pending deposits, then maintenance/config, then growth (deposits).

Gating and readiness checks for each op type:
- withdraw_request:
  - No calm requirement (contract handles beforeAction and slippage checks).
  - Execute immediately when queued (often direct user tx; off-chain may just observe rather than execute).
- cancel_deposit:
  - No calm requirement. If optional swapCalls are included, execute swaps first, then transfer USDC to owner.
  - Ready whenever the user requests it and there are funds to return.
- exec_config_change:
  - Requires calm. If not calm, requeue with backoff (e.g., 30s → 60s → 120s).
- deposit_deploy:
  - Requires calm AND funds in USDC Buffer or Pool Token Buffer.
  - If not calm or no funds, requeue with backoff.

Concurrency:
- Per-vault mutex: do not run two operations concurrently for the same vault.
- Global concurrency limited by worker pool size; ensure fairness across vaults.

Idempotency:
- Assign an idempotency key per logical operation (e.g., “deploy-funds:tx-{hash}:vault-{addr}”). If retried, regenerate the same calldata if possible or ensure the on-chain call is safe if replayed.


### Execution Flows

1) Deposit Path (happy path)
- Owner calls `deposit(amountUSDC)`. Funds sit in USDC Buffer.
- Queue creates/updates a single `deposit_deploy` op for this vault (coalesce multiple deposits).
- Worker checks calm; if true, generates 1inch swap calls (USDC → token0/token1), then calls `executeSwapsAndDeposit(swapCalls, 0, 0)` so the vault uses all available balances.
- On success, status = succeeded.

2) Withdraw Path (happy path)
- Owner calls `withdraw(a0, a1, minA0, minA1, swapCalls)` directly. This is typically not queued off-chain; the user submits the transaction.
- Contract removes liquidity (beforeAction), withdraws share, approves pool tokens, executes user-provided swaps, computes USDC delta, transfers USDC to owner, and re-deposits any remaining tokens if calm.
- Off-chain queue observes events to update any outstanding `deposit_deploy` op planning (e.g., more USDC now available post-withdraw that could be used in a later deposit action).

3) Both Deposit and Withdraw Pending
- Policy: process withdrawal first to honor exits and reduce unnecessary churn.
- After withdrawal, the USDC Buffer may increase due to swaps; any remaining pool tokens (if swaps skipped/failed) will be re-deposited only if calm when the contract attempts it. If not re-deposited, they remain in the Pool Token Buffer.
- Then attempt `deposit_deploy` if calm, using the fresh USDC Buffer (and any residual pool tokens if you choose a depositToVault path).

4) Swap Failures
- Withdraw: If swaps fail, the transaction reverts by design (SwapFailed). No partial USDC is transferred. Tokens remain in known buckets.
- Deposit: If executing swaps fails, the whole tx reverts; funds remain in USDC Buffer. The queue worker marks failed, applies backoff, and retries later.
- No silent loss: In all failure modes, funds persist in one of the three buckets and can be retried later.

5) Cancel Deposit
- Owner calls `cancelDeposit(swapCalls?)`. If swapCalls are provided, the vault swaps pool tokens into USDC and transfers all USDC to owner. If not provided, it just returns the existing USDC Buffer. Off-chain should mark any `deposit_deploy` operations as cancelled.

6) Config Changes (already implemented on-chain)
- Owner queues the change. Controller executes when calm via `executeConfigChange()`.
- Queue treats this similar to `deposit_deploy` with calm gating.


### Minimizing Churn and Unnecessary Swaps
- Always process `withdraw_request` before `deposit_deploy` for the same vault.
- Coalesce multiple deposits into a single `deposit_deploy` op — aggregate USDC Buffer and swap once.
- After `withdraw_request`, immediately recalculate whether a `deposit_deploy` is still desired; if user intent changed (e.g., they plan to exit), either cancel or defer deposit.
- Avoid “flip-flop”: if a vault alternates quickly between deposit and withdraw requests, enforce a short grace window (e.g., 30–60s) before running `deposit_deploy` to allow the user’s sequence to stabilize.


### Worker Pseudocode
```typescript
// Per-vault loop with a global scheduler
while (true) {
  const op = fetchNextReadyOperationByPriority();
  if (!op) { sleep(1000); continue; }

  withVaultMutex(op.vaultAddress, async () => {
    try {
      switch (op.type) {
        case 'withdraw_request': {
          // Usually user-submitted; if managed by worker, just submit tx
          await submitWithdrawTx(op.payload);
          break;
        }
        case 'cancel_deposit': {
          await submitCancelDepositTx(op.payload);
          break;
        }
        case 'exec_config_change': {
          const calm = await readIsCalm(op.vaultAddress);
          if (!calm) throw new RetryableError('Not calm');
          await submitExecuteConfigChangeTx(op.vaultAddress);
          break;
        }
        case 'deposit_deploy': {
          const calm = await readIsCalm(op.vaultAddress);
          const { usdcBal, token0Bal, token1Bal } = await readVaultBuffers(op.vaultAddress);
          if (!calm || (usdcBal === 0n && token0Bal === 0n && token1Bal === 0n)) {
            throw new RetryableError('Not calm or no funds');
          }
          const swapCalls = await buildOneInchSwaps(usdcBal, token0Bal, token1Bal);
          await submitExecuteSwapsAndDepositTx(op.vaultAddress, swapCalls);
          break;
        }
      }
      markSucceeded(op.id);
    } catch (e) {
      if (isRetryable(e)) {
        markFailedWithBackoff(op.id, e);
      } else {
        markFailed(op.id, e);
      }
    }
  });
}
```


### Observability and Operations
- Metrics per vault: queued ops, in-flight op, success/failure rate, average wait time.
- Alerts: operation stuck > N minutes; repeated swap failures; calm unavailable for prolonged periods.
- Traces: include vaultAddress, opId, txHash, attemptCount for end-to-end correlation.


### Security and Access Control
- Respect contract roles:
  - Only vault owner can deposit, withdraw, cancel deposit, queue config changes.
  - Only controller can execute calm-gated operations and config changes.
- Never attempt to manipulate user swap calldata for withdrawals; honor user-provided routes and slippages.
- Paymaster/policy enforcement: ensure only allowed contract calls are sponsored.


### Data Consistency and Idempotency
- Persist operation records before submitting transactions.
- Use unique idempotency keys per logical op. On worker restart, reconcile pending/running operations by checking latest on-chain state (balances, buffers, events).
- Treat on-chain state as source of truth for funds; the queue is an execution plan, not accounting.


### Edge Cases
- Not calm for extended periods: deposit_deploy and exec_config_change remain queued with exponential backoff; user can cancel or withdraw at any time.
- Reorgs or rpc flakiness: verify receipts; if unknown, check state and retry with the same idempotency key.
- Partial user intent changes: if a user deposits and shortly after withdraws, prefer the withdrawal; leave deposit_deploy pending until a grace window elapses or user cancels.
- Swap API outage: pause new swap generation; keep operations pending and resume when healthy.


### Why No Contract Changes
- The existing contract already exposes all necessary primitives:
  - USDC deposit buffer
  - Controller-executed swaps + deposit
  - Owner-driven withdrawal with swaps and safety checks
  - Calm-gated config execution
- A simple off-chain queue with the policy above achieves safety and good UX without on-chain complexity.


### Minimal Integration Points
- Server (apps/server2):
  - Create/update a `deposit_deploy` op when vault USDC balance increases (user deposit event) or when pool tokens are held outside the strategy.
  - Observe withdrawal events to adjust queued deposit intent (e.g., short grace window before redeploying).
  - Run a per-vault worker pool enforcing the priority and gating rules above.
  - Surface operation status via UI.


### Summary
- Track funds across USDC Buffer, Pool Token Buffer, and Strategy Balances.
- Serialize operations per vault with a simple, persistent queue.
- Prioritize withdrawals, then cancel deposit, then config, then deposit deploy.
- Calm-gate only where required; requeue with backoff when not calm.
- Coalesce deposits; avoid churn by processing withdrawals first and applying a short grace window before redeploying.
- Rely on existing contract capabilities; keep the solution off-chain and minimal.







