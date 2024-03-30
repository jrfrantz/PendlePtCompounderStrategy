// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;


import {IPAllActionV3} from "@pendle/core-v2/contracts/interfaces/IPAllActionV3.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {BaseStrategy} from "./BaseStrategy.sol";
contract PendleEZEthStrategy is BaseStrategy {

  constructor() BaseStrategy(0x22E12A50e3ca49FB183074235cB1db84Fe4C716D, "PendleEZEthStrategy") {}
  function _deployFunds(uint256 /* _amount */) internal virtual override {

    return;
  }

  function _freeFunds(uint256 /* _amount */) internal virtual override {
    return;
  }

  function _harvestAndReport() internal virtual override returns (uint256 _totalAssets) {
    return 0;
  }
}