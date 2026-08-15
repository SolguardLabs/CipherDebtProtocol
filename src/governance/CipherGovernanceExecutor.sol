// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Quorum timelock with canonical operation identities and predecessor ordering.
contract CipherGovernanceExecutor {
    bytes32 public constant OPERATION_DOMAIN = keccak256("CIPHER_GOVERNANCE_OPERATION_V1");

    struct Operation {
        address target;
        uint256 value;
        bytes32 dataHash;
        bytes32 predecessor;
        uint64 eta;
        uint64 expiresAt;
        uint32 approvals;
        bool executed;
        bool cancelled;
    }

    bytes32 public immutable protocolDomain;
    address public guardian;
    uint64 public minimumDelay;
    uint64 public gracePeriod;
    uint32 public quorum;
    uint32 public activeGovernorCount;

    mapping(address => bool) public isGovernor;
    mapping(bytes32 => Operation) private _operations;
    mapping(bytes32 => mapping(address => bool)) public approvedBy;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidSchedule();
    error OperationExists();
    error OperationMissing();
    error AlreadyApproved();
    error InsufficientApprovals(uint256 actual, uint256 required);
    error NotReady();
    error Expired();
    error PredecessorIncomplete();
    error TerminalOperation();
    error CallFailed(bytes result);

    event OperationScheduled(
        bytes32 indexed operationId,
        address indexed proposer,
        address indexed target,
        uint256 value,
        bytes32 dataHash,
        bytes32 predecessor,
        uint64 eta,
        uint64 expiresAt
    );
    event OperationApproved(
        bytes32 indexed operationId,
        address indexed governor,
        uint32 approvals
    );
    event OperationCancelled(bytes32 indexed operationId, address indexed caller);
    event OperationExecuted(bytes32 indexed operationId, address indexed executor, bytes result);
    event GovernorUpdated(address indexed governor, bool active);
    event GuardianUpdated(address indexed previousGuardian, address indexed nextGuardian);
    event PolicyUpdated(uint64 minimumDelay, uint64 gracePeriod, uint32 quorum);

    constructor(
        bytes32 protocolDomain_,
        address[] memory governors,
        address guardian_,
        uint32 quorum_,
        uint64 minimumDelay_,
        uint64 gracePeriod_
    ) {
        if (protocolDomain_ == bytes32(0) || guardian_ == address(0)) {
            revert InvalidConfiguration();
        }
        protocolDomain = protocolDomain_;
        guardian = guardian_;
        minimumDelay = minimumDelay_;
        gracePeriod = gracePeriod_;

        for (uint256 i = 0; i < governors.length; i++) {
            address governor = governors[i];
            if (governor == address(0) || isGovernor[governor]) revert InvalidConfiguration();
            isGovernor[governor] = true;
            activeGovernorCount += 1;
            emit GovernorUpdated(governor, true);
        }
        _validateQuorum(quorum_, activeGovernorCount, gracePeriod_);
        quorum = quorum_;
        emit PolicyUpdated(minimumDelay_, gracePeriod_, quorum_);
    }

    receive() external payable {}

    modifier onlyGovernor() {
        if (!isGovernor[msg.sender]) revert Unauthorized();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert Unauthorized();
        _;
    }

    function operationId(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint64 eta,
        uint64 expiresAt
    ) public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    OPERATION_DOMAIN,
                    protocolDomain,
                    block.chainid,
                    address(this),
                    target,
                    value,
                    keccak256(data),
                    predecessor,
                    salt,
                    eta,
                    expiresAt
                )
            );
    }

    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint64 eta
    ) external onlyGovernor returns (bytes32 id) {
        if (target == address(0) || eta < block.timestamp + minimumDelay) {
            revert InvalidSchedule();
        }
        uint64 expiresAt = eta + gracePeriod;
        id = operationId(target, value, data, predecessor, salt, eta, expiresAt);
        if (_operations[id].target != address(0)) revert OperationExists();

        _operations[id] = Operation({
            target: target,
            value: value,
            dataHash: keccak256(data),
            predecessor: predecessor,
            eta: eta,
            expiresAt: expiresAt,
            approvals: 1,
            executed: false,
            cancelled: false
        });
        approvedBy[id][msg.sender] = true;
        emit OperationScheduled(
            id,
            msg.sender,
            target,
            value,
            keccak256(data),
            predecessor,
            eta,
            expiresAt
        );
        emit OperationApproved(id, msg.sender, 1);
    }

    function approve(bytes32 id) external onlyGovernor {
        Operation storage operation = _operation(id);
        _requireOpen(operation);
        if (approvedBy[id][msg.sender]) revert AlreadyApproved();
        approvedBy[id][msg.sender] = true;
        operation.approvals += 1;
        emit OperationApproved(id, msg.sender, operation.approvals);
    }

    function cancel(bytes32 id) external {
        if (msg.sender != guardian && !isGovernor[msg.sender]) revert Unauthorized();
        Operation storage operation = _operation(id);
        _requireOpen(operation);
        operation.cancelled = true;
        emit OperationCancelled(id, msg.sender);
    }

    function execute(
        bytes32 id,
        bytes calldata data
    ) external payable returns (bytes memory result) {
        Operation storage operation = _operation(id);
        _requireOpen(operation);
        if (operation.approvals < quorum) {
            revert InsufficientApprovals(operation.approvals, quorum);
        }
        if (block.timestamp < operation.eta) revert NotReady();
        if (block.timestamp > operation.expiresAt) revert Expired();
        if (operation.predecessor != bytes32(0) && !_operations[operation.predecessor].executed)
            revert PredecessorIncomplete();
        if (keccak256(data) != operation.dataHash || msg.value != operation.value) {
            revert InvalidSchedule();
        }

        operation.executed = true;
        (bool success, bytes memory returnData) = operation.target.call{ value: operation.value }(
            data
        );
        if (!success) revert CallFailed(returnData);
        emit OperationExecuted(id, msg.sender, returnData);
        return returnData;
    }

    function setGovernor(address governor, bool active) external onlySelf {
        if (governor == address(0) || isGovernor[governor] == active) {
            revert InvalidConfiguration();
        }
        uint32 nextCount = active ? activeGovernorCount + 1 : activeGovernorCount - 1;
        _validateQuorum(quorum, nextCount, gracePeriod);
        activeGovernorCount = nextCount;
        isGovernor[governor] = active;
        emit GovernorUpdated(governor, active);
    }

    function setGuardian(address nextGuardian) external onlySelf {
        if (nextGuardian == address(0)) revert InvalidConfiguration();
        address previous = guardian;
        guardian = nextGuardian;
        emit GuardianUpdated(previous, nextGuardian);
    }

    function setPolicy(
        uint64 nextMinimumDelay,
        uint64 nextGracePeriod,
        uint32 nextQuorum
    ) external onlySelf {
        _validateQuorum(nextQuorum, activeGovernorCount, nextGracePeriod);
        minimumDelay = nextMinimumDelay;
        gracePeriod = nextGracePeriod;
        quorum = nextQuorum;
        emit PolicyUpdated(nextMinimumDelay, nextGracePeriod, nextQuorum);
    }

    function getOperation(bytes32 id) external view returns (Operation memory) {
        return _operation(id);
    }

    function state(bytes32 id) external view returns (uint8) {
        Operation memory operation_ = _operations[id];
        if (operation_.target == address(0)) return 0;
        if (operation_.cancelled) return 5;
        if (operation_.executed) return 4;
        if (block.timestamp > operation_.expiresAt) return 6;
        if (operation_.approvals < quorum) return 1;
        if (block.timestamp < operation_.eta) return 2;
        return 3;
    }

    function _operation(bytes32 id) internal view returns (Operation storage operation_) {
        operation_ = _operations[id];
        if (operation_.target == address(0)) revert OperationMissing();
    }

    function _requireOpen(Operation storage operation_) internal view {
        if (operation_.executed || operation_.cancelled) revert TerminalOperation();
        if (block.timestamp > operation_.expiresAt) revert Expired();
    }

    function _validateQuorum(
        uint32 quorum_,
        uint32 governorCount,
        uint64 gracePeriod_
    ) internal pure {
        if (quorum_ == 0 || quorum_ > governorCount || gracePeriod_ == 0) {
            revert InvalidConfiguration();
        }
    }
}
