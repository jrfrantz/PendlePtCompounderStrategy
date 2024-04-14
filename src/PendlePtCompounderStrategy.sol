// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {
    IPAllActionV3,
    LimitOrderData,
    TokenInput,
    TokenOutput
} from "@pendle/core-v2/contracts/interfaces/IPAllActionV3.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {IPYieldToken} from "@pendle/core-v2/contracts/interfaces/IPYieldToken.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {ApproxParams} from "@pendle/core-v2/contracts/router/base/MarketApproxLib.sol";
import {PendlePtOracleLib} from "@pendle/core-v2/contracts/oracles/PendlePtOracleLib.sol";
import {IPPtOracle} from "@pendle/core-v2/contracts/interfaces/IPPtOracle.sol";
import {SwapData} from "@pendle/core-v2/contracts/router/swap-aggregator/IPSwapAggregator.sol";
import {BaseStrategy} from "./BaseStrategy.sol";

/**
 * Pendle's PT tokens give fixed yield on an
 * input token at a given maturity date.
 * This strategy automates harvesting fixed yields
 * at one maturity date and immediately deploying into a subsequent
 * market date. Since PT tokens are tradable, it also enables
 * liquid withdrawals by just selling PT for `asset`now.
 */
contract PendlePtCompounderStrategy is BaseStrategy {
    using PendlePtOracleLib for IPMarket;

    /*//////////////////////////////////////////////////////////////
                      CONSTANTS
    //////////////////////////////////////////////////////////////*/
    address internal constant NATIVE = address(0);
    
    ApproxParams public defaultApprox = ApproxParams(0, type(uint256).max, 0, 256, 1e14);
    LimitOrderData public emptyLimitOrder;
    SwapData public emptySwapData;
    uint32 public constant twapDuration = 900;
    
    
    /*//////////////////////////////////////////////////////////////
                      IMMUTABLES
    //////////////////////////////////////////////////////////////*/
    IPAllActionV3 public immutable router;
    IPPtOracle internal immutable ptOracle = IPPtOracle(0x66a1096C6366b2529274dF4f5D8247827fe4CEA8);


    /*//////////////////////////////////////////////////////////////
                      STATE
    //////////////////////////////////////////////////////////////*/
    // The market (duration) we currently hold PT in
    IPMarket public currentMarket;
    // The market (duration) to enter after `currentMarket` reaches maturity
    IPMarket public nextMarket;
    // When using a twap price estimate, the maximum permissable slippage
    uint256 public maxSlippageBps = 200;


    constructor(address _asset, address initialMarket) BaseStrategy(_asset, "PendlePTCompounder") {
        router = IPAllActionV3(0x00000000005BBB0EF59571E58418F9a4357b68A0);
        asset.approve(address(router), type(uint256).max);
        currentMarket = IPMarket(initialMarket);
        _initializeMarket(currentMarket);
    }

    /*//////////////////////////////////////////////////////////////
                      STRATEGY METHOD OVERRIDES
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice  Deploys funds into a market by buying PT in a Pendle `IPMarket`.
     * @dev     .
     * @param   _amount  The amount of `asset` to deploy.
     */
    function _deployFunds(uint256 _amount) internal virtual override {
        uint256 nativeValue = 0;
        if (address(asset) == NATIVE) {
            nativeValue = _amount;
        }
        TokenInput memory tokenInput = TokenInput({
            tokenIn: address(asset),
            netTokenIn: _amount,
            tokenMintSy: address(asset),
            pendleSwap: address(0),
            swapData: emptySwapData
        });

        router.swapExactTokenForPt{value: nativeValue}(
            address(this), address(currentMarket), /* minPtOut */ 0, defaultApprox, tokenInput, emptyLimitOrder
        );
    }

    /**
     * @notice  Sell PT to obtain `_amount`, using a twap to estimate the amount of PT we need to sell.
     * @dev     Allows for strategy-defined slippage. Throws if Pendle Market's PT<>Asset oracle is not initialized
     * @param   _amount  The amount of `asset` we want to get after selling PT.
     */
    function _freeFunds(uint256 _amount) internal virtual override {
        if (currentMarket.isExpired()) {
            // if maturity has been reached, redeem instead of market sell
            _redeemAssetFromPt(_amount);
            return;
        }

        // ensure oracle is initialized. See https://docs.pendle.finance/Developers/Integration/HowToIntegratePtAndLpOracle#third-initialize-the-oracle
        (bool increaseCardinalityRequired, , bool oldestObservationSatisfied) = ptOracle.getOracleState(address(currentMarket), twapDuration);
        require(!increaseCardinalityRequired && oldestObservationSatisfied, "oracle not initialized");
        
        uint256 ptRateInAsset = currentMarket.getPtToAssetRate(twapDuration);
        uint256 estdPtRequired = (_amount * 1e18) / ptRateInAsset;

        TokenOutput memory tokenOutput = TokenOutput({
            tokenOut: address(asset),
            minTokenOut: (estdPtRequired * (10_000 - maxSlippageBps)) / 10_000,
            tokenRedeemSy: address(asset),
            pendleSwap: address(0),
            swapData: emptySwapData
        });

        router.swapExactPtForToken(address(this), address(currentMarket), estdPtRequired, tokenOutput, emptyLimitOrder);
    }

    /**
     * @notice  Claim `asset` from expired PT and redeploy into next maturity date.
     * @dev     Throws if `nextMarket` is not set.
     * @return  _totalAssets  The amount of `asset` we got back from our PT (and redeployed).
     */
    function _harvestAndReport() internal virtual override returns (uint256 _totalAssets) {
        require(currentMarket.isExpired(), "market not done");
        require(address(nextMarket) != address(0), "next market not configured");

        // redeem all of our token
        (, IPPrincipalToken PT,) = currentMarket.readTokens();
        _redeemAssetFromPt(PT.balanceOf(address(this)));

        // bump market to next
        currentMarket = nextMarket;
        nextMarket = IPMarket(address(0));

        // redeploy back into PT for yields 😎
        _deployFunds(_totalAssets);
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice  Initializes a market (maturity date) by setting necessary approvals. See https://docs.pendle.finance/Developers/HighLevelArchitecture
     * @dev     Throws if `asset` cannot be swapped into and out of market.
     * @param   market  Represents a pendle market with a specific maturity date.
     */
    function _initializeMarket(IPMarket market) internal {
        (IStandardizedYield SY, IPPrincipalToken PT, IPYieldToken YT) = market.readTokens();
        address[] memory tokensIn = SY.getTokensIn();
        address[] memory tokensOut = SY.getTokensOut();

        bool isTokenIn = false;
        for (uint256 i = 0; i < tokensIn.length; ++i) {
            if (tokensIn[i] == address(asset)) isTokenIn = true;
        }
        bool isTokenOut = false;
        for (uint256 i = 0; i < tokensOut.length; ++i) {
            if (tokensOut[i] == address(asset)) isTokenOut = true;
        }
        require(isTokenIn && isTokenOut, "Cant use for token");

        SY.approve(address(router), type(uint256).max);
        PT.approve(address(router), type(uint256).max);
        YT.approve(address(router), type(uint256).max);
        market.approve(address(router), type(uint256).max);
    }

    /**
     * @notice  Redeem assets from a Principal Token (PT) after maturity has been reached.
     * @dev     It is not the responsibility of this method to ensure the market is expired.
     * @param   amtPtIn  Amount of Principal Token to redeem.
     * @return  amtAssetOut  Amount of asset that was converted.
     */
    function _redeemAssetFromPt(uint256 amtPtIn) internal returns (uint256 amtAssetOut) {
        (,, IPYieldToken YT) = currentMarket.readTokens();

        TokenOutput memory output = TokenOutput({
            tokenOut: address(asset),
            minTokenOut: 0,
            tokenRedeemSy: address(asset),
            pendleSwap: address(0),
            swapData: emptySwapData
        });

        (amtAssetOut,) = router.redeemPyToToken(address(this), address(YT), amtPtIn, output);
    }


    /*//////////////////////////////////////////////////////////////
                      MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice  Sets the market to roll capital into after maturity has been reached on `currentMarket`.
     * @dev     Throws if `asset` is not a token in and token out of `_nextMarket`.
     * @param   _nextMarket  Market that this strategy will enter after maturity reached on `currentMarket`.
     */
    function updateNextMarket(address _nextMarket) external onlyManagement {
        nextMarket = IPMarket(_nextMarket);
        _initializeMarket(nextMarket);
    }

    /**
     * @notice  Sets how much lower than the oracle's estimate we are willing to accept for instant withdrawals.
     * @dev     Throws if invalid number.
     * @param   _newSlippageBps  The new max slippage rate in BPS.
     */
    function setMaxSlippage(uint256 _newSlippageBps) external onlyManagement {
        require(0 <= _newSlippageBps && _newSlippageBps <= 10_000, "slippage between 0% and 100%");
        maxSlippageBps = _newSlippageBps;
    }
}
