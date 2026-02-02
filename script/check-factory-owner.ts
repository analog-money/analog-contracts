import { createPublicClient, http } from 'viem';
import { base } from 'viem/chains';

async function main() {
  const publicClient = createPublicClient({
    chain: base,
    transport: http(process.env.BASE_RPC_URL || 'https://mainnet.base.org'),
  });

  const factoryAddress = '0xDC63499Acb698Eb71c18569d33e51E5D1ff5B33D' as `0x${string}`;

  // Get factory owner
  const owner = await publicClient.readContract({
    address: factoryAddress,
    abi: [{
      inputs: [],
      name: 'owner',
      outputs: [{ name: '', type: 'address' }],
      stateMutability: 'view',
      type: 'function',
    }],
    functionName: 'owner',
  });

  console.log('Factory owner:', owner);
  console.log('DEPLOYER_PRIVATE_KEY set:', !!process.env.DEPLOYER_PRIVATE_KEY);
}

main().catch(console.error);

