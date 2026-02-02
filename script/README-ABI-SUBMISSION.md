# ABI Submission to Basescan

This directory contains scripts for submitting contract ABIs to Basescan after deployment.

## Scripts

### `submit-abi-to-basescan.ts`

Submits a contract's ABI to Basescan using their API. This is useful for contracts that are already verified but need their ABI updated for better UI on Basescan.

**Usage:**

```bash
# With command line arguments (reads ETHERSCAN_API_KEY from .env)
npx tsx script/submit-abi-to-basescan.ts \
  --contract AnalogVault \
  --address 0x638c3E850E8B1DA16C44f8A04D89FD922200Ff1d

# With environment variables
ETHERSCAN_API_KEY=your_key \
CONTRACT_NAME=AnalogVault \
CONTRACT_ADDRESS=0x638c3E850E8B1DA16C44f8A04D89FD922200Ff1d \
npx tsx script/submit-abi-to-basescan.ts
```

**Requirements:**

- `ETHERSCAN_API_KEY`: Your Basescan/Etherscan API key (can be set in `.env` file)
- Contract name: The name of the contract (must match Foundry artifact name)
- Contract address: The deployed contract address

**How it works:**

1. Loads environment variables from `.env` file (if present)
2. Loads the ABI from Foundry artifacts (`out/{ContractName}.sol/{ContractName}.json`)
3. Submits the ABI to Basescan using Etherscan v2 API (POST with JSON body)
4. Verifies the submission was successful

### `deploy-and-submit-abi.sh`

Combined script that deploys the contract and automatically submits the ABI.

**Usage:**

```bash
DEPLOYER_PRIVATE_KEY=0x... \
ETHERSCAN_API_KEY=your_key \
FACTORY_ADDRESS=0x... \
./script/deploy-and-submit-abi.sh
```

**What it does:**

1. Deploys the AnalogVault implementation using Forge
2. Extracts the deployed contract address
3. Automatically submits the ABI to Basescan

## Getting a Basescan API Key

1. Go to https://basescan.org/myapikey
2. Sign up or log in
3. Create a new API key
4. Add it to your `.env` file:
   ```
   ETHERSCAN_API_KEY=your_api_key_here
   ```
   Or set it as an environment variable

## Notes

- The contract must be verified on Basescan before submitting the ABI
- The ABI is read from Foundry compilation artifacts
- The script validates the contract address (checksums it)
- If submission fails, the script will exit with an error code

## Example Output

```
========================================
Submitting ABI to Basescan
========================================
Contract Address: 0x638c3E850E8B1DA16C44f8A04D89FD922200Ff1d
API Endpoint: https://api.basescan.org/api

Submitting ABI...
✅ ABI submitted successfully!

View contract on Basescan:
   https://basescan.org/address/0x638c3E850E8B1DA16C44f8A04D89FD922200Ff1d#code

========================================
Done!
========================================
```
