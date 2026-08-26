// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {TokenFactory} from "../../src/TokenFactory.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {MockWETH, MockUniFactory, BreakableRouter} from "../mocks/MockUniswap.sol";

/// @notice Covers the failure path: what happens when the router reverts during
///         the in-transaction graduation.
///
/// This is the most delicate branch in the contract. A token that sells out and
/// then cannot graduate must not become a tomb: holders have to keep their exit,
/// and the graduation has to stay retryable.
contract GraduationRecoveryTest is Test {
    BondingCurve internal curve;
    TokenFactory internal factory;
    MockWETH internal weth;
    MockUniFactory internal uniFactory;
    BreakableRouter internal router;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant V_ETH_START = 0.125 ether;

    function setUp() public {
        weth = new MockWETH();
        uniFactory = new MockUniFactory();
        router = new BreakableRouter(address(uniFactory), address(weth));

        curve = new BondingCurve(owner, treasury, address(router), V_ETH_START);
        factory = new TokenFactory(owner, address(curve), 0);
        vm.prank(owner);
        curve.setFactory(address(factory));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _soldOutWithBrokenRouter() internal returns (address token) {
        vm.prank(alice);
        token = factory.createToken("Recover", "RCV", "");

        router.setBroken(true);

        vm.prank(bob);
        curve.buy{value: 5 ether}(token, 0, block.timestamp);
    }

    /// The buy itself must still succeed - the buyer paid, they get their
    /// tokens, and the failure is recorded rather than thrown.
    function test_FailedGraduationDoesNotRevertTheBuy() public {
        address token = _soldOutWithBrokenRouter();

        assertEq(LaunchToken(token).balanceOf(bob), curve.SALE_SUPPLY(), "buyer shortchanged");
        assertFalse(LaunchToken(token).tradingUnlocked(), "unlocked despite failure");
    }

    /// It must roll back to BONDING, not sit in GRADUATING - GRADUATING blocks
    /// sells too, which would freeze the raise and every holder's position.
    function test_FailedGraduationRollsBackToBonding() public {
        address token = _soldOutWithBrokenRouter();

        (, uint256 vTok,,,, BondingCurve.Status status) = curve.states(token);
        assertTrue(status == BondingCurve.Status.BONDING, "left in a trap state");
        assertEq(vTok, curve.LP_RESERVE(), "escrow wrong after rollback");
        assertEq(vTok, LaunchToken(token).balanceOf(address(curve)), "escrow desynced");
    }

    /// The whole point of the rollback: holders keep their exit.
    function test_HoldersCanStillSellAfterAFailedGraduation() public {
        address token = _soldOutWithBrokenRouter();

        uint256 bal = LaunchToken(token).balanceOf(bob);
        uint256 before = bob.balance;

        vm.startPrank(bob);
        LaunchToken(token).approve(address(curve), bal / 2);
        uint256 out = curve.sell(token, bal / 2, 0, block.timestamp);
        vm.stopPrank();

        assertGt(out, 0, "holder trapped");
        assertEq(bob.balance, before + out);
    }

    /// A sold-out token cannot be bought into - the clamp yields zero tokens.
    function test_BuyingASoldOutTokenReverts() public {
        address token = _soldOutWithBrokenRouter();

        vm.prank(alice);
        vm.expectRevert(BondingCurve.ZeroAmount.selector);
        curve.buy{value: 0.01 ether}(token, 0, block.timestamp);
    }

    /// Anyone can retry once the router is working again.
    function test_AnyoneCanRetryGraduation() public {
        address token = _soldOutWithBrokenRouter();
        router.setBroken(false);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        curve.graduate(token);

        (,, uint256 realEth,,, BondingCurve.Status status) = curve.states(token);
        assertTrue(status == BondingCurve.Status.GRADUATED, "retry did not graduate");
        assertEq(realEth, 0);
        assertTrue(LaunchToken(token).tradingUnlocked());
        assertEq(address(curve).balance, curve.protocolFees(), "reserves left behind");
    }

    /// Retrying while the router is still broken must revert cleanly, leaving
    /// the token exactly where it was.
    function test_RetryWhileStillBrokenChangesNothing() public {
        address token = _soldOutWithBrokenRouter();

        vm.expectRevert();
        curve.graduate(token);

        (, uint256 vTok,,,, BondingCurve.Status status) = curve.states(token);
        assertTrue(status == BondingCurve.Status.BONDING);
        assertEq(vTok, curve.LP_RESERVE());
    }

    /// `graduate` must not be a back door for a token that has not sold out.
    function test_CannotGraduateATokenThatHasNotSoldOut() public {
        vm.prank(alice);
        address token = factory.createToken("Early", "ERL", "");

        vm.prank(bob);
        curve.buy{value: 0.1 ether}(token, 0, block.timestamp);

        vm.expectRevert(BondingCurve.NotGraduating.selector);
        curve.graduate(token);
    }

    /// After a sell reopens headroom, a normal buy re-triggers graduation.
    function test_SellThenBuyReGraduates() public {
        address token = _soldOutWithBrokenRouter();
        router.setBroken(false);

        uint256 bal = LaunchToken(token).balanceOf(bob);
        vm.startPrank(bob);
        LaunchToken(token).approve(address(curve), bal / 10);
        curve.sell(token, bal / 10, 0, block.timestamp);
        vm.stopPrank();

        (,,,,, BondingCurve.Status mid) = curve.states(token);
        assertTrue(mid == BondingCurve.Status.BONDING);

        vm.prank(alice);
        curve.buy{value: 5 ether}(token, 0, block.timestamp);

        (,,,,, BondingCurve.Status end) = curve.states(token);
        assertTrue(end == BondingCurve.Status.GRADUATED, "did not re-graduate");
    }
}
