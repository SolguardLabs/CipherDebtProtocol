// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMath} from "./FixedPointMath.sol";

library PortfolioAnalytics {
    using FixedPointMath for uint256;

    uint256 internal constant WAD = 1e18;

    struct MarketExposure {
        uint256 marketId;
        uint256 collateralValue;
        uint256 debtValue;
        uint256 healthFactor;
        uint256 utilization;
        uint256 liquidationCapacity;
        uint256 borrowCapacity;
        bool liquidatable;
    }

    struct PortfolioTotals {
        uint256 collateralValue;
        uint256 debtValue;
        uint256 borrowCapacity;
        uint256 liquidationCapacity;
        uint256 weightedHealth;
        uint256 weakestHealth;
        uint256 strongestHealth;
        uint256 liquidatableMarkets;
        uint256 activeMarkets;
    }

    struct Concentration {
        uint256 largestMarketId;
        uint256 largestDebtValue;
        uint256 largestCollateralValue;
        uint256 debtConcentration;
        uint256 collateralConcentration;
        uint256 herfindahlDebt;
        uint256 herfindahlCollateral;
    }

    struct StressResult {
        uint256 collateralShock;
        uint256 debtShock;
        uint256 stressedCollateralValue;
        uint256 stressedDebtValue;
        uint256 stressedHealth;
        bool belowThreshold;
    }

    function totals(
        MarketExposure[] memory exposures
    ) internal pure returns (PortfolioTotals memory result) {
        result.weakestHealth = type(uint256).max;
        for (uint256 i = 0; i < exposures.length; i++) {
            MarketExposure memory exposure = exposures[i];
            result.collateralValue += exposure.collateralValue;
            result.debtValue += exposure.debtValue;
            result.borrowCapacity += exposure.borrowCapacity;
            result.liquidationCapacity += exposure.liquidationCapacity;
            if (exposure.debtValue != 0) {
                result.activeMarkets += 1;
                result.weightedHealth += exposure.healthFactor * exposure.debtValue;
                if (exposure.healthFactor < result.weakestHealth) {
                    result.weakestHealth = exposure.healthFactor;
                }
                if (exposure.healthFactor > result.strongestHealth) {
                    result.strongestHealth = exposure.healthFactor;
                }
            }
            if (exposure.liquidatable) {
                result.liquidatableMarkets += 1;
            }
        }
        if (result.debtValue == 0) {
            result.weightedHealth = type(uint256).max;
            result.weakestHealth = type(uint256).max;
            result.strongestHealth = type(uint256).max;
        } else {
            result.weightedHealth = result.weightedHealth / result.debtValue;
        }
    }

    function concentration(
        MarketExposure[] memory exposures
    ) internal pure returns (Concentration memory result) {
        uint256 totalDebt;
        uint256 totalCollateral;
        for (uint256 i = 0; i < exposures.length; i++) {
            totalDebt += exposures[i].debtValue;
            totalCollateral += exposures[i].collateralValue;
            if (exposures[i].debtValue > result.largestDebtValue) {
                result.largestDebtValue = exposures[i].debtValue;
                result.largestMarketId = exposures[i].marketId;
            }
            if (exposures[i].collateralValue > result.largestCollateralValue) {
                result.largestCollateralValue = exposures[i].collateralValue;
            }
        }
        if (totalDebt != 0) {
            result.debtConcentration = FixedPointMath.divWad(result.largestDebtValue, totalDebt);
            for (uint256 i = 0; i < exposures.length; i++) {
                uint256 share = FixedPointMath.divWad(exposures[i].debtValue, totalDebt);
                result.herfindahlDebt += FixedPointMath.mulWad(share, share);
            }
        }
        if (totalCollateral != 0) {
            result.collateralConcentration = FixedPointMath.divWad(
                result.largestCollateralValue,
                totalCollateral
            );
            for (uint256 i = 0; i < exposures.length; i++) {
                uint256 share = FixedPointMath.divWad(
                    exposures[i].collateralValue,
                    totalCollateral
                );
                result.herfindahlCollateral += FixedPointMath.mulWad(share, share);
            }
        }
    }

    function stress(
        uint256 collateralValue,
        uint256 debtValue,
        uint256 liquidationThreshold,
        uint256 collateralShock,
        uint256 debtShock
    ) internal pure returns (StressResult memory result) {
        require(collateralShock <= WAD, "COLLATERAL_SHOCK");
        require(debtShock <= WAD, "DEBT_SHOCK");
        uint256 collateralMultiplier = WAD - collateralShock;
        uint256 debtMultiplier = WAD + debtShock;
        result.collateralShock = collateralShock;
        result.debtShock = debtShock;
        result.stressedCollateralValue = FixedPointMath.mulWad(
            collateralValue,
            collateralMultiplier
        );
        result.stressedDebtValue = FixedPointMath.mulWad(debtValue, debtMultiplier);
        uint256 protectedValue = FixedPointMath.mulWad(
            result.stressedCollateralValue,
            liquidationThreshold
        );
        result.stressedHealth = result.stressedDebtValue == 0
            ? type(uint256).max
            : FixedPointMath.divWad(protectedValue, result.stressedDebtValue);
        result.belowThreshold = result.stressedDebtValue != 0 && result.stressedHealth < WAD;
    }

    function stressGrid(
        uint256 collateralValue,
        uint256 debtValue,
        uint256 liquidationThreshold,
        uint256[] memory collateralShocks,
        uint256[] memory debtShocks
    ) internal pure returns (StressResult[] memory results) {
        require(collateralShocks.length == debtShocks.length, "GRID_LENGTH");
        results = new StressResult[](collateralShocks.length);
        for (uint256 i = 0; i < collateralShocks.length; i++) {
            results[i] = stress(
                collateralValue,
                debtValue,
                liquidationThreshold,
                collateralShocks[i],
                debtShocks[i]
            );
        }
    }

    function migrationEfficiency(
        uint256 sourceDebtReleased,
        uint256 destinationDebtBooked
    ) internal pure returns (uint256) {
        if (sourceDebtReleased == 0) return WAD;
        return FixedPointMath.divWad(destinationDebtBooked, sourceDebtReleased);
    }

    function collateralCoverage(
        uint256 collateralValue,
        uint256 debtValue
    ) internal pure returns (uint256) {
        if (debtValue == 0) return type(uint256).max;
        return FixedPointMath.divWad(collateralValue, debtValue);
    }

    function excessCollateral(
        uint256 collateralValue,
        uint256 debtValue,
        uint256 collateralFactor
    ) internal pure returns (uint256) {
        if (debtValue == 0) return collateralValue;
        uint256 required = FixedPointMath.divWadUp(debtValue, collateralFactor);
        return collateralValue > required ? collateralValue - required : 0;
    }

    function marginalBorrowRoom(
        uint256 collateralValue,
        uint256 debtValue,
        uint256 collateralFactor
    ) internal pure returns (uint256) {
        uint256 capacity = FixedPointMath.mulWad(collateralValue, collateralFactor);
        return capacity > debtValue ? capacity - debtValue : 0;
    }

    function weightedAverageUtilization(
        MarketExposure[] memory exposures
    ) internal pure returns (uint256) {
        uint256 weighted;
        uint256 totalDebt;
        for (uint256 i = 0; i < exposures.length; i++) {
            weighted += exposures[i].utilization * exposures[i].debtValue;
            totalDebt += exposures[i].debtValue;
        }
        if (totalDebt == 0) return 0;
        return weighted / totalDebt;
    }

    function countMarketsAboveUtilization(
        MarketExposure[] memory exposures,
        uint256 threshold
    ) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < exposures.length; i++) {
            if (exposures[i].utilization > threshold) count += 1;
        }
    }

    function countMarketsBelowHealth(
        MarketExposure[] memory exposures,
        uint256 threshold
    ) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < exposures.length; i++) {
            if (exposures[i].debtValue != 0 && exposures[i].healthFactor < threshold) count += 1;
        }
    }

    function maxDebtForHealth(
        uint256 collateralValue,
        uint256 liquidationThreshold,
        uint256 targetHealth
    ) internal pure returns (uint256) {
        require(targetHealth != 0, "TARGET_HEALTH");
        uint256 protectedValue = FixedPointMath.mulWad(collateralValue, liquidationThreshold);
        return FixedPointMath.divWad(protectedValue, targetHealth);
    }

    function minCollateralForDebt(
        uint256 debtValue,
        uint256 liquidationThreshold,
        uint256 targetHealth
    ) internal pure returns (uint256) {
        require(liquidationThreshold != 0, "THRESHOLD");
        uint256 protectedDebt = FixedPointMath.mulWad(debtValue, targetHealth);
        return FixedPointMath.divWadUp(protectedDebt, liquidationThreshold);
    }

    function healthAfterDebtChange(
        uint256 collateralValue,
        uint256 debtValue,
        uint256 debtDelta,
        bool increaseDebt,
        uint256 liquidationThreshold
    ) internal pure returns (uint256) {
        uint256 nextDebt = increaseDebt
            ? debtValue + debtDelta
            : debtDelta > debtValue
                ? 0
                : debtValue - debtDelta;
        if (nextDebt == 0) return type(uint256).max;
        uint256 protectedValue = FixedPointMath.mulWad(collateralValue, liquidationThreshold);
        return FixedPointMath.divWad(protectedValue, nextDebt);
    }

    function healthAfterCollateralChange(
        uint256 collateralValue,
        uint256 debtValue,
        uint256 collateralDelta,
        bool increaseCollateral,
        uint256 liquidationThreshold
    ) internal pure returns (uint256) {
        uint256 nextCollateral = increaseCollateral
            ? collateralValue + collateralDelta
            : collateralDelta > collateralValue
                ? 0
                : collateralValue - collateralDelta;
        if (debtValue == 0) return type(uint256).max;
        uint256 protectedValue = FixedPointMath.mulWad(nextCollateral, liquidationThreshold);
        return FixedPointMath.divWad(protectedValue, debtValue);
    }

    function liquidationBuffer(uint256 healthFactor) internal pure returns (uint256) {
        if (healthFactor == type(uint256).max) return type(uint256).max;
        return healthFactor > WAD ? healthFactor - WAD : 0;
    }

    function utilizationBuffer(
        uint256 utilization,
        uint256 targetUtilization
    ) internal pure returns (uint256) {
        return targetUtilization > utilization ? targetUtilization - utilization : 0;
    }

    function needsRebalance(
        uint256 utilization,
        uint256 lowerBound,
        uint256 upperBound
    ) internal pure returns (bool) {
        return utilization < lowerBound || utilization > upperBound;
    }

    function rebalanceDirection(
        uint256 utilization,
        uint256 target
    ) internal pure returns (int256) {
        if (utilization == target) return 0;
        return utilization > target ? int256(1) : int256(-1);
    }

    function normalizeScore(
        uint256 value,
        uint256 minValue,
        uint256 maxValue
    ) internal pure returns (uint256) {
        if (maxValue <= minValue) return 0;
        if (value <= minValue) return 0;
        if (value >= maxValue) return WAD;
        return FixedPointMath.divWad(value - minValue, maxValue - minValue);
    }

    function compositeRiskScore(
        uint256 utilization,
        uint256 healthFactor,
        uint256 concentrationWad
    ) internal pure returns (uint256) {
        uint256 utilizationScore = normalizeScore(utilization, 0.5e18, 0.95e18);
        uint256 healthScore = healthFactor >= 2e18
            ? 0
            : WAD - normalizeScore(healthFactor, WAD, 2e18);
        uint256 concentrationScore = normalizeScore(concentrationWad, 0.25e18, 0.75e18);
        return (utilizationScore * 40 + healthScore * 40 + concentrationScore * 20) / 100;
    }

    function scoreBand(uint256 riskScore) internal pure returns (uint8) {
        if (riskScore < 0.2e18) return 0;
        if (riskScore < 0.4e18) return 1;
        if (riskScore < 0.6e18) return 2;
        if (riskScore < 0.8e18) return 3;
        return 4;
    }

    function capped(uint256 value, uint256 cap) internal pure returns (uint256) {
        if (cap == 0) return value;
        return value > cap ? cap : value;
    }

    function floor(uint256 value, uint256 minimum) internal pure returns (uint256) {
        return value < minimum ? minimum : value;
    }

    function midpoint(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a / 2) + (b / 2) + (((a % 2) + (b % 2)) / 2);
    }
}
