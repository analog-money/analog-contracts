// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MockNexusDistributor {
    event CoverPurchased(uint256 indexed coverId, address indexed buyer, address indexed product, address coverAsset, uint256 amount, uint256 period, uint256 premium);

    struct Cover {
        uint256 coverId;
        uint256 productId;
        address contractAddress;
        uint256 amount;
        uint256 period;
        uint256 premium;
    }

    uint256 public nextCoverId = 1;

    function buyCover(
        address contractAddress,
        address coverAsset,
        uint256 amount,
        uint256 period,
        uint256 typeId,
        uint256 maxPremiumInAsset,
        bytes[] calldata externalData
    ) external payable returns (uint256 coverId) {
        coverId = nextCoverId++;
        // Emit event to simulate purchase
        emit CoverPurchased(coverId, msg.sender, contractAddress, coverAsset, amount, period, maxPremiumInAsset);
        return coverId;
    }
}
