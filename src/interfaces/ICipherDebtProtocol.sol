// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICipherDebtProtocol {
    struct MarketView {
        uint256 id;
        address asset;
        address collateralAsset;
        bool active;
        uint256 borrowIndex;
        uint256 lastAccrual;
        uint256 totalDebt;
        uint256 suppliedLiquidity;
        uint256 reserveBalance;
        uint256 borrowRatePerSecond;
        uint256 collateralFactor;
        uint256 liquidationThreshold;
        uint256 liquidationBonus;
        uint256 reserveFactor;
        uint256 minDebt;
        uint256 supplyCap;
        uint256 borrowCap;
    }

    struct PositionView {
        uint256 marketId;
        address account;
        uint256 principal;
        uint256 indexSnapshot;
        uint256 currentDebt;
        uint256 collateralAmount;
        uint256 collateralValue;
        uint256 debtValue;
        uint256 borrowCapacity;
        uint256 liquidationCapacity;
        uint256 healthFactor;
        bool liquidatable;
    }

    function marketCount() external view returns (uint256);
    function getMarket(uint256 marketId) external view returns (MarketView memory);
    function getPosition(
        uint256 marketId,
        address account
    ) external view returns (PositionView memory);
    function quoteCurrentDebt(uint256 marketId, address account) external view returns (uint256);
    function quoteHealthFactor(uint256 marketId, address account) external view returns (uint256);
}
