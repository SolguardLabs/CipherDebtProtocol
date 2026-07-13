// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMath} from "./FixedPointMath.sol";

library RiskMath {
    using FixedPointMath for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_FACTOR = 0.95e18;
    uint256 internal constant MAX_LIQUIDATION_BONUS = 0.35e18;

    struct RiskParameters {
        uint256 collateralFactor;
        uint256 liquidationThreshold;
        uint256 liquidationBonus;
        uint256 minHealthFactor;
    }

    struct Valuation {
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 collateralPrice;
        uint256 debtPrice;
        uint256 collateralValue;
        uint256 debtValue;
        uint256 borrowCapacity;
        uint256 liquidationCapacity;
        uint256 healthFactor;
        bool liquidatable;
    }

    function validateRisk(
        uint256 collateralFactor,
        uint256 liquidationThreshold,
        uint256 liquidationBonus
    ) internal pure {
        require(collateralFactor <= MAX_FACTOR, "COLLATERAL_FACTOR");
        require(liquidationThreshold <= MAX_FACTOR, "LIQ_THRESHOLD");
        require(collateralFactor <= liquidationThreshold, "RISK_ORDER");
        require(liquidationBonus <= MAX_LIQUIDATION_BONUS, "LIQ_BONUS");
    }

    function assetValue(uint256 amount, uint256 priceWad) internal pure returns (uint256) {
        return FixedPointMath.mulWad(amount, priceWad);
    }

    function collateralCapacity(
        uint256 collateralValue,
        uint256 collateralFactor
    ) internal pure returns (uint256) {
        return FixedPointMath.mulWad(collateralValue, collateralFactor);
    }

    function liquidationCapacity(
        uint256 collateralValue,
        uint256 threshold
    ) internal pure returns (uint256) {
        return FixedPointMath.mulWad(collateralValue, threshold);
    }

    function healthFactor(
        uint256 collateralValue,
        uint256 debtValue,
        uint256 threshold
    ) internal pure returns (uint256) {
        if (debtValue == 0) return type(uint256).max;
        uint256 protectedValue = liquidationCapacity(collateralValue, threshold);
        return FixedPointMath.divWad(protectedValue, debtValue);
    }

    function borrowRoom(
        uint256 collateralValue,
        uint256 debtValue,
        uint256 collateralFactor
    ) internal pure returns (uint256) {
        uint256 capacity = collateralCapacity(collateralValue, collateralFactor);
        if (capacity <= debtValue) return 0;
        return capacity - debtValue;
    }

    function evaluate(
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 collateralPrice,
        uint256 debtPrice,
        uint256 collateralFactor,
        uint256 threshold
    ) internal pure returns (Valuation memory value) {
        value.collateralAmount = collateralAmount;
        value.debtAmount = debtAmount;
        value.collateralPrice = collateralPrice;
        value.debtPrice = debtPrice;
        value.collateralValue = assetValue(collateralAmount, collateralPrice);
        value.debtValue = assetValue(debtAmount, debtPrice);
        value.borrowCapacity = collateralCapacity(value.collateralValue, collateralFactor);
        value.liquidationCapacity = liquidationCapacity(value.collateralValue, threshold);
        value.healthFactor = healthFactor(value.collateralValue, value.debtValue, threshold);
        value.liquidatable = value.debtValue != 0 && value.healthFactor < WAD;
    }

    function maxBorrowByValue(
        uint256 collateralAmount,
        uint256 collateralPrice,
        uint256 existingDebt,
        uint256 debtPrice,
        uint256 collateralFactor
    ) internal pure returns (uint256) {
        uint256 collateralValue_ = assetValue(collateralAmount, collateralPrice);
        uint256 debtValue_ = assetValue(existingDebt, debtPrice);
        uint256 room = borrowRoom(collateralValue_, debtValue_, collateralFactor);
        if (room == 0) return 0;
        return FixedPointMath.divWad(room, debtPrice);
    }

    function maxWithdrawByValue(
        uint256 collateralAmount,
        uint256 collateralPrice,
        uint256 debtValue,
        uint256 collateralFactor
    ) internal pure returns (uint256) {
        if (debtValue == 0) return collateralAmount;
        if (collateralFactor == 0) return 0;
        uint256 requiredCollateralValue = FixedPointMath.divWadUp(debtValue, collateralFactor);
        uint256 currentCollateralValue = assetValue(collateralAmount, collateralPrice);
        if (currentCollateralValue <= requiredCollateralValue) return 0;
        uint256 withdrawValue = currentCollateralValue - requiredCollateralValue;
        return FixedPointMath.divWad(withdrawValue, collateralPrice);
    }

    function seizeCollateral(
        uint256 repayAmount,
        uint256 debtPrice,
        uint256 collateralPrice,
        uint256 liquidationBonus
    ) internal pure returns (uint256) {
        uint256 repayValue = assetValue(repayAmount, debtPrice);
        uint256 bonusValue = FixedPointMath.mulWad(repayValue, WAD + liquidationBonus);
        return FixedPointMath.divWadUp(bonusValue, collateralPrice);
    }

    function repayValueForSeizedCollateral(
        uint256 collateralAmount,
        uint256 collateralPrice,
        uint256 debtPrice,
        uint256 liquidationBonus
    ) internal pure returns (uint256) {
        uint256 collateralValue_ = assetValue(collateralAmount, collateralPrice);
        uint256 repayValue = FixedPointMath.divWad(collateralValue_, WAD + liquidationBonus);
        return FixedPointMath.divWad(repayValue, debtPrice);
    }

    function checkMinHealth(uint256 health, uint256 minHealth) internal pure {
        require(health >= minHealth, "HEALTH");
    }

    function isSolvent(uint256 health) internal pure returns (bool) {
        return health >= WAD;
    }

    function utilizationRiskLevel(uint256 utilizationWad) internal pure returns (uint8) {
        if (utilizationWad < 0.5e18) return 0;
        if (utilizationWad < 0.75e18) return 1;
        if (utilizationWad < 0.9e18) return 2;
        return 3;
    }
}
