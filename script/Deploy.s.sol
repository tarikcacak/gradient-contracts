// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {TokenFactory} from "../src/TokenFactory.sol";
import {IUniswapV2Router02} from "../src/interfaces/IExternal.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address router = vm.envAddress("UNISWAP_V2_ROUTER");
        address treasury = vm.envOr("TREASURY", deployer);
        uint256 virtualEthStart = vm.envOr("VIRTUAL_ETH_START", uint256(0.125 ether));
        uint256 createFee = vm.envOr("CREATE_FEE", uint256(0.0001 ether));

        require(router.code.length > 0, "router has no code on this chain");
        address uniFactory = IUniswapV2Router02(router).factory();
        address weth = IUniswapV2Router02(router).WETH();
        require(uniFactory.code.length > 0, "router.factory() has no code");
        require(weth.code.length > 0, "router.WETH() has no code");

        vm.startBroadcast(pk);

        BondingCurve curve = new BondingCurve(deployer, treasury, router, virtualEthStart);
        TokenFactory factory = new TokenFactory(deployer, address(curve), createFee);
        curve.setFactory(address(factory));

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== launchpad deployed ===");
        console2.log("chainId          ", block.chainid);
        console2.log("DEPLOY_BLOCK     ", block.number);
        console2.log("BondingCurve     ", address(curve));
        console2.log("TokenFactory     ", address(factory));
        console2.log("LaunchToken impl ", factory.implementation());
        console2.log("router           ", router);
        console2.log("uniswapFactory   ", uniFactory);
        console2.log("WETH             ", weth);
        console2.log("treasury         ", treasury);
        console2.log("virtualEthStart  ", virtualEthStart);
        console2.log("target raise     ", 4 * virtualEthStart);
        console2.log("createFee        ", createFee);
        console2.log("");
        console2.log("Next: copy DEPLOY_BLOCK into backend/.env, then export ABIs:");
        console2.log("  forge inspect BondingCurve abi > ../backend/abi/BondingCurve.json");
        console2.log("  forge inspect TokenFactory abi > ../backend/abi/TokenFactory.json");
    }
}

contract Smoke is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        TokenFactory factory = TokenFactory(vm.envAddress("FACTORY_ADDRESS"));
        BondingCurve curve = BondingCurve(payable(vm.envAddress("CURVE_ADDRESS")));

        vm.startBroadcast(pk);

        address token = factory.createToken{value: factory.createFee() + 0.001 ether}(
            "Smoke Test", "SMOKE", "ipfs://smoke"
        );
        console2.log("token   ", token);
        console2.log("price   ", curve.priceOf(token));
        console2.log("progress", curve.progressBps(token));

        curve.buy{value: 0.002 ether}(token, 0, block.timestamp + 300);
        console2.log("after buy, price", curve.priceOf(token));

        vm.stopBroadcast();
    }
}
