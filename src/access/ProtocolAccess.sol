// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract ProtocolAccess {
    bytes32 public constant MARKET_ADMIN_ROLE = keccak256("MARKET_ADMIN_ROLE");
    bytes32 public constant RISK_ADMIN_ROLE = keccak256("RISK_ADMIN_ROLE");
    bytes32 public constant ORACLE_ADMIN_ROLE = keccak256("ORACLE_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant MIGRATOR_ROLE = keccak256("MIGRATOR_ROLE");

    address public owner;
    address public pendingOwner;

    mapping(bytes32 => mapping(address => bool)) private _roles;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    error NotOwner();
    error NotPendingOwner();
    error MissingRole(bytes32 role, address account);
    error ZeroAddress();

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
        _grantRole(MARKET_ADMIN_ROLE, initialOwner);
        _grantRole(RISK_ADMIN_ROLE, initialOwner);
        _grantRole(ORACLE_ADMIN_ROLE, initialOwner);
        _grantRole(PAUSER_ROLE, initialOwner);
        _grantRole(TREASURY_ROLE, initialOwner);
        _grantRole(MIGRATOR_ROLE, initialOwner);
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    modifier onlyRole(bytes32 role) {
        _checkRole(role, msg.sender);
        _;
    }

    function transferOwnership(address nextOwner) external onlyOwner {
        if (nextOwner == address(0)) revert ZeroAddress();
        pendingOwner = nextOwner;
        emit OwnershipTransferStarted(owner, nextOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        _grantRole(MARKET_ADMIN_ROLE, msg.sender);
        _grantRole(RISK_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(TREASURY_ROLE, msg.sender);
        emit OwnershipTransferred(previous, msg.sender);
    }

    function grantRole(bytes32 role, address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyOwner {
        if (_roles[role][account]) {
            _roles[role][account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }

    function renounceRole(bytes32 role) external {
        if (_roles[role][msg.sender]) {
            _roles[role][msg.sender] = false;
            emit RoleRevoked(role, msg.sender, msg.sender);
        }
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    function _checkOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

    function _checkRole(bytes32 role, address account) internal view {
        if (!_roles[role][account]) revert MissingRole(role, account);
    }

    function _grantRole(bytes32 role, address account) internal {
        if (!_roles[role][account]) {
            _roles[role][account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }
}
