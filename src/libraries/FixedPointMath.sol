// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library FixedPointMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HALF_WAD = 5e17;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    error DivisionByZero();
    error PercentageOverflow();

    function wad() internal pure returns (uint256) {
        return WAD;
    }

    function basisPoints() internal pure returns (uint256) {
        return BPS;
    }

    function mulWad(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / WAD;
    }

    function mulWadUp(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return ((a * b) - 1) / WAD + 1;
    }

    function divWad(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert DivisionByZero();
        return (a * WAD) / b;
    }

    function divWadUp(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert DivisionByZero();
        if (a == 0) return 0;
        return ((a * WAD) - 1) / b + 1;
    }

    function percentOf(uint256 amount, uint256 bps) internal pure returns (uint256) {
        if (bps > BPS) revert PercentageOverflow();
        return (amount * bps) / BPS;
    }

    function percentOfUp(uint256 amount, uint256 bps) internal pure returns (uint256) {
        if (bps > BPS) revert PercentageOverflow();
        if (amount == 0 || bps == 0) return 0;
        return ((amount * bps) - 1) / BPS + 1;
    }

    function ratio(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) revert DivisionByZero();
        return (numerator * WAD) / denominator;
    }

    function ratioUp(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) revert DivisionByZero();
        if (numerator == 0) return 0;
        return ((numerator * WAD) - 1) / denominator + 1;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function clamp(uint256 value, uint256 low, uint256 high) internal pure returns (uint256) {
        if (value < low) return low;
        if (value > high) return high;
        return value;
    }

    function zeroIfNegative(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function annualize(uint256 ratePerSecond) internal pure returns (uint256) {
        return ratePerSecond * SECONDS_PER_YEAR;
    }

    function deannualize(uint256 annualRate) internal pure returns (uint256) {
        return annualRate / SECONDS_PER_YEAR;
    }

    function linearGrowth(
        uint256 index,
        uint256 ratePerSecond,
        uint256 elapsed
    ) internal pure returns (uint256) {
        if (elapsed == 0 || ratePerSecond == 0) return index;
        uint256 factor = WAD + (ratePerSecond * elapsed);
        return mulWad(index, factor);
    }

    function compoundStep(
        uint256 index,
        uint256 ratePerSecond,
        uint256 elapsed
    ) internal pure returns (uint256) {
        if (elapsed == 0 || ratePerSecond == 0) return index;
        uint256 current = index;
        uint256 remaining = elapsed;
        while (remaining > 0) {
            uint256 step = remaining > 1 hours ? 1 hours : remaining;
            current = linearGrowth(current, ratePerSecond, step);
            remaining -= step;
        }
        return current;
    }

    function weightedAverage(
        uint256 a,
        uint256 weightA,
        uint256 b,
        uint256 weightB
    ) internal pure returns (uint256) {
        uint256 totalWeight = weightA + weightB;
        if (totalWeight == 0) return 0;
        return ((a * weightA) + (b * weightB)) / totalWeight;
    }

    function weightedAverageWad(
        uint256 a,
        uint256 weightA,
        uint256 b,
        uint256 weightB
    ) internal pure returns (uint256) {
        uint256 totalWeight = weightA + weightB;
        if (totalWeight == 0) return 0;
        return divWad((mulWad(a, weightA) + mulWad(b, weightB)), totalWeight);
    }

    function convertDecimals(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return amount;
        if (fromDecimals < toDecimals) return amount * (10 ** (toDecimals - fromDecimals));
        return amount / (10 ** (fromDecimals - toDecimals));
    }

    function normalizeToWad(uint256 amount, uint8 decimals_) internal pure returns (uint256) {
        return convertDecimals(amount, decimals_, 18);
    }

    function denormalizeFromWad(uint256 amount, uint8 decimals_) internal pure returns (uint256) {
        return convertDecimals(amount, 18, decimals_);
    }

    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert DivisionByZero();
        if (a == 0) return 0;
        return ((a - 1) / b) + 1;
    }

    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function withinTolerance(uint256 a, uint256 b, uint256 tolerance) internal pure returns (bool) {
        return absDiff(a, b) <= tolerance;
    }

    function safeCastTo128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, "CAST_128");
        return uint128(value);
    }

    function safeCastTo96(uint256 value) internal pure returns (uint96) {
        require(value <= type(uint96).max, "CAST_96");
        return uint96(value);
    }

    function safeCastTo64(uint256 value) internal pure returns (uint64) {
        require(value <= type(uint64).max, "CAST_64");
        return uint64(value);
    }

    function nonZero(uint256 value, string memory reason) internal pure returns (uint256) {
        require(value != 0, reason);
        return value;
    }
}
