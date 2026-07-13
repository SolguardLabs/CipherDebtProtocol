// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library OrderHash {
    bytes32 internal constant MIGRATION_TYPEHASH =
        keccak256(
            "MigrationOrder(address borrower,uint256 sourceMarketId,uint256 destinationMarketId,uint256 debtAmount,uint256 collateralAmount,uint256 destinationIndexSnapshot,uint256 minHealthFactor,uint256 deadline,uint256 nonce)"
        );

    struct MigrationOrder {
        address borrower;
        uint256 sourceMarketId;
        uint256 destinationMarketId;
        uint256 debtAmount;
        uint256 collateralAmount;
        uint256 destinationIndexSnapshot;
        uint256 minHealthFactor;
        uint256 deadline;
        uint256 nonce;
    }

    function hash(MigrationOrder memory order) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    MIGRATION_TYPEHASH,
                    order.borrower,
                    order.sourceMarketId,
                    order.destinationMarketId,
                    order.debtAmount,
                    order.collateralAmount,
                    order.destinationIndexSnapshot,
                    order.minHealthFactor,
                    order.deadline,
                    order.nonce
                )
            );
    }

    function actionId(
        MigrationOrder memory order,
        address protocol
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(protocol, hash(order)));
    }

    function validate(MigrationOrder memory order) internal view {
        require(order.borrower != address(0), "BORROWER");
        require(order.sourceMarketId != order.destinationMarketId, "SAME_MARKET");
        require(order.debtAmount != 0 || order.collateralAmount != 0, "EMPTY_ORDER");
        require(order.destinationIndexSnapshot != 0, "SNAPSHOT");
        require(block.timestamp <= order.deadline, "DEADLINE");
    }
}
