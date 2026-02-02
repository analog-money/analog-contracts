#!/usr/bin/env tsx
/**
 * @title Submit ABI to Basescan
 * @notice Script to submit contract ABI to Basescan for verified contracts
 *
 * This script reads the ABI from Foundry artifacts and submits it to Basescan
 * using Etherscan v2 API. This is useful for contracts that are already verified
 * but need their ABI updated.
 *
 * Usage:
 *   npx tsx script/submit-abi-to-basescan.ts \
 *     --contract AnalogVault \
 *     --address 0x638c3E850E8B1DA16C44f8A04D89FD922200Ff1d
 *
 * Or with environment variables:
 *   CONTRACT_NAME=AnalogVault \
 *   CONTRACT_ADDRESS=0x638c3E850E8B1DA16C44f8A04D89FD922200Ff1d \
 *   npx tsx script/submit-abi-to-basescan.ts
 *
 * The script reads ETHERSCAN_API_KEY from .env file or environment variables.
 */

import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { getAddress } from "ethers";

// Load .env file if it exists
function loadEnvFile() {
  const envPath = join(process.cwd(), ".env");
  if (existsSync(envPath)) {
    const envContent = readFileSync(envPath, "utf-8");
    const lines = envContent.split("\n");
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed && !trimmed.startsWith("#")) {
        const [key, ...valueParts] = trimmed.split("=");
        if (key && valueParts.length > 0) {
          const value = valueParts
            .join("=")
            .trim()
            .replace(/^["']|["']$/g, "");
          if (!process.env[key.trim()]) {
            process.env[key.trim()] = value;
          }
        }
      }
    }
  }
}

interface BasescanApiResponse {
  status: string;
  message: string;
  result?: string;
}

async function submitABIToBasescan(
  contractAddress: string,
  abi: any[],
  apiKey: string
): Promise<void> {
  // Etherscan v2 API endpoint for Basescan
  // V2 API uses unified endpoint: https://api.etherscan.io/v2/api
  // Note: Base (chainid 8453) requires a paid Etherscan API plan
  const apiUrl = "https://api.etherscan.io/v2/api";
  const address = getAddress(contractAddress);
  const chainId = 8453; // Base mainnet chain ID

  console.log("========================================");
  console.log("Submitting ABI to Basescan (Etherscan v2 API)");
  console.log("========================================");
  console.log("Contract Address:", address);
  console.log("API Endpoint:", apiUrl);
  console.log("Chain ID:", chainId);
  console.log("API Method: POST (v2 format)");
  console.log("");
  console.log("Using Etherscan v2 unified API");
  console.log("See: https://docs.etherscan.io/v2-migration");
  console.log("");

  // Etherscan v2 API format (per https://docs.etherscan.io/v2-migration):
  // - chainid, apikey, module, action in query string
  // - Large data (address, abi) in POST body to avoid URI length limits
  const queryParams = new URLSearchParams({
    chainid: chainId.toString(),
    apikey: apiKey,
    module: "contract",
    action: "setabi",
  });

  const formData = new URLSearchParams();
  formData.append("address", address);
  formData.append("abi", JSON.stringify(abi));

  try {
    console.log("Submitting ABI...");
    const urlWithParams = `${apiUrl}?${queryParams.toString()}`;
    const response = await fetch(urlWithParams, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: formData.toString(),
    });

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const data: BasescanApiResponse = await response.json();

    if (data.status === "1" || data.message === "OK") {
      console.log("✅ ABI submitted successfully!");
      console.log("");
      console.log("View contract on Basescan:");
      console.log(`   https://basescan.org/address/${address}#code`);
      console.log("");
      if (data.result) {
        console.log("Result:", data.result);
      }
    } else {
      console.error("❌ Failed to submit ABI");
      console.error("Status:", data.status);
      console.error("Message:", data.message);
      if (data.result) {
        console.error("Result:", data.result);
        // Check if it's a paid plan requirement
        if (data.result.includes("Free API access is not supported")) {
          console.error("");
          console.error("⚠️  Base (chainid 8453) requires a paid Etherscan API plan.");
          console.error("   Upgrade at: https://etherscan.io/apis");
          console.error("   Or use Basescan's legacy endpoint (if still available)");
        }
      }
      process.exit(1);
    }
  } catch (error) {
    console.error("Error submitting ABI:", error);
    if (error instanceof Error) {
      console.error("Error message:", error.message);
    }
    process.exit(1);
  }
}

