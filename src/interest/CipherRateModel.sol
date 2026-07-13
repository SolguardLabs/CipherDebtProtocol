// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IRateModel } from "../interfaces/IRateModel.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";

contract CipherRateModel is IRateModel {
    using FixedPointMath for uint256;

    uint256 public constant WAD = 1e18;
    uint256 public constant MAX_RATE_PER_SECOND = 0.0002e18;
    uint256 public constant DEFAULT_OPTIMAL_UTILIZATION = 0.8e18;

    struct Curve {
        uint256 baseRatePerSecond;
        uint256 slopeOnePerSecond;
        uint256 slopeTwoPerSecond;
        uint256 optimalUtilization;
        uint256 reserveFactor;
        string label;
    }

    struct RateQuote {
        uint256 utilizationWad;
        uint256 borrowRatePerSecond;
        uint256 supplyRatePerSecond;
        uint256 borrowApr;
        uint256 supplyApr;
        uint256 reserveRatePerSecond;
        uint8 utilizationBand;
    }

    Curve public conservativeCurve;
    Curve public balancedCurve;
    Curve public growthCurve;

    event CurveUpdated(bytes32 indexed curveId, Curve curve);

    error InvalidCurve();

    constructor() {
        conservativeCurve = Curve({
            baseRatePerSecond: 317_097_919,
            slopeOnePerSecond: 634_195_839,
            slopeTwoPerSecond: 6_341_958_396,
            optimalUtilization: 0.75e18,
            reserveFactor: 0.12e18,
            label: "conservative"
        });
        balancedCurve = Curve({
            baseRatePerSecond: 475_646_879,
            slopeOnePerSecond: 1_268_391_679,
            slopeTwoPerSecond: 12_683_916_793,
            optimalUtilization: 0.8e18,
            reserveFactor: 0.1e18,
            label: "balanced"
        });
        growthCurve = Curve({
            baseRatePerSecond: 792_744_799,
            slopeOnePerSecond: 2_536_783_358,
            slopeTwoPerSecond: 25_367_833_587,
            optimalUtilization: 0.85e18,
            reserveFactor: 0.08e18,
            label: "growth"
        });
    }

    function borrowRatePerSecond(RateState calldata state) external pure returns (uint256) {
        uint256 util = utilization(state);
        Curve memory curve = Curve({
            baseRatePerSecond: state.baseRatePerSecond,
            slopeOnePerSecond: state.slopeOnePerSecond,
            slopeTwoPerSecond: state.slopeTwoPerSecond,
            optimalUtilization: state.optimalUtilization == 0
                ? DEFAULT_OPTIMAL_UTILIZATION
                : state.optimalUtilization,
            reserveFactor: 0,
            label: ""
        });
        return _borrowRate(curve, util);
    }

    function utilization(RateState calldata state) public pure returns (uint256) {
        uint256 cash = state.suppliedLiquidity > state.reserveBalance
            ? state.suppliedLiquidity - state.reserveBalance
            : 0;
        uint256 denominator = cash + state.totalDebt;
        if (denominator == 0) return 0;
        return FixedPointMath.divWad(state.totalDebt, denominator);
    }

    function quoteConservative(
        uint256 suppliedLiquidity,
        uint256 totalDebt
    ) external view returns (RateQuote memory) {
        return quote(conservativeCurve, suppliedLiquidity, totalDebt, 0);
    }

    function quoteBalanced(
        uint256 suppliedLiquidity,
        uint256 totalDebt
    ) external view returns (RateQuote memory) {
        return quote(balancedCurve, suppliedLiquidity, totalDebt, 0);
    }

    function quoteGrowth(
        uint256 suppliedLiquidity,
        uint256 totalDebt
    ) external view returns (RateQuote memory) {
        return quote(growthCurve, suppliedLiquidity, totalDebt, 0);
    }

    function quote(
        Curve memory curve,
        uint256 suppliedLiquidity,
        uint256 totalDebt,
        uint256 reserves
    ) public pure returns (RateQuote memory rate) {
        _validateCurve(curve);
        uint256 cash = suppliedLiquidity > reserves ? suppliedLiquidity - reserves : 0;
        uint256 denominator = cash + totalDebt;
        uint256 util = denominator == 0 ? 0 : FixedPointMath.divWad(totalDebt, denominator);
        uint256 borrowRate = _borrowRate(curve, util);
        uint256 reserveRate = FixedPointMath.mulWad(borrowRate, curve.reserveFactor);
        uint256 netBorrowRate = borrowRate - reserveRate;
        uint256 supplyRate = FixedPointMath.mulWad(netBorrowRate, util);
        rate.utilizationWad = util;
        rate.borrowRatePerSecond = borrowRate;
        rate.supplyRatePerSecond = supplyRate;
        rate.borrowApr = FixedPointMath.annualize(borrowRate);
        rate.supplyApr = FixedPointMath.annualize(supplyRate);
        rate.reserveRatePerSecond = reserveRate;
        rate.utilizationBand = utilizationBand(util);
    }

    function projectIndex(
        uint256 currentIndex,
        uint256 ratePerSecond,
        uint256 elapsed
    ) external pure returns (uint256) {
        require(currentIndex >= WAD, "INDEX");
        require(ratePerSecond <= MAX_RATE_PER_SECOND, "RATE");
        return FixedPointMath.linearGrowth(currentIndex, ratePerSecond, elapsed);
    }

    function projectDebt(
        uint256 principal,
        uint256 positionIndex,
        uint256 marketIndex
    ) external pure returns (uint256) {
        if (principal == 0) return 0;
        uint256 snapshot = positionIndex == 0 ? WAD : positionIndex;
        return (principal * marketIndex) / snapshot;
    }

    function utilizationBand(uint256 util) public pure returns (uint8) {
        if (util < 0.25e18) return 0;
        if (util < 0.5e18) return 1;
        if (util < 0.75e18) return 2;
        if (util < 0.9e18) return 3;
        if (util < 0.97e18) return 4;
        return 5;
    }

    function recommendedCurve(
        uint256 collateralVolatility,
        uint256 liquidityDepth,
        uint256 utilizationTarget
    ) external pure returns (bytes32 curveId) {
        if (collateralVolatility > 0.35e18 || liquidityDepth < 100_000e18) {
            return keccak256("conservative");
        }
        if (utilizationTarget > 0.82e18) {
            return keccak256("growth");
        }
        return keccak256("balanced");
    }

    function utilizationAfterBorrow(
        uint256 suppliedLiquidity,
        uint256 totalDebt,
        uint256 borrowAmount
    ) external pure returns (uint256) {
        uint256 nextDebt = totalDebt + borrowAmount;
        uint256 denominator = suppliedLiquidity + nextDebt;
        if (denominator == 0) return 0;
        return FixedPointMath.divWad(nextDebt, denominator);
    }

    function utilizationAfterRepay(
        uint256 suppliedLiquidity,
        uint256 totalDebt,
        uint256 repayAmount
    ) external pure returns (uint256) {
        uint256 nextDebt = repayAmount > totalDebt ? 0 : totalDebt - repayAmount;
        uint256 denominator = suppliedLiquidity + nextDebt;
        if (denominator == 0) return 0;
        return FixedPointMath.divWad(nextDebt, denominator);
    }

    function borrowCost(
        uint256 amount,
        uint256 ratePerSecond,
        uint256 elapsed
    ) external pure returns (uint256) {
        require(ratePerSecond <= MAX_RATE_PER_SECOND, "RATE");
        return FixedPointMath.mulWad(amount, ratePerSecond * elapsed);
    }

    function debtAfterInterval(
        uint256 debt,
        uint256 ratePerSecond,
        uint256 elapsed
    ) external pure returns (uint256) {
        require(ratePerSecond <= MAX_RATE_PER_SECOND, "RATE");
        return FixedPointMath.linearGrowth(debt, ratePerSecond, elapsed);
    }

    function supplyYield(
        uint256 amount,
        uint256 supplyRatePerSecond,
        uint256 elapsed
    ) external pure returns (uint256) {
        require(supplyRatePerSecond <= MAX_RATE_PER_SECOND, "RATE");
        return FixedPointMath.mulWad(amount, supplyRatePerSecond * elapsed);
    }

    function spread(uint256 borrowRate, uint256 supplyRate) external pure returns (uint256) {
        return borrowRate > supplyRate ? borrowRate - supplyRate : 0;
    }

    function reserveShare(uint256 interest, uint256 reserveFactor) external pure returns (uint256) {
        require(reserveFactor <= 0.5e18, "RESERVE");
        return FixedPointMath.mulWad(interest, reserveFactor);
    }

    function _borrowRate(Curve memory curve, uint256 util) internal pure returns (uint256) {
        _validateCurve(curve);
        if (util <= curve.optimalUtilization) {
            uint256 slopeShare = FixedPointMath.divWad(util, curve.optimalUtilization);
            return
                curve.baseRatePerSecond +
                FixedPointMath.mulWad(curve.slopeOnePerSecond, slopeShare);
        }
        uint256 excess = util - curve.optimalUtilization;
        uint256 excessDenominator = WAD - curve.optimalUtilization;
        uint256 excessShare = FixedPointMath.divWad(excess, excessDenominator);
        return
            curve.baseRatePerSecond +
            curve.slopeOnePerSecond +
            FixedPointMath.mulWad(curve.slopeTwoPerSecond, excessShare);
    }

    function _validateCurve(Curve memory curve) internal pure {
        if (curve.optimalUtilization == 0 || curve.optimalUtilization >= WAD) revert InvalidCurve();
        if (curve.baseRatePerSecond > MAX_RATE_PER_SECOND) revert InvalidCurve();
        if (curve.slopeOnePerSecond > MAX_RATE_PER_SECOND) revert InvalidCurve();
        if (curve.slopeTwoPerSecond > MAX_RATE_PER_SECOND) revert InvalidCurve();
        if (curve.reserveFactor > 0.5e18) revert InvalidCurve();
    }
}
