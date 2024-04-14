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

contract Demo is Script {
    IPYieldToken YT;
    IPPrincipalToken PT;
    IStandardizedYield SY;
    IPMarket market;
    IERC20 ezEth;
    IPAllActionV3 router;
    IPRouterStatic routerStatic;

    // DefaultApprox means no off-chain preparation is involved, more gas consuming (~ 180k gas)
    ApproxParams public defaultApprox = ApproxParams(0, type(uint256).max, 0, 256, 1e20);

    function setUp() public {
        uint256 forkId =
            vm.createSelectFork("https://eth-mainnet.g.alchemy.com/v2/ZqfVOtoK34QDr2El7RkViZZEplF4o8-7", 19603584);

        ezEth = IERC20(0xbf5495Efe5DB9ce00f80364C8B423567e58d2110);
        SY = IStandardizedYield(0x22E12A50e3ca49FB183074235cB1db84Fe4C716D);
        YT = IPYieldToken(0x256Fb830945141f7927785c06b65dAbc3744213c);
        PT = IPPrincipalToken(0xeEE8aED1957ca1545a0508AfB51b53cCA7e3c0d1);
        market = IPMarket(0xDe715330043799D7a80249660d1e6b61eB3713B3);
        router = IPAllActionV3(0x00000000005BBB0EF59571E58418F9a4357b68A0);
        routerStatic = IPRouterStatic(0x263833d47eA3fA4a30f269323aba6a107f9eB14C);

        IERC20(ezEth).approve(address(router), type(uint256).max);
        IERC20(SY).approve(address(router), type(uint256).max);
        IERC20(PT).approve(address(router), type(uint256).max);
        IERC20(YT).approve(address(router), type(uint256).max);
        IERC20(market).approve(address(router), type(uint256).max);
    }

    function run() public {
        console.log("Script at blocknum %s", block.number);
        (IStandardizedYield _sy, IPPrincipalToken _pt, IPYieldToken _yt) = market.readTokens();
        console.log("%s %s", address(SY), address(_sy));
        console.log("%s %s", address(PT), address(_pt));
        console.log("%s %s", address(YT), address(_yt)); // all match

        // step 1: get some ezETH
        uint256 myEzEthBalanace = ezEth.balanceOf(address(this));
        console.log("my ezEthBalance is %s", myEzEthBalanace);
        //vm.deal(address(ezEth), address(this), 10 ether);
        myEzEthBalanace = ezEth.balanceOf(address(this));
        console.log("my ezEthBalance is %s", myEzEthBalanace);

        uint256 mySyBalance = SY.balanceOf(address(this));
        uint256 mySharesOut = SY.deposit{value: 10 ether}(
            address(this),
            address(0), // NATIVE
            10 ether,
            1 ether
        );
        // shares out is same as SY balance
        console.log(
            "Shares out %s. SY balance now: %s. vs before %s",
            mySharesOut / 1e18,
            SY.balanceOf(address(this)) / 1e18,
            mySyBalance / 1e18
        );

        uint256 mySharesOut2 = SY.deposit{value: 10 ether}(address(this), address(0), 10 ether, 1 ether);
        console.log(
            "Second time %s. vs first %s. Total %s",
            mySharesOut2 / 1 ether,
            mySharesOut / 1 ether,
            SY.balanceOf(address(this)) / 1 ether
        );

        uint256 ptRateInSy = routerStatic.getPtToSyRate(address(market));
        uint256 ptRateInAsset = routerStatic.getPtToAssetRate(address(market));
        console.log(
            "The PT rate in SY is %s. In asset its %s. The block time is %s", ptRateInSy, ptRateInAsset, block.timestamp
        );

        /* (uint256 netPtIn, uint256 netSyFee, uint256 priceImpact, uint256 exchangeRateAfter) = routerStatic.swapPtForExactSyStatic(address(market), 1 ether);
    console.log("netPtIn: %s. netSyFee %s. exchangeRateAfter %s", netPtIn, netSyFee, exchangeRateAfter); */
        /* 
    SY.transfer(address(YT), 1 ether);
    uint256 amountPYOut = YT.mintPY(address(this), address(this));
    console.log("amountPYOut %s. ", amountPYOut);
    console.log("SY: %s; PT: %s; YT %s", SY.balanceOf(address(this)), PT.balanceOf(address(this)), YT.balanceOf(address(this)));



    // using router instead
    uint256 myEth = address(this).balance - 1 ether;

    SwapData memory emptySwap;
    LimitOrderData memory emptyLimit;
    // TODO WETH
    TokenInput memory input = TokenInput({
      tokenIn: address(0),
      netTokenIn: myEth,
      tokenMintSy: address(0),
      pendleSwap: address(0),
      swapData: emptySwap
    });
    console.log("prepping for swap from %s", address(this));
    (IStandardizedYield _sy, , IPYieldToken _yt) = market.readTokens();
    console.log("Market is SY: %s, YT %s", address(_sy), address(_yt));
    console.log("Market expiry is %s vs timestamp of %s; %s", market.expiry(), block.timestamp, market.isExpired());
    console.log("%s; %s", market.totalActiveSupply(), market.totalSupply());
    MarketState memory _state = market.readState(address(router));
    console.logInt(_state.totalPt); */
        /* router.swapExactTokenForPt{value: myEth }(address(this), address(market), myEth , defaultApprox, input, emptyLimit); */
    }
}
