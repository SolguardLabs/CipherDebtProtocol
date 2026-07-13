// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPriceOracle {
    struct PriceData {
        uint256 priceWad;
        uint256 updatedAt;
        bool valid;
    }

    event PriceUpdated(address indexed asset, uint256 priceWad, uint256 updatedAt);
    event AssetPaused(address indexed asset, bool paused);

    function getPrice(address asset) external view returns (PriceData memory data);
    function priceWad(address asset) external view returns (uint256);
}
