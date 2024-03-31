// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;


import {IPAllActionV3, LimitOrderData} from "@pendle/core-v2/contracts/interfaces/IPAllActionV3.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {IPYieldToken} from "@pendle/core-v2/contracts/interfaces/IPYieldToken.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {ApproxParams} from "@pendle/core-v2/contracts/router/base/MarketApproxLib.sol";

import {BaseStrategy} from "./BaseStrategy.sol";
contract PendleEZEthStrategy is BaseStrategy {

  IPAllActionV3 public constant router = IPAllActionV3(0x00000000005BBB0EF59571E58418F9a4357b68A0);
  IPMarket public constant market = IPMarket(0xDe715330043799D7a80249660d1e6b61eB3713B3);

  IStandardizedYield public SY;
  IPPrincipalToken public PT;
  IPYieldToken public YT;


  // docs: "DefaultApprox means no off-chain preparation is involved, more gas consuming (~ 180k gas)"
  ApproxParams public defaultApprox = ApproxParams(0, type(uint256).max, 0, 256, 1e14);

  // docs: "EmptyLimit means no limit order is involved"
  LimitOrderData public emptyLimit;


  constructor() BaseStrategy(0x22E12A50e3ca49FB183074235cB1db84Fe4C716D, "PendleEZEthStrategy") {
    (SY, PT, YT) = market.readTokens();
    require(address(SY) == address(asset), "contract mismatch");

    asset.approve(address(router), type(uint256).max);
    PT.approve(address(router), type(uint256).max);
  }

  function _deployFunds(uint256  _amount) internal virtual override {
    router.swapExactSyForPt(address(this), address(market), _amount, 0, defaultApprox, emptyLimit);
  }


  function _freeFunds(uint256 _amount) internal virtual override {
    router.swapExactPtForSy(address(this), address(market), _amount, 0, emptyLimit);
  }

/**
`harvestAndReport()/_harvestAndReport()`: Called during reports to tell the strategy a trusted address has called it 
and to harvest any rewards re-deploy any loose funds and return the actual amount of funds the strategy holds.
 */
  function _harvestAndReport() internal virtual override returns (uint256 _totalAssets) {
    uint256 myBalancePt = PT.balanceOf(address(this));

    // redeem SY from PT if the era has finished
    uint256 netSyOut = router.redeemPyToSy(address(this), YT, netPyIn, minSyOut);

    // roll all of that SY into the next PT

    // update PT and YT in case they have changed
    (SY, PT, YT) = market.readTokens();
    _deployFunds(netSyOut);

    // return the value of that PT (how to calc?)
    return 0; //todo https://docs.pendle.finance/Developers/Integration/HowToIntegratePtAndLpOracle
  }
}

// instead of hardcoding a SY token should prob hardcode an ibToken?