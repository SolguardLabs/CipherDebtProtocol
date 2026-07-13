// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ProtocolAccess } from "../access/ProtocolAccess.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";

contract CipherTreasury is ProtocolAccess {
    using SafeTransferLib for IERC20;

    struct AssetPolicy {
        bool accepted;
        uint256 dailyOutflowLimit;
        uint256 minimumRetainedBalance;
        address preferredReceiver;
        string accountingUnit;
    }

    struct OutflowState {
        uint256 windowStart;
        uint256 spentInWindow;
    }

    struct Payment {
        address asset;
        address receiver;
        uint256 amount;
        bytes32 paymentRef;
    }

    mapping(address => AssetPolicy) private _policies;
    mapping(address => OutflowState) private _outflows;
    mapping(bytes32 => bool) public paidReferences;

    event AssetPolicyUpdated(address indexed asset, AssetPolicy policy);
    event PaymentExecuted(
        address indexed asset,
        address indexed receiver,
        uint256 amount,
        bytes32 paymentRef
    );
    event Swept(address indexed asset, address indexed receiver, uint256 amount);

    error AssetNotAccepted();
    error PaymentAlreadyExecuted();
    error DailyLimitExceeded();
    error RetainedBalanceRequired();
    error InvalidPayment();

    constructor(address initialOwner) ProtocolAccess(initialOwner) {}

    receive() external payable {}

    function setAssetPolicy(
        address asset,
        AssetPolicy calldata policy
    ) external onlyRole(TREASURY_ROLE) {
        require(asset != address(0), "ASSET");
        require(bytes(policy.accountingUnit).length != 0, "UNIT");
        _policies[asset] = policy;
        emit AssetPolicyUpdated(asset, policy);
    }

    function policyOf(address asset) external view returns (AssetPolicy memory) {
        return _policies[asset];
    }

    function outflowOf(address asset) external view returns (OutflowState memory) {
        return _outflows[asset];
    }

    function executePayment(Payment calldata payment) external onlyRole(TREASURY_ROLE) {
        _executePayment(payment);
    }

    function executeBatch(Payment[] calldata payments) external onlyRole(TREASURY_ROLE) {
        for (uint256 i = 0; i < payments.length; i++) {
            _executePayment(payments[i]);
        }
    }

    function sweep(
        address asset,
        address receiver,
        uint256 amount
    ) external onlyRole(TREASURY_ROLE) {
        AssetPolicy memory policy = _policies[asset];
        if (!policy.accepted) revert AssetNotAccepted();
        if (receiver == address(0)) receiver = policy.preferredReceiver;
        if (receiver == address(0)) revert InvalidPayment();
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 sweepAmount = amount == 0 ? balance : amount;
        if (balance < sweepAmount + policy.minimumRetainedBalance) revert RetainedBalanceRequired();
        _consumeOutflow(asset, sweepAmount, policy.dailyOutflowLimit);
        IERC20(asset).safeTransfer(receiver, sweepAmount);
        emit Swept(asset, receiver, sweepAmount);
    }

    function canPay(
        address asset,
        uint256 amount
    ) external view returns (bool allowed, string memory reason) {
        AssetPolicy memory policy = _policies[asset];
        if (!policy.accepted) return (false, "asset-not-accepted");
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < amount + policy.minimumRetainedBalance) return (false, "retained-balance");
        OutflowState memory state = _currentOutflow(asset);
        if (
            policy.dailyOutflowLimit != 0 && state.spentInWindow + amount > policy.dailyOutflowLimit
        ) {
            return (false, "daily-limit");
        }
        return (true, "ok");
    }

    function availableToPay(address asset) external view returns (uint256) {
        AssetPolicy memory policy = _policies[asset];
        if (!policy.accepted) return 0;
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance <= policy.minimumRetainedBalance) return 0;
        uint256 balanceRoom = balance - policy.minimumRetainedBalance;
        OutflowState memory state = _currentOutflow(asset);
        if (policy.dailyOutflowLimit == 0) return balanceRoom;
        if (state.spentInWindow >= policy.dailyOutflowLimit) return 0;
        uint256 limitRoom = policy.dailyOutflowLimit - state.spentInWindow;
        return balanceRoom < limitRoom ? balanceRoom : limitRoom;
    }

    function paymentDigest(Payment calldata payment) external pure returns (bytes32) {
        return _paymentDigest(payment);
    }

    function _executePayment(Payment calldata payment) internal {
        if (payment.asset == address(0) || payment.receiver == address(0) || payment.amount == 0) {
            revert InvalidPayment();
        }
        AssetPolicy memory policy = _policies[payment.asset];
        if (!policy.accepted) revert AssetNotAccepted();
        bytes32 digest = _paymentDigest(payment);
        if (paidReferences[digest]) revert PaymentAlreadyExecuted();
        uint256 balance = IERC20(payment.asset).balanceOf(address(this));
        if (balance < payment.amount + policy.minimumRetainedBalance)
            revert RetainedBalanceRequired();
        _consumeOutflow(payment.asset, payment.amount, policy.dailyOutflowLimit);
        paidReferences[digest] = true;
        IERC20(payment.asset).safeTransfer(payment.receiver, payment.amount);
        emit PaymentExecuted(payment.asset, payment.receiver, payment.amount, payment.paymentRef);
    }

    function _consumeOutflow(address asset, uint256 amount, uint256 dailyLimit) internal {
        OutflowState memory state = _currentOutflow(asset);
        if (dailyLimit != 0 && state.spentInWindow + amount > dailyLimit)
            revert DailyLimitExceeded();
        state.spentInWindow += amount;
        _outflows[asset] = state;
    }

    function _currentOutflow(address asset) internal view returns (OutflowState memory state) {
        state = _outflows[asset];
        uint256 currentWindow = (block.timestamp / 1 days) * 1 days;
        if (state.windowStart != currentWindow) {
            state.windowStart = currentWindow;
            state.spentInWindow = 0;
        }
    }

    function _paymentDigest(Payment calldata payment) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(payment.asset, payment.receiver, payment.amount, payment.paymentRef)
            );
    }
}
