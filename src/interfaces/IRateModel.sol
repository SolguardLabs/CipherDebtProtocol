// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRateModel {
    struct RateState {
        uint256 suppliedLiquidity;
        uint256 totalDebt;
        uint256 reserveBalance;
        uint256 baseRatePerSecond;
        uint256 slopeOnePerSecond;
        uint256 slopeTwoPerSecond;
        uint256 optimalUtilization;
    }

    function borrowRatePerSecond(RateState calldata state) external pure returns (uint256);
    function utilization(RateState calldata state) external pure returns (uint256);
}
