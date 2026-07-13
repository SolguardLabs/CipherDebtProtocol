// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolAccess} from "../access/ProtocolAccess.sol";

contract CipherMarketCatalog is ProtocolAccess {
    struct MarketDescriptor {
        uint256 marketId;
        string name;
        string symbol;
        string region;
        string tenor;
        string ratePolicy;
        string riskPolicy;
        string collateralPolicy;
        string oraclePolicy;
        string liquidityPolicy;
        bytes32 externalId;
        bool listed;
    }

    struct OperationalLimits {
        uint256 dailyBorrowLimit;
        uint256 dailyRepayLimit;
        uint256 migrationLimit;
        uint256 liquidationLimit;
        uint256 maxOrderAge;
        uint256 maxPendingOrders;
        bool manualReview;
    }

    struct MarketStatus {
        bool depositsOpen;
        bool borrowsOpen;
        bool repaymentsOpen;
        bool migrationsOpen;
        bool liquidationsOpen;
        bool oracleHealthy;
        bool rateHealthy;
        uint256 statusUpdatedAt;
        string note;
    }

    struct Page {
        MarketDescriptor[] descriptors;
        uint256 nextCursor;
        bool hasMore;
    }

    uint256[] private _listedMarketIds;
    mapping(uint256 => MarketDescriptor) private _descriptors;
    mapping(uint256 => OperationalLimits) private _limits;
    mapping(uint256 => MarketStatus) private _statuses;
    mapping(bytes32 => uint256) private _idByExternalId;

    event DescriptorUpdated(uint256 indexed marketId, MarketDescriptor descriptor);
    event DescriptorRemoved(uint256 indexed marketId);
    event LimitsUpdated(uint256 indexed marketId, OperationalLimits limits);
    event StatusUpdated(uint256 indexed marketId, MarketStatus status);

    error DescriptorMissing();
    error DuplicateExternalId();
    error InvalidDescriptor();

    constructor(address initialOwner) ProtocolAccess(initialOwner) {}

    function upsertDescriptor(
        MarketDescriptor calldata marketDescriptor
    ) external onlyRole(MARKET_ADMIN_ROLE) {
        _validateDescriptor(marketDescriptor);
        uint256 existingMarket = _idByExternalId[marketDescriptor.externalId];
        if (existingMarket != 0 && existingMarket - 1 != marketDescriptor.marketId) {
            revert DuplicateExternalId();
        }
        if (!_descriptors[marketDescriptor.marketId].listed) {
            _listedMarketIds.push(marketDescriptor.marketId);
        }
        _descriptors[marketDescriptor.marketId] = marketDescriptor;
        _idByExternalId[marketDescriptor.externalId] = marketDescriptor.marketId + 1;
        emit DescriptorUpdated(marketDescriptor.marketId, marketDescriptor);
    }

    function removeDescriptor(uint256 marketId) external onlyRole(MARKET_ADMIN_ROLE) {
        if (!_descriptors[marketId].listed) revert DescriptorMissing();
        bytes32 externalId = _descriptors[marketId].externalId;
        delete _descriptors[marketId];
        delete _limits[marketId];
        delete _statuses[marketId];
        delete _idByExternalId[externalId];
        for (uint256 i = 0; i < _listedMarketIds.length; i++) {
            if (_listedMarketIds[i] == marketId) {
                _listedMarketIds[i] = _listedMarketIds[_listedMarketIds.length - 1];
                _listedMarketIds.pop();
                break;
            }
        }
        emit DescriptorRemoved(marketId);
    }

    function setOperationalLimits(
        uint256 marketId,
        OperationalLimits calldata newLimits
    ) external onlyRole(RISK_ADMIN_ROLE) {
        if (!_descriptors[marketId].listed) revert DescriptorMissing();
        require(newLimits.maxOrderAge >= 1 minutes || newLimits.maxOrderAge == 0, "ORDER_AGE");
        _limits[marketId] = newLimits;
        emit LimitsUpdated(marketId, newLimits);
    }

    function setMarketStatus(
        uint256 marketId,
        MarketStatus calldata newStatus
    ) external onlyRole(PAUSER_ROLE) {
        if (!_descriptors[marketId].listed) revert DescriptorMissing();
        MarketStatus memory next = newStatus;
        next.statusUpdatedAt = block.timestamp;
        _statuses[marketId] = next;
        emit StatusUpdated(marketId, next);
    }

    function descriptor(uint256 marketId) external view returns (MarketDescriptor memory) {
        if (!_descriptors[marketId].listed) revert DescriptorMissing();
        return _descriptors[marketId];
    }

    function limits(uint256 marketId) external view returns (OperationalLimits memory) {
        if (!_descriptors[marketId].listed) revert DescriptorMissing();
        return _limits[marketId];
    }

    function status(uint256 marketId) external view returns (MarketStatus memory) {
        if (!_descriptors[marketId].listed) revert DescriptorMissing();
        return _statuses[marketId];
    }

    function listedMarketIds() external view returns (uint256[] memory ids) {
        ids = new uint256[](_listedMarketIds.length);
        for (uint256 i = 0; i < _listedMarketIds.length; i++) {
            ids[i] = _listedMarketIds[i];
        }
    }

    function page(uint256 cursor, uint256 size) external view returns (Page memory result) {
        if (cursor >= _listedMarketIds.length || size == 0) {
            result.descriptors = new MarketDescriptor[](0);
            result.nextCursor = cursor;
            result.hasMore = false;
            return result;
        }
        uint256 end = cursor + size;
        if (end > _listedMarketIds.length) end = _listedMarketIds.length;
        result.descriptors = new MarketDescriptor[](end - cursor);
        for (uint256 i = cursor; i < end; i++) {
            result.descriptors[i - cursor] = _descriptors[_listedMarketIds[i]];
        }
        result.nextCursor = end;
        result.hasMore = end < _listedMarketIds.length;
    }

    function findByExternalId(bytes32 externalId) external view returns (MarketDescriptor memory) {
        uint256 encoded = _idByExternalId[externalId];
        if (encoded == 0) revert DescriptorMissing();
        return _descriptors[encoded - 1];
    }

    function marketCount() external view returns (uint256) {
        return _listedMarketIds.length;
    }

    function isListed(uint256 marketId) external view returns (bool) {
        return _descriptors[marketId].listed;
    }

    function readinessScore(uint256 marketId) external view returns (uint256 score) {
        if (!_descriptors[marketId].listed) revert DescriptorMissing();
        MarketStatus memory s = _statuses[marketId];
        if (s.depositsOpen) score += 15;
        if (s.borrowsOpen) score += 20;
        if (s.repaymentsOpen) score += 15;
        if (s.migrationsOpen) score += 15;
        if (s.liquidationsOpen) score += 15;
        if (s.oracleHealthy) score += 10;
        if (s.rateHealthy) score += 10;
    }

    function requiresManualReview(
        uint256 marketId,
        uint256 orderAmount,
        uint256 pendingOrders
    ) external view returns (bool) {
        if (!_descriptors[marketId].listed) revert DescriptorMissing();
        OperationalLimits memory l = _limits[marketId];
        if (l.manualReview) return true;
        if (l.migrationLimit != 0 && orderAmount > l.migrationLimit) return true;
        if (l.maxPendingOrders != 0 && pendingOrders > l.maxPendingOrders) return true;
        return false;
    }

    function policyDigest(uint256 marketId) external view returns (bytes32) {
        if (!_descriptors[marketId].listed) revert DescriptorMissing();
        MarketDescriptor memory d = _descriptors[marketId];
        OperationalLimits memory l = _limits[marketId];
        MarketStatus memory s = _statuses[marketId];
        return
            keccak256(
                abi.encode(
                    d.marketId,
                    d.externalId,
                    d.ratePolicy,
                    d.riskPolicy,
                    d.collateralPolicy,
                    d.oraclePolicy,
                    d.liquidityPolicy,
                    l.dailyBorrowLimit,
                    l.dailyRepayLimit,
                    l.migrationLimit,
                    l.liquidationLimit,
                    s.depositsOpen,
                    s.borrowsOpen,
                    s.migrationsOpen,
                    s.oracleHealthy,
                    s.rateHealthy
                )
            );
    }

    function _validateDescriptor(MarketDescriptor calldata marketDescriptor) internal pure {
        if (bytes(marketDescriptor.name).length == 0) revert InvalidDescriptor();
        if (bytes(marketDescriptor.symbol).length == 0) revert InvalidDescriptor();
        if (marketDescriptor.externalId == bytes32(0)) revert InvalidDescriptor();
        if (!marketDescriptor.listed) revert InvalidDescriptor();
    }
}
