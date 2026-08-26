// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CurveMath} from "../../src/libs/CurveMath.sol";

contract CurveMathHarness {
    function buyQuote(uint256 a, uint256 b, uint256 c) external pure returns (uint256) {
        return CurveMath.buyQuote(a, b, c);
    }

    function sellQuote(uint256 a, uint256 b, uint256 c) external pure returns (uint256) {
        return CurveMath.sellQuote(a, b, c);
    }

    function ethInForExactTokens(uint256 a, uint256 b, uint256 c) external pure returns (uint256) {
        return CurveMath.ethInForExactTokens(a, b, c);
    }

    function spotPriceE18(uint256 a, uint256 b) external pure returns (uint256) {
        return CurveMath.spotPriceE18(a, b);
    }
}

contract CurveMathTest is Test {
    CurveMathHarness internal h;

    uint256 constant V_ETH0 = 0.125 ether;
    uint256 constant V_TOK0 = 1_000_000_000e18;
    uint256 constant SALE = 800_000_000e18;
    uint256 constant LP_RESERVE = 200_000_000e18;

    function setUp() public {
        h = new CurveMathHarness();
    }

    function test_TotalRaiseIsFourTimesVirtualSeed() public view {
        uint256 need = h.ethInForExactTokens(V_ETH0, V_TOK0, SALE);
        assertEq(need, 4 * V_ETH0, "raise != 4x seed");
        assertEq(need, 0.5 ether, "raise != 0.5 ETH");
    }

    function test_PriceRange() public view {
        assertEq(h.spotPriceE18(V_ETH0, V_TOK0), 1.25e8, "open price");

        uint256 vEthEnd = V_ETH0 + 4 * V_ETH0;
        assertEq(h.spotPriceE18(vEthEnd, LP_RESERVE), 3.125e9, "close price");

        assertEq(h.spotPriceE18(vEthEnd, LP_RESERVE) / h.spotPriceE18(V_ETH0, V_TOK0), 25, "multiple");
    }

    function testFuzz_EthInForExactTokensIsInverseOfBuyQuote(uint256 tokensOut) public view {
        tokensOut = bound(tokensOut, 1e18, SALE);

        uint256 ethIn = h.ethInForExactTokens(V_ETH0, V_TOK0, tokensOut);
        uint256 got = h.buyQuote(V_ETH0, V_TOK0, ethIn);

        assertGe(got, tokensOut, "inverse undershot");
        assertLe(got - tokensOut, 1e12, "inverse overshot by more than dust");
    }

    function testFuzz_RoundTripIsNeverProfitable(uint256 ethIn) public view {
        ethIn = bound(ethIn, 1, 0.5 ether);

        uint256 tokensOut = h.buyQuote(V_ETH0, V_TOK0, ethIn);
        vm.assume(tokensOut > 0);

        uint256 vEth1 = V_ETH0 + ethIn;
        uint256 vTok1 = V_TOK0 - tokensOut;

        uint256 ethBack = h.sellQuote(vEth1, vTok1, tokensOut);
        assertLe(ethBack, ethIn, "round trip printed ETH");
    }

    function testFuzz_BuyDoesNotDecreaseK(uint256 vEth, uint256 vTok, uint256 ethIn) public view {
        vEth = bound(vEth, V_ETH0, 100 ether);
        vTok = bound(vTok, LP_RESERVE, V_TOK0);
        ethIn = bound(ethIn, 1, 10 ether);

        uint256 out = h.buyQuote(vEth, vTok, ethIn);
        vm.assume(out < vTok);

        assertGe((vEth + ethIn) * (vTok - out), vEth * vTok, "k shrank on buy");
    }

    function testFuzz_SellDoesNotDecreaseK(uint256 vEth, uint256 vTok, uint256 tokenIn) public view {
        vEth = bound(vEth, V_ETH0, 100 ether);
        vTok = bound(vTok, LP_RESERVE, V_TOK0);
        tokenIn = bound(tokenIn, 1, SALE);

        uint256 out = h.sellQuote(vEth, vTok, tokenIn);
        vm.assume(out < vEth);

        assertGe((vEth - out) * (vTok + tokenIn), vEth * vTok, "k shrank on sell");
    }

    function testFuzz_PriceRisesWithSupplySold(uint256 a, uint256 b) public view {
        a = bound(a, 0, SALE - 1e18);
        b = bound(b, a + 1e18, SALE);

        uint256 pA = h.spotPriceE18(V_ETH0 + h.ethInForExactTokens(V_ETH0, V_TOK0, a), V_TOK0 - a);
        uint256 pB = h.spotPriceE18(V_ETH0 + h.ethInForExactTokens(V_ETH0, V_TOK0, b), V_TOK0 - b);
        assertGt(pB, pA, "price not monotonic");
    }

    function testFuzz_BuyQuoteMonotonicInEthIn(uint256 x, uint256 d) public view {
        x = bound(x, 1, 1 ether);
        d = bound(d, 1, 1 ether);
        assertGe(h.buyQuote(V_ETH0, V_TOK0, x + d), h.buyQuote(V_ETH0, V_TOK0, x));
    }

    function test_ZeroInputsReturnZero() public view {
        assertEq(h.buyQuote(V_ETH0, V_TOK0, 0), 0);
        assertEq(h.sellQuote(V_ETH0, V_TOK0, 0), 0);
        assertEq(h.ethInForExactTokens(V_ETH0, V_TOK0, 0), 0);
    }

    function test_RevertsWhenDrainingWholeReserve() public {
        vm.expectRevert(CurveMath.ExceedsReserve.selector);
        h.ethInForExactTokens(V_ETH0, V_TOK0, V_TOK0);
    }

    function test_RevertsOnZeroReserve() public {
        vm.expectRevert(CurveMath.ZeroReserve.selector);
        h.buyQuote(0, V_TOK0, 1 ether);
    }

    function test_NoOverflowAtExtremes() public view {
        assertLt(h.buyQuote(V_ETH0, V_TOK0, 1_000_000 ether), V_TOK0);
        assertLt(h.sellQuote(100 ether, V_TOK0, V_TOK0), 100 ether);
    }
}
