// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../../src/interfaces/IExternal.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function approve(address sp, uint256 a) external returns (bool) {
        allowance[msg.sender][sp] = a;
        emit Approval(msg.sender, sp, a);
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) {
            require(al >= a, "allowance");
            allowance[f][msg.sender] = al - a;
        }
        _move(f, to, a);
        return true;
    }

    function _move(address f, address t, uint256 a) internal {
        require(balanceOf[f] >= a, "balance");
        balanceOf[f] -= a;
        balanceOf[t] += a;
        emit Transfer(f, t, a);
    }

    function _mint(address to, uint256 a) internal {
        totalSupply += a;
        balanceOf[to] += a;
        emit Transfer(address(0), to, a);
    }
}

contract MockWETH is MockERC20("Wrapped Ether", "WETH") {
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 a) external {
        require(balanceOf[msg.sender] >= a, "balance");
        balanceOf[msg.sender] -= a;
        totalSupply -= a;
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok, "eth");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract MockPair is MockERC20("Uniswap V2", "UNI-V2") {
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    address public token0;
    address public token1;
    uint112 private r0;
    uint112 private r1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, uint32(block.timestamp));
    }

    function mint(address to) external returns (uint256 liquidity) {
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 a0 = b0 - r0;
        uint256 a1 = b1 - r1;

        if (totalSupply == 0) {
            liquidity = _sqrt(a0 * a1) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            uint256 l0 = (a0 * totalSupply) / r0;
            uint256 l1 = (a1 * totalSupply) / r1;
            liquidity = l0 < l1 ? l0 : l1;
        }
        require(liquidity > 0, "insufficient liquidity minted");
        _mint(to, liquidity);
        r0 = uint112(b0);
        r1 = uint112(b1);
    }

    function skim(address to) external {
        _safeOut(token0, to, IERC20(token0).balanceOf(address(this)) - r0);
        _safeOut(token1, to, IERC20(token1).balanceOf(address(this)) - r1);
    }

    function sync() external {
        r0 = uint112(IERC20(token0).balanceOf(address(this)));
        r1 = uint112(IERC20(token1).balanceOf(address(this)));
    }

    function _safeOut(address t, address to, uint256 a) internal {
        if (a > 0) IERC20(t).transfer(to, a);
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

contract MockUniFactory {
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256);

    function createPair(address a, address b) external returns (address pair) {
        require(a != b, "identical");
        require(getPair[a][b] == address(0), "exists");
        pair = address(new MockPair(a, b));
        getPair[a][b] = pair;
        getPair[b][a] = pair;
        allPairs.push(pair);
        emit PairCreated(a, b, pair, allPairs.length);
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }
}

contract MockRouter {
    address public immutable factory;
    address public immutable WETH;

    constructor(address f, address w) {
        factory = f;
        WETH = w;
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable virtual returns (uint256, uint256, uint256) {
        return _addLiquidityETH(token, amountTokenDesired, amountTokenMin, amountETHMin, to, deadline);
    }

    function _addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) internal returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        require(block.timestamp <= deadline, "expired");

        address pair = MockUniFactory(factory).getPair(token, WETH);
        if (pair == address(0)) pair = MockUniFactory(factory).createPair(token, WETH);

        (uint112 r0, uint112 r1,) = MockPair(pair).getReserves();
        (uint256 rTok, uint256 rEth) = MockPair(pair).token0() == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        if (rTok == 0 && rEth == 0) {
            (amountToken, amountETH) = (amountTokenDesired, msg.value);
        } else {
            uint256 ethOptimal = (amountTokenDesired * rEth) / rTok;
            if (ethOptimal <= msg.value) {
                (amountToken, amountETH) = (amountTokenDesired, ethOptimal);
            } else {
                uint256 tokOptimal = (msg.value * rTok) / rEth;
                (amountToken, amountETH) = (tokOptimal, msg.value);
            }
        }

        require(amountToken >= amountTokenMin, "INSUFFICIENT_A_AMOUNT");
        require(amountETH >= amountETHMin, "INSUFFICIENT_B_AMOUNT");

        IERC20(token).transferFrom(msg.sender, pair, amountToken);
        MockWETH(payable(WETH)).deposit{value: amountETH}();
        IERC20(WETH).transfer(pair, amountETH);
        liquidity = MockPair(pair).mint(to);

        if (msg.value > amountETH) {
            (bool ok,) = msg.sender.call{value: msg.value - amountETH}("");
            require(ok, "refund");
        }
    }
}

contract BreakableRouter is MockRouter {
    bool public broken;

    constructor(address f, address w) MockRouter(f, w) {}

    function setBroken(bool b) external {
        broken = b;
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable override returns (uint256, uint256, uint256) {
        require(!broken, "router down");
        return _addLiquidityETH(token, amountTokenDesired, amountTokenMin, amountETHMin, to, deadline);
    }
}
