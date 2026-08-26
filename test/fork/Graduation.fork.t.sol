// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {TokenFactory} from "../../src/TokenFactory.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {IERC20, IUniswapV2Pair, IUniswapV2Router02} from "../../src/interfaces/IExternal.sol";

contract GraduationForkTest is Test {
    BondingCurve internal curve;
    TokenFactory internal factory;
    address internal router;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal buyer = makeAddr("buyer");

    uint256 internal constant V_ETH_START = 0.125 ether;

    function setUp() public {
        try vm.envAddress("UNISWAP_V2_ROUTER") returns (address r) {
            router = r;
        } catch {
            return;
        }
        if (router.code.length == 0) {
            router = address(0);
            return;
        }

        curve = new BondingCurve(owner, treasury, router, V_ETH_START);
        factory = new TokenFactory(owner, address(curve), 0);
        vm.prank(owner);
        curve.setFactory(address(factory));

        vm.deal(buyer, 10 ether);
    }

    modifier onlyForked() {
        if (router == address(0)) {
            console2.log("skipping: UNISWAP_V2_ROUTER unset or has no code on this chain");
            return;
        }
        _;
    }

    function test_RouterWiringIsSane() public onlyForked {
        assertEq(curve.router(), router);
        assertTrue(curve.uniswapFactory() != address(0), "router has no factory");
        assertTrue(curve.weth() != address(0), "router has no WETH");
        assertGt(curve.uniswapFactory().code.length, 0, "factory has no code");
        assertGt(curve.weth().code.length, 0, "WETH has no code");
    }

    function test_FullLifecycleAgainstRealUniswap() public onlyForked {
        vm.prank(buyer);
        address token = factory.createToken("Fork Token", "FORK", "ipfs://fork");

        (,,,, address pair,) = curve.states(token);
        assertGt(pair.code.length, 0, "real pair not deployed");

        vm.prank(buyer);
        curve.buy{value: 5 ether}(token, 0, block.timestamp);

        (,, uint256 realEth,,, BondingCurve.Status status) = curve.states(token);
        assertTrue(status == BondingCurve.Status.GRADUATED, "did not graduate");
        assertEq(realEth, 0, "reserves left behind");

        assertEq(IUniswapV2Pair(pair).balanceOf(address(curve)), 0);
        assertGt(IUniswapV2Pair(pair).balanceOf(0x000000000000000000000000000000000000dEaD), 0);

        uint256 poolTok = IERC20(token).balanceOf(pair);
        uint256 poolEth = IERC20(curve.weth()).balanceOf(pair);
        uint256 poolPrice = (poolEth * 1e18) / poolTok;
        uint256 closingPrice = (5 * V_ETH_START * 1e18) / curve.LP_RESERVE();

        console2.log("pool price   ", poolPrice);
        console2.log("curve close  ", closingPrice);
        assertApproxEqRel(poolPrice, closingPrice, 0.001e18, "pool price != curve close");

        assertTrue(LaunchToken(token).tradingUnlocked());
    }

    function test_DonationAttackAgainstRealPair() public onlyForked {
        vm.prank(buyer);
        address token = factory.createToken("Fork Token", "FORK", "");
        (,,,, address pair,) = curve.states(token);

        address attacker = makeAddr("attacker");
        vm.deal(attacker, 5 ether);
        vm.startPrank(attacker);
        (bool ok,) = curve.weth().call{value: 3 ether}(abi.encodeWithSignature("deposit()"));
        require(ok, "weth deposit");
        IERC20(curve.weth()).transfer(pair, 3 ether);
        vm.stopPrank();

        vm.prank(buyer);
        curve.buy{value: 5 ether}(token, 0, block.timestamp);

        uint256 poolTok = IERC20(token).balanceOf(pair);
        uint256 poolEth = IERC20(curve.weth()).balanceOf(pair);
        uint256 poolPrice = (poolEth * 1e18) / poolTok;
        uint256 closingPrice = (5 * V_ETH_START * 1e18) / curve.LP_RESERVE();

        assertApproxEqRel(poolPrice, closingPrice, 0.001e18, "donation moved the opening price");
        assertEq(IERC20(curve.weth()).balanceOf(treasury), 3 ether, "donation not swept to treasury");
    }
}
