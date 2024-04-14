// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import "forge-std/Script.sol";
import "forge-std/StdUtils.sol";

import "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";
import {IPYieldToken} from "@pendle/core-v2/contracts/interfaces/IPYieldToken.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import "@pendle/core-v2/contracts/interfaces/IPAllActionV3.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import "@pendle/core-v2/contracts/core/Market/MarketMathCore.sol";
import "@pendle/core-v2/contracts/interfaces/IPRouterStatic.sol";
import "@pendle/core-v2/contracts/oracles/PendlePtOracleLib.sol";

contract Demo is Script {
    using PendlePtOracleLib for IPMarket;

    IPYieldToken YT;
    IPPrincipalToken PT;
    IStandardizedYield SY;
    IPMarket market;
    IERC20 ezEth;
    IPAllActionV3 router;
    IPRouterStatic routerStatic;

    uint32 public twapDuration = 900;

    function setUp() public {
        uint256 forkId =
            vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 19603584);

        ezEth = IERC20(0xbf5495Efe5DB9ce00f80364C8B423567e58d2110);
        market = IPMarket(0xDe715330043799D7a80249660d1e6b61eB3713B3);
        (SY, PT, YT) = market.readTokens();
        address[] memory tokensIn = SY.getTokensIn();
        address[] memory tokensOut = SY.getTokensOut();

        for (uint256 i = 0; i < tokensIn.length; i++) {
            console.log("tokensIn: %s", tokensIn[i]);
        }
        for (uint256 i = 0; i < tokensOut.length; i++) {
            console.log("tokensout: %s", tokensOut[i]);
        }

        router = IPAllActionV3(0x00000000005BBB0EF59571E58418F9a4357b68A0);
        routerStatic = IPRouterStatic(0x263833d47eA3fA4a30f269323aba6a107f9eB14C);

        IERC20(ezEth).approve(address(router), type(uint256).max);
        IERC20(SY).approve(address(router), type(uint256).max);
        IERC20(PT).approve(address(router), type(uint256).max);
        IERC20(YT).approve(address(router), type(uint256).max);
        IERC20(market).approve(address(router), type(uint256).max);
    }

    ApproxParams public defaultApprox = ApproxParams(0, type(uint256).max, 0, 256, 1e14);
    LimitOrderData public emptyLimitOrderData;
    SwapData public emptySwapData;

    function run() external {
        console.log("balance : %s", address(this).balance / 1 ether);

        uint256 amountOfAssetToSwap = 20 ether;
        address tokenInputAddress = address(0);
        uint256 amtShares =
            SY.deposit{value: amountOfAssetToSwap}(address(this), tokenInputAddress, amountOfAssetToSwap, 0);
        console.log("Amt Shares %s", amtShares);

        (uint256 netPtOut, uint256 netSyFee) = router.swapExactSyForPt(
            address(this),
            address(market),
            amtShares,
            amtShares, // minimum out
            defaultApprox,
            emptyLimitOrderData
        );
        console.log("netPtOut: %s (%s)", netPtOut, netPtOut / 1 ether);
        console.log("netSyFee: %s (%s)", netSyFee, netSyFee / 1 ether);

        // now swap back out
        // reverts because MarketProportionTooHigh... try again with a more sanet asset
        /* uint256 exactPtIn = netPtOut;
    router.swapExactPtForSy(
      address(this), 
      address(market), 
      exactPtIn,
      0, 
      emptyLimitOrderData
    ); */

        // try oracle... need to initialize in practice...
        uint256 ptRateInSy = market.getPtToSyRate(twapDuration);
        console.log("1 PT in SY: %s (0.%s eth)", ptRateInSy, ptRateInSy);

        uint256 desiredSy = 2.5 ether;
        uint256 estdPtRequired = (desiredSy * 1e18) / ptRateInSy;
        console.log("estdPtRequired: %s (%s)", estdPtRequired, estdPtRequired / 1e18);

        (uint256 actualSyOut, uint256 swapOutSyFee) = router.swapExactPtForSy(
            address(this), address(market), estdPtRequired, desiredSy * 9_000 / 10_000, emptyLimitOrderData
        );

        console.log("Actual out: %s", actualSyOut);
        console.log("The SY fee for that was %s", swapOutSyFee);

        console.log(
            "This all expires at %s. IsExpired? %s After it is called %s",
            market.expiry(),
            market.isExpired(),
            PT.name()
        );
        vm.warp(market.expiry() + 1);
        console.log("Ok Now I have  warped. IsExpired %s", market.isExpired());

        uint256 amtRedeemed = router.redeemPyToSy(address(this), address(YT), 5 ether, 0);
        console.log("%s", amtRedeemed);
    }
}
