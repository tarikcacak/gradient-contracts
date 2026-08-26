// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {TokenFactory} from "../src/TokenFactory.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MockWETH, MockUniFactory, MockRouter, MockPair} from "./mocks/MockUniswap.sol";

abstract contract BaseTest is Test {
    BondingCurve internal curve;
    TokenFactory internal factory;
    MockWETH internal weth;
    MockUniFactory internal uniFactory;
    MockRouter internal router;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant V_ETH_START = 0.125 ether;
    uint256 internal constant CREATE_FEE = 0.0001 ether;

    function setUp() public virtual {
        weth = new MockWETH();
        uniFactory = new MockUniFactory();
        router = new MockRouter(address(uniFactory), address(weth));

        curve = new BondingCurve(owner, treasury, address(router), V_ETH_START);
        factory = new TokenFactory(owner, address(curve), CREATE_FEE);

        vm.prank(owner);
        curve.setFactory(address(factory));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    function _create(address creator) internal returns (address token) {
        return _create(creator, 0);
    }

    function _create(address creator, uint256 initialBuy) internal returns (address token) {
        vm.prank(creator);
        token = factory.createToken{value: CREATE_FEE + initialBuy}("Test Token", "TEST", "ipfs://meta");
    }

    function _buy(address who, address token, uint256 value) internal returns (uint256 out) {
        vm.prank(who);
        out = curve.buy{value: value}(token, 0, block.timestamp);
    }

    function _sell(address who, address token, uint256 amount) internal returns (uint256 ethOut) {
        vm.startPrank(who);
        LaunchToken(token).approve(address(curve), amount);
        ethOut = curve.sell(token, amount, 0, block.timestamp);
        vm.stopPrank();
    }

    function _graduate(address who, address token) internal {
        vm.prank(who);
        curve.buy{value: 5 ether}(token, 0, block.timestamp);
    }

    function _state(address token)
        internal
        view
        returns (uint256 vEth, uint256 vTok, uint256 realEth, BondingCurve.Status status)
    {
        (vEth, vTok, realEth,,, status) = curve.states(token);
    }
}
