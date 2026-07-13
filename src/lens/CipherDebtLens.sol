// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ICipherDebtProtocol } from "../interfaces/ICipherDebtProtocol.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";
import { RiskMath } from "../libraries/RiskMath.sol";

contract CipherDebtLens {
    using FixedPointMath for uint256;

    uint256 public constant WAD = 1e18;

    struct MarketPage {
        ICipherDebtProtocol.MarketView[] markets;
        uint256 nextCursor;
        bool hasMore;
    }

    struct AccountMarket {
        uint256 marketId;
        uint256 collateralAmount;
        uint256 currentDebt;
        uint256 collateralValue;
        uint256 debtValue;
        uint256 healthFactor;
        uint256 borrowRoom;
        uint256 maxWithdraw;
        bool liquidatable;
    }

    struct AccountSummary {
        address account;
        uint256 marketsVisited;
        uint256 totalCollateralValue;
        uint256 totalDebtValue;
        uint256 weakestHealthFactor;
        uint256 liquidatableMarkets;
        uint256 activeDebtMarkets;
    }

    struct MarketUtilization {
        uint256 marketId;
        uint256 availableLiquidity;
        uint256 suppliedLiquidity;
        uint256 totalDebt;
        uint256 utilization;
        uint256 borrowIndex;
        uint256 reserveBalance;
        uint8 band;
    }

    struct LiquidationPreview {
        uint256 marketId;
        address borrower;
        uint256 currentDebt;
        uint256 healthFactor;
        uint256 repayAmount;
        uint256 collateralToSeize;
        uint256 remainingDebt;
        uint256 remainingCollateral;
        bool allowed;
    }

    struct BorrowPreview {
        uint256 marketId;
        address account;
        uint256 requestedBorrow;
        uint256 debtBefore;
        uint256 debtAfter;
        uint256 borrowRoomBefore;
        uint256 healthAfter;
        bool allowed;
    }

    struct WithdrawPreview {
        uint256 marketId;
        address account;
        uint256 requestedWithdraw;
        uint256 collateralBefore;
        uint256 collateralAfter;
        uint256 healthAfter;
        bool allowed;
    }

    function marketPage(
        ICipherDebtProtocol protocol,
        uint256 cursor,
        uint256 size
    ) external view returns (MarketPage memory page) {
        uint256 count = protocol.marketCount();
        if (cursor >= count || size == 0) {
            page.markets = new ICipherDebtProtocol.MarketView[](0);
            page.nextCursor = cursor;
            page.hasMore = false;
            return page;
        }
        uint256 end = cursor + size;
        if (end > count) end = count;
        page.markets = new ICipherDebtProtocol.MarketView[](end - cursor);
        for (uint256 i = cursor; i < end; i++) {
            page.markets[i - cursor] = protocol.getMarket(i);
        }
        page.nextCursor = end;
        page.hasMore = end < count;
    }

    function accountMarkets(
        ICipherDebtProtocol protocol,
        address account,
        uint256[] calldata marketIds
    ) external view returns (AccountMarket[] memory rows) {
        rows = new AccountMarket[](marketIds.length);
        for (uint256 i = 0; i < marketIds.length; i++) {
            rows[i] = _accountMarket(protocol, account, marketIds[i]);
        }
    }

    function accountSummary(
        ICipherDebtProtocol protocol,
        address account,
        uint256[] calldata marketIds
    ) external view returns (AccountSummary memory summary) {
        summary.account = account;
        summary.marketsVisited = marketIds.length;
        summary.weakestHealthFactor = type(uint256).max;
        for (uint256 i = 0; i < marketIds.length; i++) {
            ICipherDebtProtocol.PositionView memory position = protocol.getPosition(
                marketIds[i],
                account
            );
            summary.totalCollateralValue += position.collateralValue;
            summary.totalDebtValue += position.debtValue;
            if (position.currentDebt != 0) summary.activeDebtMarkets += 1;
            if (position.liquidatable) summary.liquidatableMarkets += 1;
            if (position.healthFactor < summary.weakestHealthFactor) {
                summary.weakestHealthFactor = position.healthFactor;
            }
        }
        if (summary.activeDebtMarkets == 0) summary.weakestHealthFactor = type(uint256).max;
    }

    function marketUtilization(
        ICipherDebtProtocol protocol,
        uint256 marketId
    ) public view returns (MarketUtilization memory row) {
        ICipherDebtProtocol.MarketView memory market = protocol.getMarket(marketId);
        uint256 available = protocolAvailableLiquidity(protocol, marketId);
        uint256 denominator = available + market.totalDebt;
        uint256 util = denominator == 0 ? 0 : FixedPointMath.divWad(market.totalDebt, denominator);
        row.marketId = marketId;
        row.availableLiquidity = available;
        row.suppliedLiquidity = market.suppliedLiquidity;
        row.totalDebt = market.totalDebt;
        row.utilization = util;
        row.borrowIndex = market.borrowIndex;
        row.reserveBalance = market.reserveBalance;
        row.band = _utilizationBand(util);
    }

    function utilizationPage(
        ICipherDebtProtocol protocol,
        uint256[] calldata marketIds
    ) external view returns (MarketUtilization[] memory rows) {
        rows = new MarketUtilization[](marketIds.length);
        for (uint256 i = 0; i < marketIds.length; i++) {
            rows[i] = marketUtilization(protocol, marketIds[i]);
        }
    }

    function previewBorrow(
        ICipherDebtProtocol protocol,
        address account,
        uint256 marketId,
        uint256 borrowAmount
    ) external view returns (BorrowPreview memory preview) {
        ICipherDebtProtocol.PositionView memory position = protocol.getPosition(marketId, account);
        ICipherDebtProtocol.MarketView memory market = protocol.getMarket(marketId);
        uint256 debtAfter = position.currentDebt + borrowAmount;
        uint256 debtValueAfter = FixedPointMath.mulWad(debtAfter, _safeUnitPrice(market.asset));
        uint256 protectedValue = FixedPointMath.mulWad(
            position.collateralValue,
            market.liquidationThreshold
        );
        uint256 healthAfter = debtValueAfter == 0
            ? type(uint256).max
            : FixedPointMath.divWad(protectedValue, debtValueAfter);
        preview.marketId = marketId;
        preview.account = account;
        preview.requestedBorrow = borrowAmount;
        preview.debtBefore = position.currentDebt;
        preview.debtAfter = debtAfter;
        preview.borrowRoomBefore = position.borrowCapacity > position.debtValue
            ? position.borrowCapacity - position.debtValue
            : 0;
        preview.healthAfter = healthAfter;
        preview.allowed =
            healthAfter >= WAD &&
            borrowAmount <= protocolAvailableLiquidity(protocol, marketId);
    }

    function previewWithdraw(
        ICipherDebtProtocol protocol,
        address account,
        uint256 marketId,
        uint256 withdrawAmount
    ) external view returns (WithdrawPreview memory preview) {
        ICipherDebtProtocol.PositionView memory position = protocol.getPosition(marketId, account);
        ICipherDebtProtocol.MarketView memory market = protocol.getMarket(marketId);
        uint256 collateralAfter = withdrawAmount > position.collateralAmount
            ? 0
            : position.collateralAmount - withdrawAmount;
        uint256 collateralPrice = _safeUnitPrice(market.collateralAsset);
        uint256 collateralValueAfter = FixedPointMath.mulWad(collateralAfter, collateralPrice);
        uint256 debtValue = position.debtValue;
        uint256 protectedValue = FixedPointMath.mulWad(
            collateralValueAfter,
            market.liquidationThreshold
        );
        uint256 healthAfter = debtValue == 0
            ? type(uint256).max
            : FixedPointMath.divWad(protectedValue, debtValue);
        preview.marketId = marketId;
        preview.account = account;
        preview.requestedWithdraw = withdrawAmount;
        preview.collateralBefore = position.collateralAmount;
        preview.collateralAfter = collateralAfter;
        preview.healthAfter = healthAfter;
        preview.allowed = withdrawAmount <= position.collateralAmount && healthAfter >= WAD;
    }

    function previewLiquidation(
        ICipherDebtProtocol protocol,
        IPriceOracle oracle,
        uint256 marketId,
        address borrower,
        uint256 repayAmount
    ) external view returns (LiquidationPreview memory preview) {
        ICipherDebtProtocol.MarketView memory market = protocol.getMarket(marketId);
        ICipherDebtProtocol.PositionView memory position = protocol.getPosition(marketId, borrower);
        uint256 debtPrice = _oraclePrice(oracle, market.asset);
        uint256 collateralPrice = _oraclePrice(oracle, market.collateralAsset);
        uint256 paid = FixedPointMath.min(repayAmount, position.currentDebt);
        uint256 seized = RiskMath.seizeCollateral(
            paid,
            debtPrice,
            collateralPrice,
            market.liquidationBonus
        );
        if (seized > position.collateralAmount) {
            seized = position.collateralAmount;
        }
        preview.marketId = marketId;
        preview.borrower = borrower;
        preview.currentDebt = position.currentDebt;
        preview.healthFactor = position.healthFactor;
        preview.repayAmount = paid;
        preview.collateralToSeize = seized;
        preview.remainingDebt = position.currentDebt > paid ? position.currentDebt - paid : 0;
        preview.remainingCollateral = position.collateralAmount > seized
            ? position.collateralAmount - seized
            : 0;
        preview.allowed = position.healthFactor < WAD && paid != 0 && seized != 0;
    }

    function protocolAvailableLiquidity(
        ICipherDebtProtocol protocol,
        uint256 marketId
    ) public view returns (uint256) {
        try protocol.getMarket(marketId) returns (ICipherDebtProtocol.MarketView memory market) {
            if (market.suppliedLiquidity <= market.totalDebt + market.reserveBalance) return 0;
            return market.suppliedLiquidity - market.totalDebt - market.reserveBalance;
        } catch {
            return 0;
        }
    }

    function sortMarketsByUtilization(
        ICipherDebtProtocol protocol,
        uint256[] calldata marketIds
    ) external view returns (uint256[] memory sortedIds, uint256[] memory utilizations) {
        sortedIds = new uint256[](marketIds.length);
        utilizations = new uint256[](marketIds.length);
        for (uint256 i = 0; i < marketIds.length; i++) {
            MarketUtilization memory row = marketUtilization(protocol, marketIds[i]);
            sortedIds[i] = marketIds[i];
            utilizations[i] = row.utilization;
        }
        for (uint256 i = 0; i < sortedIds.length; i++) {
            for (uint256 j = i + 1; j < sortedIds.length; j++) {
                if (utilizations[j] > utilizations[i]) {
                    (utilizations[i], utilizations[j]) = (utilizations[j], utilizations[i]);
                    (sortedIds[i], sortedIds[j]) = (sortedIds[j], sortedIds[i]);
                }
            }
        }
    }

    function weakestPosition(
        ICipherDebtProtocol protocol,
        address account,
        uint256[] calldata marketIds
    ) external view returns (uint256 marketId, uint256 healthFactor) {
        healthFactor = type(uint256).max;
        for (uint256 i = 0; i < marketIds.length; i++) {
            ICipherDebtProtocol.PositionView memory position = protocol.getPosition(
                marketIds[i],
                account
            );
            if (position.currentDebt != 0 && position.healthFactor < healthFactor) {
                healthFactor = position.healthFactor;
                marketId = marketIds[i];
            }
        }
    }

    function debtWeightedHealth(
        ICipherDebtProtocol protocol,
        address account,
        uint256[] calldata marketIds
    ) external view returns (uint256) {
        uint256 weighted;
        uint256 totalDebtValue;
        for (uint256 i = 0; i < marketIds.length; i++) {
            ICipherDebtProtocol.PositionView memory position = protocol.getPosition(
                marketIds[i],
                account
            );
            if (position.debtValue != 0 && position.healthFactor != type(uint256).max) {
                weighted += position.healthFactor * position.debtValue;
                totalDebtValue += position.debtValue;
            }
        }
        if (totalDebtValue == 0) return type(uint256).max;
        return weighted / totalDebtValue;
    }

    function _accountMarket(
        ICipherDebtProtocol protocol,
        address account,
        uint256 marketId
    ) internal view returns (AccountMarket memory row) {
        ICipherDebtProtocol.PositionView memory position = protocol.getPosition(marketId, account);
        ICipherDebtProtocol.MarketView memory market = protocol.getMarket(marketId);
        uint256 maxWithdraw = RiskMath.maxWithdrawByValue(
            position.collateralAmount,
            _safeUnitPrice(market.collateralAsset),
            position.debtValue,
            market.collateralFactor
        );
        uint256 borrowRoom = position.borrowCapacity > position.debtValue
            ? position.borrowCapacity - position.debtValue
            : 0;
        row.marketId = marketId;
        row.collateralAmount = position.collateralAmount;
        row.currentDebt = position.currentDebt;
        row.collateralValue = position.collateralValue;
        row.debtValue = position.debtValue;
        row.healthFactor = position.healthFactor;
        row.borrowRoom = borrowRoom;
        row.maxWithdraw = maxWithdraw;
        row.liquidatable = position.liquidatable;
    }

    function _oraclePrice(IPriceOracle oracle, address asset) internal view returns (uint256) {
        IPriceOracle.PriceData memory data = oracle.getPrice(asset);
        return data.valid ? data.priceWad : 0;
    }

    function _safeUnitPrice(address) internal pure returns (uint256) {
        return WAD;
    }

    function _utilizationBand(uint256 util) internal pure returns (uint8) {
        if (util < 0.25e18) return 0;
        if (util < 0.5e18) return 1;
        if (util < 0.75e18) return 2;
        if (util < 0.9e18) return 3;
        if (util < 0.97e18) return 4;
        return 5;
    }
}
