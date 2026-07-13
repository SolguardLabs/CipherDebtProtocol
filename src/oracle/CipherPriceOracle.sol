// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { ProtocolAccess } from "../access/ProtocolAccess.sol";

contract CipherPriceOracle is IPriceOracle, ProtocolAccess {
    struct OracleRecord {
        uint256 priceWad;
        uint256 updatedAt;
        uint256 maxDelay;
        bool paused;
        bool configured;
    }

    mapping(address => OracleRecord) private _records;

    event AssetConfigured(address indexed asset, uint256 maxDelay);
    event MaxDelayUpdated(address indexed asset, uint256 maxDelay);

    error AssetNotConfigured();
    error PriceUnavailable();
    error PricePaused();
    error StalePrice();

    constructor(address initialOwner) ProtocolAccess(initialOwner) {}

    function configureAsset(address asset, uint256 maxDelay) external onlyRole(ORACLE_ADMIN_ROLE) {
        require(asset != address(0), "ASSET");
        require(maxDelay >= 1 minutes, "DELAY");
        OracleRecord storage record = _records[asset];
        record.maxDelay = maxDelay;
        record.configured = true;
        emit AssetConfigured(asset, maxDelay);
    }

    function setPrice(address asset, uint256 newPriceWad) external onlyRole(ORACLE_ADMIN_ROLE) {
        require(newPriceWad != 0, "PRICE");
        OracleRecord storage record = _records[asset];
        if (!record.configured) revert AssetNotConfigured();
        record.priceWad = newPriceWad;
        record.updatedAt = block.timestamp;
        emit PriceUpdated(asset, newPriceWad, block.timestamp);
    }

    function setPaused(address asset, bool paused) external onlyRole(ORACLE_ADMIN_ROLE) {
        OracleRecord storage record = _records[asset];
        if (!record.configured) revert AssetNotConfigured();
        record.paused = paused;
        emit AssetPaused(asset, paused);
    }

    function setMaxDelay(address asset, uint256 maxDelay) external onlyRole(ORACLE_ADMIN_ROLE) {
        require(maxDelay >= 1 minutes, "DELAY");
        OracleRecord storage record = _records[asset];
        if (!record.configured) revert AssetNotConfigured();
        record.maxDelay = maxDelay;
        emit MaxDelayUpdated(asset, maxDelay);
    }

    function getPrice(address asset) external view returns (PriceData memory data) {
        OracleRecord storage record = _records[asset];
        if (!record.configured || record.priceWad == 0 || record.paused) {
            return PriceData({ priceWad: 0, updatedAt: record.updatedAt, valid: false });
        }
        bool fresh = block.timestamp <= record.updatedAt + record.maxDelay;
        return PriceData({ priceWad: record.priceWad, updatedAt: record.updatedAt, valid: fresh });
    }

    function priceWad(address asset) external view returns (uint256) {
        OracleRecord storage record = _records[asset];
        if (!record.configured) revert AssetNotConfigured();
        if (record.paused) revert PricePaused();
        if (record.priceWad == 0) revert PriceUnavailable();
        if (block.timestamp > record.updatedAt + record.maxDelay) revert StalePrice();
        return record.priceWad;
    }

    function recordOf(address asset) external view returns (OracleRecord memory) {
        return _records[asset];
    }
}
