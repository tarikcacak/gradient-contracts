// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library CurveMath {
    error ZeroReserve();
    error ExceedsReserve();

    function buyQuote(uint256 vEth, uint256 vTok, uint256 ethIn) internal pure returns (uint256) {
        if (ethIn == 0) return 0;
        if (vEth == 0 || vTok == 0) revert ZeroReserve();
        return (ethIn * vTok) / (vEth + ethIn);
    }

    function sellQuote(uint256 vEth, uint256 vTok, uint256 tokenIn) internal pure returns (uint256) {
        if (tokenIn == 0) return 0;
        if (vEth == 0 || vTok == 0) revert ZeroReserve();
        return (tokenIn * vEth) / (vTok + tokenIn);
    }

    function ethInForExactTokens(uint256 vEth, uint256 vTok, uint256 tokensOut) internal pure returns (uint256) {
        if (tokensOut == 0) return 0;
        if (tokensOut >= vTok) revert ExceedsReserve();
        uint256 num = tokensOut * vEth;
        uint256 den = vTok - tokensOut;
        uint256 q = num / den;
        return (num % den == 0) ? q : q + 1;
    }

    function spotPriceE18(uint256 vEth, uint256 vTok) internal pure returns (uint256) {
        if (vTok == 0) revert ZeroReserve();
        return (vEth * 1e18) / vTok;
    }

    function buyPriceImpactBps(uint256 vEth, uint256 vTok, uint256 ethIn) internal pure returns (uint256) {
        uint256 out = buyQuote(vEth, vTok, ethIn);
        if (out == 0) return 0;
        uint256 spot = (ethIn * vTok) / vEth;
        if (spot <= out) return 0;
        return ((spot - out) * 10_000) / spot;
    }
}
