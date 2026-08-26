// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {TokenFactory} from "../../src/TokenFactory.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {MockWETH, MockUniFactory, MockRouter} from "../mocks/MockUniswap.sol";

/// @dev Drives random, bounded traffic at the curve. Every entry point clamps
///      its inputs and swallows expected reverts so the fuzzer spends its runs
///      exploring state rather than bouncing off input validation.
contract Handler is Test {
    BondingCurve public curve;
    address[] public tokens;
    address[] public actors;

    uint256 public ghostEthIn;
    uint256 public ghostEthOut;

    constructor(BondingCurve curve_, address[] memory tokens_, address[] memory actors_) {
        curve = curve_;
        tokens = tokens_;
        actors = actors_;
    }

    function _token(uint256 seed) internal view returns (address) {
        return tokens[seed % tokens.length];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function buy(uint256 tokenSeed, uint256 actorSeed, uint256 amount) external {
        address token = _token(tokenSeed);
        address actor = _actor(actorSeed);
        amount = bound(amount, 1e10, 0.15 ether);

        if (actor.balance < amount) return;

        // Credit only what the curve actually kept - the final buy is clamped
        // and refunds its surplus, so `amount` would badly overstate inflow.
        uint256 before = actor.balance;
        vm.prank(actor);
        try curve.buy{value: amount}(token, 0, block.timestamp) {
            ghostEthIn += before - actor.balance;
        } catch {}
    }

    function sell(uint256 tokenSeed, uint256 actorSeed, uint256 pct) external {
        address token = _token(tokenSeed);
        address actor = _actor(actorSeed);
        pct = bound(pct, 1, 100);

        uint256 bal = LaunchToken(token).balanceOf(actor);
        if (bal == 0) return;
        uint256 amount = (bal * pct) / 100;
        if (amount == 0) return;

        vm.startPrank(actor);
        LaunchToken(token).approve(address(curve), amount);
        try curve.sell(token, amount, 0, block.timestamp) returns (uint256 out) {
            ghostEthOut += out;
        } catch {}
        vm.stopPrank();
    }

    function claimFees(uint256) external {
        try curve.claimFees() {} catch {}
    }

    /// Exercises the permissionless retry path, including its rejection of
    /// tokens that have not sold out.
    function graduate(uint256 tokenSeed) external {
        try curve.graduate(_token(tokenSeed)) {} catch {}
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function tokenAt(uint256 i) external view returns (address) {
        return tokens[i];
    }
}

contract CurveInvariantTest is Test {
    BondingCurve internal curve;
    TokenFactory internal factory;
    MockWETH internal weth;
    MockUniFactory internal uniFactory;
    MockRouter internal router;
    Handler internal handler;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");

    uint256 internal constant V_ETH_START = 0.125 ether;

    function setUp() public {
        weth = new MockWETH();
        uniFactory = new MockUniFactory();
        router = new MockRouter(address(uniFactory), address(weth));

        curve = new BondingCurve(owner, treasury, address(router), V_ETH_START);
        factory = new TokenFactory(owner, address(curve), 0);
        vm.prank(owner);
        curve.setFactory(address(factory));

        address[] memory actors = new address[](4);
        for (uint256 i = 0; i < 4; i++) {
            actors[i] = address(uint160(0x1000 + i));
            vm.deal(actors[i], 50 ether);
        }

        address[] memory tokens = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(actors[i % actors.length]);
            tokens[i] = factory.createToken("Inv", "INV", "");
        }

        handler = new Handler(curve, tokens, actors);
        targetContract(address(handler));
    }

    /// The single most important property: the contract can always honour every
    /// reserve it claims to hold, plus every fee it has accrued.
    function invariant_AlwaysFullyBacked() public view {
        uint256 owed = curve.protocolFees();
        for (uint256 i = 0; i < handler.tokenCount(); i++) {
            (,, uint256 realEth,,,) = curve.states(handler.tokenAt(i));
            owed += realEth;
        }
        assertGe(address(curve).balance, owed, "curve is under-collateralised");
    }

    /// While bonding, the real reserve is exactly the virtual reserve minus its
    /// seed. Any drift means buy and sell disagree about accounting.
    function invariant_RealEthTracksVirtualEth() public view {
        for (uint256 i = 0; i < handler.tokenCount(); i++) {
            address t = handler.tokenAt(i);
            (uint256 vEth,, uint256 realEth,,, BondingCurve.Status status) = curve.states(t);
            if (status == BondingCurve.Status.BONDING) {
                assertEq(vEth - V_ETH_START, realEth, "vEth/realEth diverged");
            }
        }
    }

    /// The token reserve is not virtual: it must equal the escrowed balance.
    function invariant_TokenReserveIsEscrowed() public view {
        for (uint256 i = 0; i < handler.tokenCount(); i++) {
            address t = handler.tokenAt(i);
            (, uint256 vTok,,,, BondingCurve.Status status) = curve.states(t);
            if (status == BondingCurve.Status.BONDING) {
                assertEq(vTok, LaunchToken(t).balanceOf(address(curve)), "vTok != escrow");
            }
        }
    }

    /// The curve can never sell past its allocation, and never below the LP
    /// reserve it must hand to Uniswap.
    function invariant_SaleNeverExceedsAllocation() public view {
        for (uint256 i = 0; i < handler.tokenCount(); i++) {
            (, uint256 vTok,,,, BondingCurve.Status status) = curve.states(handler.tokenAt(i));
            if (status != BondingCurve.Status.BONDING) continue; // escrow is emptied at graduation
            assertGe(vTok, curve.LP_RESERVE(), "sold into the LP reserve");
            assertLe(vTok, curve.TOTAL_SUPPLY(), "reserve exceeds total supply");
        }
    }

    /// k must never shrink. If it does, rounding is leaking value to traders.
    function invariant_KNeverShrinks() public view {
        uint256 k0 = V_ETH_START * curve.TOTAL_SUPPLY();
        for (uint256 i = 0; i < handler.tokenCount(); i++) {
            address t = handler.tokenAt(i);
            (uint256 vEth, uint256 vTok,,,, BondingCurve.Status status) = curve.states(t);
            if (status == BondingCurve.Status.BONDING) {
                assertGe(vEth * vTok, k0, "k shrank");
            }
        }
    }

    /// Traders can never extract more ETH than they put in, in aggregate.
    function invariant_TradersNeverExtractMoreThanDeposited() public view {
        assertLe(handler.ghostEthOut(), handler.ghostEthIn(), "traders net-extracted ETH");
    }

    /// Trading stays locked until graduation, for every token.
    function invariant_TradingLockedWhileBonding() public view {
        for (uint256 i = 0; i < handler.tokenCount(); i++) {
            address t = handler.tokenAt(i);
            (,,,,, BondingCurve.Status status) = curve.states(t);
            if (status == BondingCurve.Status.BONDING) {
                assertFalse(LaunchToken(t).tradingUnlocked(), "unlocked too early");
            }
        }
    }
}
