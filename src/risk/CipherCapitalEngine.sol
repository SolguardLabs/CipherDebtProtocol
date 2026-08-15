// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FixedPointMath } from "../libraries/FixedPointMath.sol";

/// @notice Deterministic capital and liquidity stress model for Cipher debt markets.
contract CipherCapitalEngine {
    using FixedPointMath for uint256;

    uint256 public constant WAD = 1e18;

    struct MarketInput {
        uint256 marketId;
        uint256 suppliedLiquidity;
        uint256 totalDebt;
        uint256 reserveBalance;
        uint256 collateralValue;
        uint256 debtValue;
        uint256 liquidationThresholdWad;
        uint256 collateralShockWad;
        uint256 debtShockWad;
        uint256 liquidationCostWad;
        uint256 liquidityHaircutWad;
        uint256 maturitySeconds;
    }

    struct RiskPolicy {
        uint256 targetCoverageWad;
        uint256 operationalBuffer;
        uint256 minimumLiquidLiquidity;
        uint256 maximumMarketShareWad;
        uint256 maximumHhiWad;
    }

    struct MarketAssessment {
        uint256 marketId;
        uint256 stressedCollateralValue;
        uint256 stressedDebtValue;
        uint256 liquidationProceeds;
        uint256 liquidLiquidity;
        uint256 availableCapital;
        uint256 requiredCapital;
        uint256 surplus;
        uint256 deficit;
        uint256 coverageWad;
        uint256 utilizationWad;
        bool liquid;
        bool covered;
    }

    struct PortfolioAssessment {
        uint256 markets;
        uint256 totalStressedDebt;
        uint256 totalAvailableCapital;
        uint256 totalRequiredCapital;
        uint256 totalSurplus;
        uint256 totalDeficit;
        uint256 largestMarketId;
        uint256 largestMarketShareWad;
        uint256 debtHhiWad;
        uint256 debtWeightedMaturitySeconds;
        uint256 coverageWad;
        bool concentrationCompliant;
        bool capitalCompliant;
    }

    error EmptyPortfolio();
    error InvalidPolicy();
    error InvalidRatio(uint256 value);

    function assessMarket(
        MarketInput memory input,
        RiskPolicy memory policy
    ) public pure returns (MarketAssessment memory result) {
        _validateInput(input);
        _validatePolicy(policy);

        result.marketId = input.marketId;
        result.stressedCollateralValue = input.collateralValue.mulWad(
            WAD - input.collateralShockWad
        );
        result.stressedDebtValue = input.debtValue.mulWad(WAD + input.debtShockWad);

        uint256 protectedCollateral = result.stressedCollateralValue.mulWad(
            input.liquidationThresholdWad
        );
        result.liquidationProceeds = protectedCollateral.mulWad(WAD - input.liquidationCostWad);

        uint256 grossLiquidity = input.suppliedLiquidity > input.totalDebt + input.reserveBalance
            ? input.suppliedLiquidity - input.totalDebt - input.reserveBalance
            : 0;
        result.liquidLiquidity = grossLiquidity.mulWad(WAD - input.liquidityHaircutWad);
        result.availableCapital =
            result.liquidationProceeds +
            result.liquidLiquidity +
            input.reserveBalance;
        result.requiredCapital =
            result.stressedDebtValue.mulWadUp(policy.targetCoverageWad) +
            policy.operationalBuffer;

        if (result.availableCapital >= result.requiredCapital) {
            result.surplus = result.availableCapital - result.requiredCapital;
        } else {
            result.deficit = result.requiredCapital - result.availableCapital;
        }

        result.coverageWad = result.requiredCapital == 0
            ? type(uint256).max
            : result.availableCapital.divWad(result.requiredCapital);
        result.utilizationWad = input.suppliedLiquidity == 0
            ? 0
            : input.totalDebt.divWad(input.suppliedLiquidity);
        result.liquid = result.liquidLiquidity >= policy.minimumLiquidLiquidity;
        result.covered = result.deficit == 0;
    }

    function assessPortfolio(
        MarketInput[] memory inputs,
        RiskPolicy memory policy
    ) external pure returns (PortfolioAssessment memory result) {
        if (inputs.length == 0) revert EmptyPortfolio();
        _validatePolicy(policy);
        result.markets = inputs.length;

        uint256 weightedMaturity;
        uint256 largestDebt;
        for (uint256 i = 0; i < inputs.length; i++) {
            MarketAssessment memory market = assessMarket(inputs[i], policy);
            result.totalStressedDebt += market.stressedDebtValue;
            result.totalAvailableCapital += market.availableCapital;
            result.totalRequiredCapital += market.requiredCapital;
            result.totalSurplus += market.surplus;
            result.totalDeficit += market.deficit;
            weightedMaturity += market.stressedDebtValue * inputs[i].maturitySeconds;
            if (market.stressedDebtValue > largestDebt) {
                largestDebt = market.stressedDebtValue;
                result.largestMarketId = market.marketId;
            }
        }

        if (result.totalStressedDebt != 0) {
            result.largestMarketShareWad = largestDebt.divWad(result.totalStressedDebt);
            result.debtWeightedMaturitySeconds = weightedMaturity / result.totalStressedDebt;
            for (uint256 i = 0; i < inputs.length; i++) {
                uint256 stressedDebt = inputs[i].debtValue.mulWad(WAD + inputs[i].debtShockWad);
                uint256 share = stressedDebt.divWad(result.totalStressedDebt);
                result.debtHhiWad += share.mulWad(share);
            }
        }

        result.coverageWad = result.totalRequiredCapital == 0
            ? type(uint256).max
            : result.totalAvailableCapital.divWad(result.totalRequiredCapital);
        result.concentrationCompliant =
            result.largestMarketShareWad <= policy.maximumMarketShareWad &&
            result.debtHhiWad <= policy.maximumHhiWad;
        result.capitalCompliant = result.totalDeficit == 0;
    }

    function portfolioDigest(
        MarketInput[] memory inputs,
        RiskPolicy memory policy
    ) external pure returns (bytes32) {
        if (inputs.length == 0) revert EmptyPortfolio();
        _validatePolicy(policy);
        return keccak256(abi.encode(keccak256("CIPHER_CAPITAL_V1"), inputs, policy));
    }

    function _validateInput(MarketInput memory input) internal pure {
        _validateRatio(input.liquidationThresholdWad);
        _validateRatio(input.collateralShockWad);
        _validateRatio(input.debtShockWad);
        _validateRatio(input.liquidationCostWad);
        _validateRatio(input.liquidityHaircutWad);
    }

    function _validatePolicy(RiskPolicy memory policy) internal pure {
        if (policy.targetCoverageWad < WAD) revert InvalidPolicy();
        if (policy.maximumMarketShareWad == 0 || policy.maximumMarketShareWad > WAD) {
            revert InvalidPolicy();
        }
        if (policy.maximumHhiWad == 0 || policy.maximumHhiWad > WAD) {
            revert InvalidPolicy();
        }
    }

    function _validateRatio(uint256 value) internal pure {
        if (value > WAD) revert InvalidRatio(value);
    }
}
