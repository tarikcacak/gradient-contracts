// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {IERC20, IUniswapV2Pair} from "../../src/interfaces/IExternal.sol";

contract BondingCurveTest is BaseTest {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ------------------------------------------------------------- creation

    function test_CreateEscrowsWholeSupplyAndOpensPair() public {
        address token = _create(alice);

        assertEq(LaunchToken(token).totalSupply(), curve.TOTAL_SUPPLY());
        assertEq(LaunchToken(token).balanceOf(address(curve)), curve.TOTAL_SUPPLY());
        assertEq(LaunchToken(token).curve(), address(curve));
        assertFalse(LaunchToken(token).tradingUnlocked());

        (uint256 vEth, uint256 vTok, uint256 realEth, BondingCurve.Status status) = _state(token);
        assertEq(vEth, V_ETH_START);
        assertEq(vTok, curve.TOTAL_SUPPLY());
        assertEq(realEth, 0);
        assertTrue(status == BondingCurve.Status.BONDING);

        (,,,, address pair,) = curve.states(token);
        assertTrue(pair != address(0), "pair not created at launch");
        assertEq(uniFactory.getPair(token, address(weth)), pair);
    }

    function test_CreateFeeAccruesToProtocol() public {
        _create(alice);
        assertEq(curve.protocolFees(), CREATE_FEE);
    }

    function test_CreateWithInitialBuyGivesCreatorTokens() public {
        address token = _create(alice, 0.01 ether);
        assertGt(LaunchToken(token).balanceOf(alice), 0, "creator got nothing");
        (,, uint256 realEth,) = _state(token);
        assertGt(realEth, 0);
    }

    function test_ImplementationCannotBeInitialized() public {
        address impl = factory.implementation();
        vm.expectRevert(LaunchToken.AlreadyInitialized.selector);
        LaunchToken(impl).initialize("X", "X", address(curve), 1);
    }

    // ------------------------------------------------------------------ buy

    function test_BuyMatchesQuoteExactly() public {
        address token = _create(alice);

        (uint256 qOut, uint256 qFee, uint256 qRefund,) = curve.quoteBuy(token, 0.01 ether);
        uint256 out = _buy(bob, token, 0.01 ether);

        assertEq(out, qOut, "quote != execution");
        assertEq(qRefund, 0, "unexpected refund mid-sale");
        assertEq(curve.protocolFees(), CREATE_FEE + qFee);
        assertEq(LaunchToken(token).balanceOf(bob), out);
    }

    function test_BuyMovesReservesConsistently() public {
        address token = _create(alice);
        _buy(bob, token, 0.05 ether);

        (uint256 vEth, uint256 vTok, uint256 realEth,) = _state(token);
        assertEq(vEth - V_ETH_START, realEth, "vEth/realEth diverged");
        assertEq(vTok, LaunchToken(token).balanceOf(address(curve)), "vTok != escrowed balance");
        assertEq(address(curve).balance, realEth + curve.protocolFees(), "balance mismatch");
    }

    function test_BuyRespectsSlippage() public {
        address token = _create(alice);
        (uint256 qOut,,,) = curve.quoteBuy(token, 0.01 ether);

        vm.prank(bob);
        vm.expectRevert(BondingCurve.Slippage.selector);
        curve.buy{value: 0.01 ether}(token, qOut + 1, block.timestamp);
    }

    function test_BuyRespectsDeadline() public {
        address token = _create(alice);
        vm.warp(block.timestamp + 100);

        vm.prank(bob);
        vm.expectRevert(BondingCurve.Expired.selector);
        curve.buy{value: 0.01 ether}(token, 0, block.timestamp - 1);
    }

    function test_PriceRisesAsSupplySells() public {
        address token = _create(alice);
        uint256 p0 = curve.priceOf(token);
        _buy(bob, token, 0.1 ether);
        uint256 p1 = curve.priceOf(token);
        _buy(carol, token, 0.1 ether);
        uint256 p2 = curve.priceOf(token);

        assertGt(p1, p0);
        assertGt(p2, p1);
    }

    /// Two buyers of the same size: the earlier one must get more tokens.
    function test_EarlierBuyerGetsMore() public {
        address token = _create(alice);
        uint256 first = _buy(bob, token, 0.05 ether);
        uint256 second = _buy(carol, token, 0.05 ether);
        assertGt(first, second, "curve did not reward the early buyer");
    }

    // ----------------------------------------------------------------- sell

    function test_SellReturnsEthAndRestoresReserves() public {
        address token = _create(alice);
        uint256 bought = _buy(bob, token, 0.1 ether);

        uint256 balBefore = bob.balance;
        uint256 ethOut = _sell(bob, token, bought);

        assertEq(bob.balance, balBefore + ethOut);
        assertEq(LaunchToken(token).balanceOf(bob), 0);

        (uint256 vEth, uint256 vTok,,) = _state(token);
        assertEq(vTok, curve.TOTAL_SUPPLY(), "supply not fully returned");
        assertGe(vEth, V_ETH_START, "vEth fell below the virtual floor");
    }

    /// The only thing a buy-then-sell can lose is fees plus curve dust.
    function test_RoundTripCostsOnlyFees() public {
        address token = _create(alice);

        uint256 before = bob.balance;
        uint256 bought = _buy(bob, token, 0.2 ether);
        uint256 ethOut = _sell(bob, token, bought);

        uint256 lost = before - bob.balance;
        assertEq(lost, 0.2 ether - ethOut);

        // 1% in, then 1% out on a slightly smaller notional -> just under 2%.
        assertLt(lost, 0.0042 ether, "lost more than two fee legs");
        assertGt(lost, 0.0038 ether, "fee not actually charged");
    }

    function test_SellRespectsSlippage() public {
        address token = _create(alice);
        uint256 bought = _buy(bob, token, 0.1 ether);
        (uint256 ethOut,,) = curve.quoteSell(token, bought);

        vm.startPrank(bob);
        LaunchToken(token).approve(address(curve), bought);
        vm.expectRevert(BondingCurve.Slippage.selector);
        curve.sell(token, bought, ethOut + 1, block.timestamp);
        vm.stopPrank();
    }

    function test_CannotSellWithoutBalance() public {
        address token = _create(alice);
        _buy(bob, token, 0.1 ether);

        vm.startPrank(carol);
        LaunchToken(token).approve(address(curve), 1e18);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        curve.sell(token, 1e18, 0, block.timestamp);
        vm.stopPrank();
    }

    // -------------------------------------------------------- trading gate

    function test_TransfersLockedBeforeGraduation() public {
        address token = _create(alice);
        _buy(bob, token, 0.1 ether);

        vm.prank(bob);
        vm.expectRevert(LaunchToken.TradingLocked.selector);
        LaunchToken(token).transfer(carol, 1e18);
    }

    /// Pushing tokens straight into the curve would desync `vTok` from escrow
    /// and strand them, so the gate keys on the curve being the *initiator*.
    function test_CannotPushTokensIntoTheCurveDirectly() public {
        address token = _create(alice);
        _buy(bob, token, 0.1 ether);

        vm.prank(bob);
        vm.expectRevert(LaunchToken.TradingLocked.selector);
        LaunchToken(token).transfer(address(curve), 1e18);
    }

    function test_TransfersUnlockedAfterGraduation() public {
        address token = _create(alice);
        _buy(bob, token, 0.1 ether);
        // Graduate with bob so the recipient below starts from a clean balance.
        _graduate(bob, token);

        assertTrue(LaunchToken(token).tradingUnlocked());

        uint256 amt = LaunchToken(token).balanceOf(bob) / 2;
        assertGt(amt, 0);
        assertEq(LaunchToken(token).balanceOf(carol), 0, "recipient not clean");

        vm.prank(bob);
        LaunchToken(token).transfer(carol, amt);
        assertEq(LaunchToken(token).balanceOf(carol), amt);
    }

    // ------------------------------------------------- final buy + clamping

    function test_FinalBuyClampsAndRefundsSurplus() public {
        address token = _create(alice);

        uint256 before = carol.balance;
        vm.prank(carol);
        curve.buy{value: 5 ether}(token, 0, block.timestamp);

        // The whole sale costs 0.5 ETH net, ~0.505 ETH gross of the 1% fee.
        uint256 spent = before - carol.balance;
        assertLt(spent, 0.51 ether, "did not refund the surplus");
        assertGt(spent, 0.50 ether, "refunded too much");

        // The clamp landed the sale exactly on SALE_SUPPLY, which is what
        // triggered graduation; graduation then emptied the escrow, so `vTok`
        // reads 0 rather than LP_RESERVE. Assert the sale total instead.
        (, uint256 vTok, uint256 realEth, BondingCurve.Status status) = _state(token);
        assertTrue(status == BondingCurve.Status.GRADUATED, "did not graduate");
        assertEq(vTok, 0, "escrow not emptied by graduation");
        assertEq(realEth, 0, "reserves not consumed by graduation");
        assertEq(curve.progressBps(token), 10_000, "progress not complete");
        assertEq(curve.priceOf(token), 0, "graduated token still quotes a curve price");
    }

    /// The clamp stops the sale precisely on SALE_SUPPLY. Observed one buy
    /// before graduation empties the escrow.
    function test_SaleStopsExactlyOnTheAllocation() public {
        address token = _create(alice);
        _buy(bob, token, 0.3 ether);

        (, uint256 vTokBefore,,) = _state(token);
        assertGt(vTokBefore, curve.LP_RESERVE(), "already sold out");

        vm.prank(carol);
        curve.buy{value: 5 ether}(token, 0, block.timestamp);

        // Total delivered across both buys is exactly the sale allocation.
        uint256 delivered = LaunchToken(token).balanceOf(bob) + LaunchToken(token).balanceOf(carol);
        assertEq(delivered, curve.SALE_SUPPLY(), "sale did not stop on the allocation");
    }

    function test_CannotTradeAfterGraduation() public {
        address token = _create(alice);
        _graduate(bob, token);

        vm.prank(carol);
        vm.expectRevert(BondingCurve.NotBonding.selector);
        curve.buy{value: 0.01 ether}(token, 0, block.timestamp);
    }

    function test_GraduateCannotRunTwice() public {
        address token = _create(alice);
        _graduate(bob, token);

        vm.expectRevert(BondingCurve.NotGraduating.selector);
        curve.graduate(token);
    }

    // --------------------------------------------------------- graduation

    /// The headline correctness property: the pool must open at the price the
    /// curve closed at, or the first Uniswap trade is a free arb.
    function test_PoolOpensAtTheCurveClosingPrice() public {
        address token = _create(alice);

        _buy(bob, token, 0.3 ether);

        // The clamp makes the closing state path-independent: vTok always lands
        // on LP_RESERVE and vEth on 5x the virtual seed.
        uint256 closingPrice = (5 * V_ETH_START * 1e18) / curve.LP_RESERVE();

        _graduate(carol, token);

        (,,,, address pair,) = curve.states(token);
        uint256 poolTok = IERC20(token).balanceOf(pair);
        uint256 poolEth = IERC20(address(weth)).balanceOf(pair);
        assertGt(poolTok, 0);
        assertGt(poolEth, 0);

        uint256 poolPrice = (poolEth * 1e18) / poolTok;

        // Within 10 bps. Any wider and the pool is arbitrageable on block one.
        assertApproxEqRel(poolPrice, closingPrice, 0.001e18, "pool price != curve close");
    }

    function test_GraduationBurnsLpAndSurplusTokens() public {
        address token = _create(alice);
        uint256 supplyBefore = LaunchToken(token).totalSupply();

        _graduate(bob, token);

        (,,,, address pair,) = curve.states(token);

        // All LP is at the burn address; nobody can pull the liquidity.
        assertEq(IUniswapV2Pair(pair).balanceOf(address(curve)), 0, "curve kept LP");
        assertGt(IUniswapV2Pair(pair).balanceOf(DEAD), 0, "LP not burned");

        // Tokens that did not fit the pool at the closing price are destroyed.
        assertLt(LaunchToken(token).totalSupply(), supplyBefore, "surplus not burned");
        assertEq(LaunchToken(token).balanceOf(address(curve)), 0, "curve kept tokens");
    }

    function test_GraduationLeavesNoReserveEthBehind() public {
        address token = _create(alice);
        _graduate(bob, token);

        (,, uint256 realEth,) = _state(token);
        assertEq(realEth, 0);
        // Everything left in the contract is claimable fees, nothing more.
        assertEq(address(curve).balance, curve.protocolFees());
    }

    /// A donated balance on a virgin pair must not skew the opening ratio.
    function test_DonationToPairDoesNotSkewOpeningPrice() public {
        address token = _create(alice);
        (,,,, address pair,) = curve.states(token);

        // Attacker parks WETH in the empty pair before graduation.
        vm.prank(bob);
        weth.deposit{value: 5 ether}();
        vm.prank(bob);
        IERC20(address(weth)).transfer(pair, 5 ether);

        _graduate(carol, token);

        uint256 poolTok = IERC20(token).balanceOf(pair);
        uint256 poolEth = IERC20(address(weth)).balanceOf(pair);
        uint256 poolPrice = (poolEth * 1e18) / poolTok;
        uint256 closingPrice = (5 * V_ETH_START * 1e18) / curve.LP_RESERVE();

        assertApproxEqRel(poolPrice, closingPrice, 0.001e18, "donation skewed the pool");
        // The donation was swept, not absorbed.
        assertEq(IERC20(address(weth)).balanceOf(treasury), 5 ether, "donation not swept");
    }

    // --------------------------------------------------------------- fees

    function test_ClaimFeesOnlyEverReachesTreasury() public {
        address token = _create(alice);
        _buy(bob, token, 0.1 ether);

        uint256 fees = curve.protocolFees();
        assertGt(fees, 0);

        // Callable by anyone; the destination is immutable.
        vm.prank(carol);
        curve.claimFees();

        assertEq(treasury.balance, fees);
        assertEq(curve.protocolFees(), 0);
    }

    function test_ClaimFeesCannotTouchReserves() public {
        address token = _create(alice);
        _buy(bob, token, 0.1 ether);

        (,, uint256 realEth,) = _state(token);
        curve.claimFees();

        // Reserve ETH is untouched and still fully backed.
        assertEq(address(curve).balance, realEth, "claimFees ate reserves");
        (,, uint256 realAfter,) = _state(token);
        assertEq(realAfter, realEth);

        // And the holder can still exit for their share.
        uint256 bal = LaunchToken(token).balanceOf(bob);
        uint256 got = _sell(bob, token, bal);
        assertGt(got, 0);
    }

    function test_FeeCapsAreEnforced() public {
        // Read the caps BEFORE arming expectRevert: argument evaluation is
        // itself an external call, and it would swallow the expectation.
        uint256 maxTrade = curve.MAX_TRADE_FEE_BPS();
        uint256 maxGrad = curve.MAX_GRADUATION_FEE_BPS();

        vm.startPrank(owner);
        vm.expectRevert(BondingCurve.FeeTooHigh.selector);
        curve.setFees(maxTrade + 1, 0);

        vm.expectRevert(BondingCurve.FeeTooHigh.selector);
        curve.setFees(0, maxGrad + 1);

        // The ceiling itself is allowed.
        curve.setFees(maxTrade, maxGrad);
        vm.stopPrank();

        assertEq(curve.tradeFeeBps(), maxTrade);
    }

    // ------------------------------------------------------ access control

    function test_OnlyFactoryCanRegister() public {
        vm.prank(alice);
        vm.expectRevert(BondingCurve.NotFactory.selector);
        curve.registerToken(address(0x1234), alice);
    }

    function test_OnlySelfCanPerformGraduation() public {
        address token = _create(alice);
        vm.prank(alice);
        vm.expectRevert(BondingCurve.NotSelf.selector);
        curve.performGraduation(token);
    }

    function test_FactoryCanOnlyBeSetOnce() public {
        vm.prank(owner);
        vm.expectRevert(BondingCurve.FactoryAlreadySet.selector);
        curve.setFactory(address(0xBEEF));
    }

    function test_NonOwnerCannotChangeFees() public {
        vm.prank(alice);
        vm.expectRevert(BondingCurve.NotOwner.selector);
        curve.setFees(0, 0);
    }

    // ----------------------------------------------------- circuit breaker

    /// Buys pause. Sells never do - a switch that traps holders is a rug.
    function test_PauseStopsBuysButNeverSells() public {
        address token = _create(alice);
        uint256 bought = _buy(bob, token, 0.1 ether);

        vm.prank(owner);
        curve.setBuysPaused(true);

        vm.prank(carol);
        vm.expectRevert(BondingCurve.BuysArePaused.selector);
        curve.buy{value: 0.01 ether}(token, 0, block.timestamp);

        uint256 got = _sell(bob, token, bought);
        assertGt(got, 0, "pause trapped a holder");
    }

    // ------------------------------------------------------------- fuzzing

    function testFuzz_QuoteAlwaysMatchesExecution(uint256 ethIn) public {
        // Kept below the clamp threshold so the assertion on fee deltas is not
        // confounded by the graduation fee.
        ethIn = bound(ethIn, 1e12, 0.3 ether);
        address token = _create(alice);

        (uint256 qOut, uint256 qFee, uint256 qRefund,) = curve.quoteBuy(token, ethIn);
        vm.assume(qOut > 0);

        uint256 feesBefore = curve.protocolFees();
        uint256 balBefore = bob.balance;

        vm.prank(bob);
        uint256 out = curve.buy{value: ethIn}(token, 0, block.timestamp);

        assertEq(out, qOut, "tokensOut mismatch");
        assertEq(curve.protocolFees() - feesBefore, qFee, "fee mismatch");
        assertEq(balBefore - bob.balance, ethIn - qRefund, "refund mismatch");
    }

    function testFuzz_ContractIsAlwaysFullyBacked(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 1e12, 0.1 ether);
        b = bound(b, 1e12, 0.1 ether);
        c = bound(c, 1, 100);

        address token = _create(alice);
        _buy(bob, token, a);
        _buy(carol, token, b);

        uint256 bal = LaunchToken(token).balanceOf(bob);
        if (bal > 0) _sell(bob, token, (bal * c) / 100);

        (,, uint256 realEth,) = _state(token);
        assertGe(address(curve).balance, realEth + curve.protocolFees(), "under-collateralised");
    }
}
