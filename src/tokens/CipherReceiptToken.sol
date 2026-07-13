// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";

contract CipherReceiptToken is IERC20 {
    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;
    address public immutable protocol;
    uint256 private _totalSupply;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    error OnlyProtocol();
    error InsufficientBalance();
    error InsufficientAllowance();

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address protocol_) {
        require(protocol_ != address(0), "PROTOCOL");
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        protocol = protocol_;
    }

    modifier onlyProtocol() {
        if (msg.sender != protocol) revert OnlyProtocol();
        _;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                _allowances[from][msg.sender] = allowed - amount;
            }
            emit Approval(from, msg.sender, _allowances[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external onlyProtocol {
        require(to != address(0), "TO");
        _totalSupply += amount;
        unchecked {
            _balances[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyProtocol {
        require(from != address(0), "FROM");
        uint256 balance = _balances[from];
        if (balance < amount) revert InsufficientBalance();
        unchecked {
            _balances[from] = balance - amount;
            _totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "TO");
        uint256 balance = _balances[from];
        if (balance < amount) revert InsufficientBalance();
        unchecked {
            _balances[from] = balance - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