function loadFoundryArtifact(contractName: string): { abi: any[] } {
  const artifactPaths = [
    // Foundry output
    join(process.cwd(), "out", `${contractName}.sol`, `${contractName}.json`),
    // Alternative path
    join(process.cwd(), "out", contractName, `${contractName}.json`),
  ];

  for (const artifactPath of artifactPaths) {
    try {
      const artifactContent = readFileSync(artifactPath, "utf-8");
      const artifact = JSON.parse(artifactContent);

      if (artifact.abi) {
        return { abi: artifact.abi };
      }
    } catch (error) {
      // Try next path
      continue;
    }
  }

  throw new Error(
    `Could not find artifact for ${contractName}. Tried paths:\n${artifactPaths.join("\n")}`
  );
}

function main() {
  // Load .env file first
  loadEnvFile();

  // Parse command line arguments
  const args = process.argv.slice(2);
  let contractName: string | undefined;
  let contractAddress: string | undefined;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--contract" || args[i] === "-c") {
      contractName = args[++i];
    } else if (args[i] === "--address" || args[i] === "-a") {
      contractAddress = args[++i];
    } else if (args[i] === "--help" || args[i] === "-h") {
      console.log(`
Usage: npx tsx script/submit-abi-to-basescan.ts [options]

Options:
  --contract, -c <name>     Contract name (e.g., AnalogVault)
  --address, -a <address>   Contract address
  --help, -h                Show this help message

Environment Variables:
  ETHERSCAN_API_KEY         Etherscan/Basescan API key (required, can be in .env)
  BASESCAN_API_KEY          Alternative API key name (for backwards compatibility)
  CONTRACT_NAME             Contract name (alternative to --contract)
  CONTRACT_ADDRESS          Contract address (alternative to --address)

Example:
  npx tsx script/submit-abi-to-basescan.ts \\
    --contract AnalogVault \\
    --address 0x638c3E850E8B1DA16C44f8A04D89FD922200Ff1d

Note: ETHERSCAN_API_KEY can be set in .env file or as environment variable.
      `);
      process.exit(0);
    }
  }

  // Get values from environment or arguments
  contractName = contractName || process.env.CONTRACT_NAME;
  contractAddress = contractAddress || process.env.CONTRACT_ADDRESS;
  // Support both ETHERSCAN_API_KEY and BASESCAN_API_KEY for backwards compatibility
  const apiKey = process.env.ETHERSCAN_API_KEY || process.env.BASESCAN_API_KEY;

  // Validate inputs
  if (!apiKey) {
    console.error("❌ Error: ETHERSCAN_API_KEY environment variable is required");
    console.error("   Set it in .env file or as environment variable");
    console.error("   Get your API key from: https://basescan.org/myapikey");
    process.exit(1);
  }

  if (!contractName) {
    console.error("❌ Error: Contract name is required");
    console.error("   Use --contract <name> or set CONTRACT_NAME environment variable");
    process.exit(1);
  }

  if (!contractAddress) {
    console.error("❌ Error: Contract address is required");
    console.error("   Use --address <address> or set CONTRACT_ADDRESS environment variable");
    process.exit(1);
  }

  // Load ABI from Foundry artifact
  console.log(`Loading ABI for ${contractName}...`);
  let abi: any[];
  try {
    const artifact = loadFoundryArtifact(contractName);
    abi = artifact.abi;
    console.log(`✅ Loaded ABI with ${abi.length} items`);
    console.log("");
  } catch (error) {
    console.error("❌ Error loading artifact:", error);
    if (error instanceof Error) {
      console.error("   ", error.message);
    }
    process.exit(1);
  }

  // Submit ABI to Basescan
  submitABIToBasescan(contractAddress, abi, apiKey)
    .then(() => {
      console.log("========================================");
      console.log("Done!");
      console.log("========================================");
    })
    .catch((error) => {
      console.error("Fatal error:", error);
      process.exit(1);
    });
}

main();
