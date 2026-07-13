// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FixedPointMath } from "./FixedPointMath.sol";

library DebtAccounting {
    using FixedPointMath for uint256;

    uint256 internal constant WAD = 1e18;

    struct DebtPosition {
        uint256 principal;
        uint256 indexSnapshot;
        uint256 openedAt;
        uint256 updatedAt;
    }

    struct DebtChange {
        uint256 previousDebt;
        uint256 nextDebt;
        uint256 principalWritten;
        uint256 indexWritten;
        uint256 delta;
        bool increased;
    }

    function isEmpty(DebtPosition storage position) internal view returns (bool) {
        return position.principal == 0;
    }

    function currentDebt(
        DebtPosition storage position,
        uint256 marketIndex
    ) internal view returns (uint256) {
        if (position.principal == 0) return 0;
        uint256 snapshot = position.indexSnapshot == 0 ? WAD : position.indexSnapshot;
        return (position.principal * marketIndex) / snapshot;
    }

    function previewDebt(
        uint256 principal,
        uint256 snapshot,
        uint256 marketIndex
    ) internal pure returns (uint256) {
        if (principal == 0) return 0;
        uint256 storedIndex = snapshot == 0 ? WAD : snapshot;
        return (principal * marketIndex) / storedIndex;
    }

    function checkpoint(
        DebtPosition storage position,
        uint256 debt,
        uint256 marketIndex
    ) internal returns (DebtChange memory change) {
        uint256 previous = currentDebt(position, marketIndex);
        position.principal = debt;
        position.indexSnapshot = marketIndex;
        if (position.openedAt == 0 && debt != 0) {
            position.openedAt = block.timestamp;
        }
        position.updatedAt = block.timestamp;
        change.previousDebt = previous;
        change.nextDebt = debt;
        change.principalWritten = debt;
        change.indexWritten = marketIndex;
        change.delta = previous > debt ? previous - debt : debt - previous;
        change.increased = debt >= previous;
    }

    function increase(
        DebtPosition storage position,
        uint256 amount,
        uint256 marketIndex
    ) internal returns (DebtChange memory change) {
        uint256 current = currentDebt(position, marketIndex);
        return checkpoint(position, current + amount, marketIndex);
    }

    function decrease(
        DebtPosition storage position,
        uint256 amount,
        uint256 marketIndex
    ) internal returns (DebtChange memory change) {
        uint256 current = currentDebt(position, marketIndex);
        uint256 paid = amount > current ? current : amount;
        return checkpoint(position, current - paid, marketIndex);
    }

    function close(
        DebtPosition storage position,
        uint256 marketIndex
    ) internal returns (DebtChange memory change) {
        uint256 current = currentDebt(position, marketIndex);
        position.principal = 0;
        position.indexSnapshot = marketIndex;
        position.updatedAt = block.timestamp;
        change.previousDebt = current;
        change.nextDebt = 0;
        change.principalWritten = 0;
        change.indexWritten = marketIndex;
        change.delta = current;
        change.increased = false;
    }

    function rewriteFromQuote(
        DebtPosition storage position,
        uint256 amount,
        uint256 marketIndex,
        uint256 quoteIndex
    ) internal returns (DebtChange memory change) {
        uint256 current = currentDebt(position, marketIndex);
        uint256 quotedAmount = quoteIndex == marketIndex
            ? amount
            : FixedPointMath.mulWad(amount, FixedPointMath.divWad(quoteIndex, marketIndex));
        return checkpoint(position, current + quotedAmount, marketIndex);
    }

    function paymentToClose(
        DebtPosition storage position,
        uint256 marketIndex
    ) internal view returns (uint256) {
        return currentDebt(position, marketIndex);
    }

    function utilization(
        uint256 totalDebt,
        uint256 availableLiquidity
    ) internal pure returns (uint256) {
        uint256 denominator = totalDebt + availableLiquidity;
        if (denominator == 0) return 0;
        return FixedPointMath.divWad(totalDebt, denominator);
    }

    function accrueIndex(
        uint256 index,
        uint256 ratePerSecond,
        uint256 elapsed
    ) internal pure returns (uint256) {
        return FixedPointMath.linearGrowth(index, ratePerSecond, elapsed);
    }

    function accrueDebt(
        uint256 totalDebt,
        uint256 oldIndex,
        uint256 newIndex
    ) internal pure returns (uint256 interest, uint256 nextTotal) {
        if (totalDebt == 0 || newIndex <= oldIndex) return (0, totalDebt);
        nextTotal = (totalDebt * newIndex) / oldIndex;
        interest = nextTotal - totalDebt;
    }

    function quotePrincipalAtIndex(
        uint256 currentDebt_,
        uint256 fromIndex,
        uint256 toIndex
    ) internal pure returns (uint256) {
        if (currentDebt_ == 0) return 0;
        if (toIndex == 0) return currentDebt_;
        return (currentDebt_ * fromIndex) / toIndex;
    }

    function wouldDust(uint256 debt, uint256 minDebt) internal pure returns (bool) {
        return debt != 0 && debt < minDebt;
    }

    function maxRepayable(uint256 requested, uint256 debt) internal pure returns (uint256) {
        return requested > debt ? debt : requested;
    }

    function maxBorrowableByCap(
        uint256 currentTotalDebt,
        uint256 borrowCap
    ) internal pure returns (uint256) {
        if (borrowCap == 0) return type(uint256).max;
        if (currentTotalDebt >= borrowCap) return 0;
        return borrowCap - currentTotalDebt;
    }

    function maxSuppliableByCap(
        uint256 currentSupply,
        uint256 supplyCap
    ) internal pure returns (uint256) {
        if (supplyCap == 0) return type(uint256).max;
        if (currentSupply >= supplyCap) return 0;
        return supplyCap - currentSupply;
    }
}
