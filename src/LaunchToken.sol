// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract LaunchToken {
    string private _name;
    string private _symbol;

    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public curve;

    bool public tradingUnlocked;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event TradingUnlocked();

    error AlreadyInitialized();
    error NotCurve();
    error TradingLocked();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    constructor() {
        curve = address(0xdead);
    }

    function initialize(string calldata name_, string calldata symbol_, address curve_, uint256 supply_) external {
        if (curve != address(0)) revert AlreadyInitialized();
        if (curve_ == address(0)) revert ZeroAddress();

        _name = name_;
        _symbol = symbol_;
        curve = curve_;

        totalSupply = supply_;
        balanceOf[curve_] = supply_;
        emit Transfer(address(0), curve_, supply_);
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function unlockTrading() external {
        if (msg.sender != curve) revert NotCurve();
        tradingUnlocked = true;
        emit TradingUnlocked();
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function burn(uint256 amount) external {
        uint256 bal = balanceOf[msg.sender];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[msg.sender] = bal - amount;
            totalSupply -= amount;
        }
        emit Transfer(msg.sender, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();

        if (!tradingUnlocked && from != curve && msg.sender != curve) revert TradingLocked();

        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
