# Analog Protocol Contracts V2

This repository contains the core smart contracts for the Analog Protocol V2, focusing on hedged liquidity provisioning strategies. It utilizes [Foundry](https://getfoundry.sh/) for development, testing, and deployment.

## Overview

The system is designed to provide automated, hedged yield strategies on top of concentrated liquidity AMMs (like Uniswap V3).

### Key Components

*   **Vaults (`src/AnalogVault.sol`)**: The main entry point for users. Handles deposits (USDC), withdrawals, and coordinates with the strategy and controller.
*   **Factories (`src/*Factory.sol`)**: managing the deployment of new vaults and strategies.
*   **Strategies**: Implementations for specific yield generating strategies (e.g., `StrategyPassiveManagerUniswap`).
*   **External Integrations**:
    *   **Beefy**: Utilizes Beefy Finance infrastructure for some vault mechanics.
    *   **Avantis**: Used for hedging mechanisms (referenced in dependencies).

### Vault Mechanics

The `AnalogVault` employs a **two-step execution pattern** for major operations (deposits, withdrawals, swaps) to ensure safety and proper state management:

1.  **Registration**: A user or authorized party registers an intent (e.g., `deposit`, `withdraw`). This stores the request in a `PendingOps` struct.
2.  **Execution**: The controller or owner executes the pending operation (e.g., `swapAndDeploy`, `executeWithdrawal`).

This separation allows for:
*   Off-chain calculation of optimal swap paths.
*   Batching of operations.
*   Safety checks (e.g., ensuring strategy is "calm" before deploying capital).

## Prerequisites

*   [Foundry](https://book.getfoundry.sh/getting-started/installation): Ensure you have `forge`, `cast`, `anvil`, and `chisel` installed.

## Installation

1.  Clone the repository (if you haven't already).
2.  Install dependencies:

```bash
forge install
```

*Note: This project relies on several git submodules (e.g., `beefy-zk`, `avantis-contracts`). Ensure they are initialized.*

## Usage

### Build

Compile the contracts:

```bash
forge build
```

### Test

Run the full test suite:

```bash
forge test
```

Run a specific test:

```bash
forge test --match-path test/AnalogVaultFork.t.sol
```

### Deployment

Deployment scripts are located in the `script/` directory.

To deploy the Vault Factory:

```bash
forge script script/DeployAnalogVaultFactory.s.sol:DeployAnalogVaultFactory --rpc-url <YOUR_RPC_URL> --private-key <YOUR_PRIVATE_KEY> --broadcast
```

*(Adjust the script name and parameters as needed for your specific deployment target)*

## Directory Structure

*   `src/`: Smart contract source code.
*   `test/`: Foundry tests (unit and fork tests).
*   `script/`: Deployment and interaction scripts.
*   `lib/`: Installed dependencies.

## License

SPDX-License-Identifier: MIT
