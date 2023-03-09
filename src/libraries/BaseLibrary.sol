// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.8.14;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DiamondHelper, IDiamond, IDiamondLoupe} from "../DiamondHelper.sol";

import {IBaseStrategy} from "../interfaces/IBaseStrategy.sol";

interface IFactory {
    function protocol_fee_config()
        external
        view
        returns (uint16, uint32, address);
}

import "forge-std/console.sol";

/// TODO:
//       Bump sol version
//      Does base strategy need to hold errors and events?
//      add unchecked {} where applicable
//      add cloning
//      Add support interface for IERC165 https://github.com/mudgen/diamond-2-hardhat/blob/main/contracts/interfaces/IERC165.sol

library BaseLibrary {
    using SafeERC20 for ERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted whent the 'mangement' address is updtaed to 'newManagement'.
     */
    event UpdateManagement(address indexed newManagement);

    /**
     * @notice Emitted whent the 'keeper' address is updtaed to 'newKeeper'.
     */
    event UpdateKeeper(address indexed newKeeper);

    /**
     * @notice Emitted whent the 'performaneFee' is updtaed to 'newPerformanceFee'.
     */
    event UpdatePerformanceFee(uint16 newPerformanceFee);

    /**
     * @notice Emitted whent the 'performanceFeeRecipient' address is updtaed to 'newPerformanceFeeRecipient'.
     */
    event UpdatePerformanceFeeRecipient(
        address indexed newPerformanceFeeRecipient
    );

    /**
     * @notice Emitted whent the 'profitMaxUnlockTime' is updtaed to 'newProfitMaxUnlockTime'.
     */
    event UpdateProfitMaxUnlockTime(uint256 newProfitMaxUnlockTime);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    event Deposit(
        address indexed caller,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event Reported(
        uint256 profit,
        uint256 loss,
        uint256 performanceFees,
        uint256 protocolFees
    );

    event DiamondCut(
        IDiamond.FacetCut[] _diamondCut,
        address _init,
        bytes _calldata
    );

    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    error Unauthorized();

    /*//////////////////////////////////////////////////////////////
                        STORAGE STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct ERC20Data {
        ERC20 asset;
        string name;
        string symbol;
        uint256 totalSupply;
        uint256 INITIAL_CHAIN_ID;
        bytes32 INITIAL_DOMAIN_SEPARATOR;
        mapping(address => uint256) nonces;
        mapping(address => uint256) balances;
        mapping(address => mapping(address => uint256)) allowances;
    }

    struct AssetsData {
        uint256 totalIdle;
        uint256 totalDebt;
    }

    // TODO: this should be able to be packed better
    struct ProfitData {
        uint256 fullProfitUnlockDate;
        uint256 profitUnlockingRate;
        uint256 profitMaxUnlockTime;
        uint256 lastReport;
        uint16 performanceFee;
        address performanceFeeRecipient;
    }

    struct AccessData {
        address management;
        address keeper;
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyManagement() {
        isManagement();
        _;
    }

    modifier onlyKeepers() {
        isKeeper();
        _;
    }

    // These are left public to allow for the strategy to use them as well

    function isManagement() public view {
        if (msg.sender != _accessStorage().management) revert Unauthorized();
    }

    function isKeeper() public view {
        AccessData storage c = _accessStorage();
        if (msg.sender != c.management && msg.sender != c.keeper)
            revert Unauthorized();
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANT
    //////////////////////////////////////////////////////////////*/

    string private constant API_VERSION = "3.1.0";

    // NOTE: holder address based on expected location during tests
    address private constant diamondHelper =
        0xFEfC6BAF87cF3684058D62Da40Ff3A795946Ab06;

    uint256 private constant MAX_BPS = 10_000;
    uint256 private constant MAX_BPS_EXTENDED = 1_000_000_000_000;

    // Factory address NOTE: This will be set to deployed factory. deterministic address for testing is used now
    // TODO: how to account for protocol fees when the strategy is empty
    address private constant FACTORY =
        0x2a9e8fa175F45b235efDdD97d2727741EF4Eee63;

    /**
     * @dev Custom storgage slots that will store their specific structs for each strategies storage variables.
     *
     * Any storage updates done by the library effect the storage of the calling contract. Each of these variabless
     * point to the specic location that will be used to store the corresponding struct that holds that data.
     *
     * We intentionally use large strings in order to get high slots that that should allow for stratgists
     * to use any amount of storage in the implementations without worrying about collisions. The assets stuct is the
     * lowest and it sits a slot > 1e75.
     */

    // Storage slot to use for ERC20 variables
    // We intentionally may this string the longest to get the highest slot to avoid any collisions with the mappings
    // that may be set before the other structs have been fully instantiated.
    bytes32 private constant ERC20_STRATEGY_STORAGE =
        bytes32(uint256(keccak256("yearn.erc20.data.strategy.storage")) - 1);

    // storage slot for debt and idle
    bytes32 private constant ASSETS_STRATEGY_STORAGE =
        bytes32(uint256(keccak256("yearn.assets.strategy.storage")) - 1);

    // storage slot to use for report/ profit locking variables
    bytes32 private constant PROFIT_LOCKING_STORAGE =
        bytes32(uint256(keccak256("yearn.profit.locking.storage")) - 1);

    // storage slot to use for the permissined addresses for a strategy
    bytes32 private constant ACCESS_CONTROL_STORAGE =
        bytes32(uint256(keccak256("yearn.access.control.storage")) - 1);

    /*//////////////////////////////////////////////////////////////
                    STORAGE GETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _erc20Storage() private pure returns (ERC20Data storage e) {
        // Since STORAGE_SLOT is a constant, we have to put a variable
        // on the stack to access it from an inline assembly block.
        bytes32 slot = ERC20_STRATEGY_STORAGE;
        assembly {
            e.slot := slot
        }
    }

    function _assetsStorage() private pure returns (AssetsData storage a) {
        // Since STORAGE_SLOT is a constant, we have to put a variable
        // on the stack to access it from an inline assembly block.
        bytes32 slot = ASSETS_STRATEGY_STORAGE;
        assembly {
            a.slot := slot
        }
    }

    function _profitStorage() private pure returns (ProfitData storage p) {
        // Since STORAGE_SLOT is a constant, we have to put a variable
        // on the stack to access it from an inline assembly block.
        bytes32 slot = PROFIT_LOCKING_STORAGE;
        assembly {
            p.slot := slot
        }
    }

    function _accessStorage() private pure returns (AccessData storage c) {
        // Since STORAGE_SLOT is a constant, we have to put a variable
        // on the stack to access it from an inline assembly block.
        bytes32 slot = ACCESS_CONTROL_STORAGE;
        assembly {
            c.slot := slot
        }
    }

    /*//////////////////////////////////////////////////////////////
                INITILIZATION OF DEFAULT STORAGE
    //////////////////////////////////////////////////////////////*/

    function init(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _management
    ) external {
        // cache storage pointer
        ERC20Data storage e = _erc20Storage();

        // make sure we aren't initiliazed
        require(address(e.asset) == address(0), "!init");
        // set the strategys underlying asset
        e.asset = ERC20(_asset);
        // Set the Tokens name and symbol
        e.name = _name;
        e.symbol = _symbol;
        // Set initial chain id for permit replay protection
        e.INITIAL_CHAIN_ID = block.chainid;
        // Set the inital domain seperator for permit functions
        e.INITIAL_DOMAIN_SEPARATOR = _computeDomainSeparator();

        // set the default management address
        _accessStorage().management = _management;

        // Initiliaze the assets struct
        _assetsStorage().totalDebt = 0;

        // cache profit data pointer
        ProfitData storage p = _profitStorage();
        // default to a 10 day profit unlock period
        p.profitMaxUnlockTime = 10 days;
        // default to mangement as the treasury TODO: allow this to be customized
        p.performanceFeeRecipient = _management;
        // default to a 10% performance fee?
        p.performanceFee = 1_000;
        // set last report to this block
        p.lastReport = block.timestamp;

        // emit the standard DiamondCut event with the values from out helper contract
        emit DiamondCut(
            // struct containing the address of the library, the add enum and array of all function selectors
            DiamondHelper(diamondHelper).diamondCut(),
            // init address to call if applicable
            address(0),
            // call data to send the init address if applicable
            new bytes(0)
        );
    }

    /*//////////////////////////////////////////////////////////////
                        ERC4626 FUNCIONS
    //////////////////////////////////////////////////////////////*/

    // TODO: make sure we cannot have address(this) be the reciever on deposits

    function deposit(
        uint256 assets,
        address receiver
    ) public returns (uint256 shares) {
        require(receiver != address(this), "ERC4626: mint to self");
        // check lower than max
        require(
            assets <= maxDeposit(receiver),
            "ERC4626: deposit more than max"
        );

        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        // Need to transfer before minting or ERC777s could reenter.
        _erc20Storage().asset.safeTransferFrom(
            msg.sender,
            address(this),
            assets
        );

        // mint shares
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        // let strategy invest the funds if applicable
        _depositFunds(assets, false);
    }

    function mint(
        uint256 shares,
        address receiver
    ) public returns (uint256 assets) {
        require(receiver != address(this), "ERC4626: mint to self");
        require(shares <= maxMint(receiver), "ERC4626: mint more than max");

        assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        // Need to transfer before minting or ERC777s could reenter.
        _erc20Storage().asset.safeTransferFrom(
            msg.sender,
            address(this),
            assets
        );

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        // let strategy invest the funds if applicable
        _depositFunds(assets, false);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public returns (uint256 shares) {
        require(
            assets <= maxWithdraw(owner),
            "ERC4626: withdraw more than max"
        );

        shares = previewWithdraw(assets); // No need to check for rounding error, previewWithdraw rounds up.

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        _withdrawFunds(assets);

        _burn(owner, shares);

        _erc20Storage().asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public returns (uint256 assets) {
        require(shares <= maxRedeem(owner), "ERC4626: redeem more than max");

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        // withdraw if we dont have enough idle
        _withdrawFunds(assets);

        _burn(owner, shares);

        _erc20Storage().asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // post deposit/report hook to deposit any loose funds
    function _depositFunds(uint256 _newAmount, bool _reported) private {
        AssetsData storage a = _assetsStorage();
        ERC20 _asset = _erc20Storage().asset;
        // We will deposit up to current idle plus the new amount added
        uint256 toInvest = a.totalIdle + _newAmount;

        uint256 before = _asset.balanceOf(address(this));
        // invest if applicable
        IBaseStrategy(address(this)).invest(toInvest, _reported);

        // Always get the actual amount invested for higher accuracy
        // We double check the diff agianst toInvest to never underflow
        uint256 invested = Math.min(
            before - _asset.balanceOf(address(this)),
            toInvest
        );

        // adjust total Assets
        a.totalDebt += invested;
        // check if we invested all the loose asset
        a.totalIdle = toInvest - invested;
    }

    // TODO: Make this better
    //      This should return the actual amount freed so it can accept losses
    function _withdrawFunds(uint256 _amount) private {
        AssetsData storage a = _assetsStorage();
        ERC20 _asset = _erc20Storage().asset;

        uint256 idle = a.totalIdle;

        if (idle >= _amount) {
            // We dont need to withdraw anything
            a.totalIdle -= _amount;
        } else {
            // withdraw if we dont have enough idle
            uint256 before = _asset.balanceOf(address(this));
            // free what we need - what we have
            IBaseStrategy(address(this)).freeFunds(_amount - idle);

            // get the exact amount to account for loss or errors
            uint256 withdrawn = _asset.balanceOf(address(this)) - before;
            // TODO: should account for errors here to not overflow or over withdraw
            a.totalDebt -= withdrawn;

            // we are giving the full amount of our idle funds
            a.totalIdle = 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PROFIT LOCKING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Function for keepers to call to harvest and record all profits accrued.
     * @dev This should only ever be called through protected relays as swaps will likely occur.
     *
     * This will account for any gains/losses since the last report and charge fees accordingly.
     *
     * Any profit over the totalFees charged will be immediatly locked so there is no change in PricePerShare.
     * Then slowly unlocked over the 'maxProfitUnlockTime' each second based on the calculated 'profitUnlockingRate'.
     *
     * Any 'loss' or fees greater than 'profit' will attempted to be offset with any remaining locked shares from the last
     * report in order to reduce any negative impact to PPS.
     *
     * Will then recalculate the new time to unlock profits over and the rate based on a weighted average of any remaining time from the last
     * report and the new amount of shares to be locked.
     *
     * Finally will tell the strategy to _invest all idle funds which should include both the totalIdle before the call as well
     * any amount of 'asset' freed up during the totalInvested() call.
     *
     * @return profit The notional amount of gain since the last report in terms of 'asset' if any.
     * @return loss The notional amount of loss since the last report in terms of "asset" if any.
     */
    function report()
        external
        onlyKeepers
        returns (uint256 profit, uint256 loss)
    {
        // Cache storage pointer since its used again at the end
        AssetsData storage a = _assetsStorage();
        uint256 oldTotalAssets;
        unchecked {
            // Manuaully calculate totalAssets to save an sLoad
            oldTotalAssets = a.totalIdle + a.totalDebt;
        }

        // Calculate protocol fees before we burn shares and update lastReport
        (
            uint256 totalFees,
            address protocolFeesRecipient
        ) = _assessProtocolFees(oldTotalAssets);

        // burn unlocked shares
        _burnUnlockedShares();

        // Tell the strategy to report the real total assets it has.
        // It should account for invested and loose 'asset' so we can accuratly update the totalIdle to account
        // for sold but non-reinvested funds during reward harvesting.
        uint256 _invested = IBaseStrategy(address(this)).totalInvested();

        // Cache storage pointer
        ProfitData storage p = _profitStorage();
        uint256 performanceFees;

        // Calculate profit/loss
        if (_invested > oldTotalAssets) {
            // We have a profit
            profit = _invested - oldTotalAssets;

            // Asses performance fees
            performanceFees = (profit * p.performanceFee) / MAX_BPS;
            totalFees += performanceFees;
        } else {
            // We have a loss
            loss = oldTotalAssets - _invested;
        }

        // We need to get the shares for fees to issue at current PPS before any minting or burning
        uint256 sharesForFees = convertToShares(totalFees);
        uint256 sharesToLock;
        if (loss + totalFees >= profit) {
            // We have a net loss
            // Will try and unlock the difference between between the gain and the loss
            uint256 sharesToBurn = Math.min(
                convertToShares((loss + totalFees) - profit), // Check vault code
                balanceOf(address(this))
            );

            if (sharesToBurn > 0) {
                _burn(address(this), sharesToBurn);
            }
        } else {
            // we have a net profit
            // lock (profit - fees)
            sharesToLock = convertToShares(profit - totalFees);
            _mint(address(this), sharesToLock);
        }

        // Mint fees shares.
        if (sharesForFees > 0) {
            uint256 performanceFeeShares = (sharesForFees * performanceFees) /
                totalFees;
            if (performanceFeeShares > 0) {
                _mint(p.performanceFeeRecipient, performanceFeeShares);
            }

            if (sharesForFees - performanceFeeShares > 0) {
                _mint(
                    protocolFeesRecipient,
                    sharesForFees - performanceFeeShares
                );
            }
        }

        {
            // Scoped to avoid stack to deep errors
            uint256 remainingTime;
            uint256 _fullProfitUnlockDate = p.fullProfitUnlockDate;
            if (_fullProfitUnlockDate > block.timestamp) {
                remainingTime = _fullProfitUnlockDate - block.timestamp;
            }

            // Update unlocking rate and time to fully unlocked
            uint256 totalLockedShares = balanceOf(address(this));
            uint256 _profitMaxUnlockTime = p.profitMaxUnlockTime;
            if (totalLockedShares > 0 && _profitMaxUnlockTime > 0) {
                uint256 previouslyLockedShares = totalLockedShares -
                    sharesToLock;

                // new_profit_locking_period is a weighted average between the remaining time of the previously locked shares and the PROFIT_MAX_UNLOCK_TIME
                uint256 newProfitLockingPeriod = (previouslyLockedShares *
                    remainingTime +
                    sharesToLock *
                    _profitMaxUnlockTime) / totalLockedShares;

                p.profitUnlockingRate =
                    (totalLockedShares * MAX_BPS_EXTENDED) /
                    newProfitLockingPeriod;

                p.fullProfitUnlockDate =
                    block.timestamp +
                    newProfitLockingPeriod;
            } else {
                // NOTE: only setting this to 0 will turn in the desired effect, no need to update fullProfitUnlockDate
                p.profitUnlockingRate = 0;
            }
        }

        // Update storage variables
        uint256 newIdle = _erc20Storage().asset.balanceOf(address(this));
        // Set totalIdle to the actual amount we have loose
        a.totalIdle = newIdle;
        // the new debt should only be what is not loose
        a.totalDebt = _invested - newIdle;
        p.lastReport = block.timestamp;

        // emit event with info
        emit Reported(
            profit,
            loss,
            performanceFees,
            totalFees - performanceFees // Protocol fees
        );

        // invest any idle funds, tell strategy it is during a report call
        _depositFunds(0, true);
    }

    function _assessProtocolFees(
        uint256 _oldTotalAssets
    )
        private
        view
        returns (uint256 protocolFees, address protocolFeesRecipient)
    {
        (
            uint16 protocolFeeBps,
            uint32 protocolFeeLastChange,
            address _protocolFeesRecipient
        ) = IFactory(FACTORY).protocol_fee_config();

        if (protocolFeeBps > 0) {
            protocolFeesRecipient = _protocolFeesRecipient;
            // NOTE: charge fees since last report OR last fee change
            //      (this will mean less fees are charged after a change in protocol_fees, but fees should not change frequently)
            uint256 secondsSinceLastReport = Math.min(
                block.timestamp - _profitStorage().lastReport,
                block.timestamp - uint256(protocolFeeLastChange)
            );

            protocolFees =
                (uint256(protocolFeeBps) *
                    _oldTotalAssets *
                    secondsSinceLastReport) /
                24 /
                365 /
                3600 /
                MAX_BPS;
        }
    }

    function _burnUnlockedShares() private {
        uint256 unlcokdedShares = _unlockedShares();
        if (unlcokdedShares == 0) {
            return;
        }

        // update variables (done here to keep _unlcokdedShares() as a view function)
        if (_profitStorage().fullProfitUnlockDate > block.timestamp) {
            _profitStorage().lastReport = block.timestamp;
        }

        _burn(address(this), unlcokdedShares);
    }

    /*//////////////////////////////////////////////////////////////
                        TENDING LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice For a 'keeper' to 'tend' the strategy if a custom tendTrigger() is implemented.
     * @dev Both 'tendTrigger' and '_tend' will need to be overridden for this to be used.
     *
     * This will callback the internal '_tend' call in the BaseStrategy with the total current
     * amount available to the strategy to invest.
     *
     * Keepers are expected to use protected relays in tend calls so this can be used for illiquid
     * or manipulatable strategies to compound rewards, perform maintence or invest/withdraw funds.
     *
     * All accounting for totalDebt and totalIdle updates will be done here post '_tend'.
     *
     * This should never cause an increase in PPS. Total assets should be the same before and after
     *
     * A report() call will be needed to record the profit.
     */
    function tend() external onlyKeepers {
        AssetsData storage a = _assetsStorage();
        // Expected Behavior is this will get used twice so we cache it
        uint256 _totalIdle = a.totalIdle;
        ERC20 _asset = _erc20Storage().asset;

        uint256 beforeBalance = _asset.balanceOf(address(this));
        IBaseStrategy(address(this)).tendThis(_totalIdle);
        uint256 afterBalance = _asset.balanceOf(address(this));

        // Adjust storage according to the changes without adjusting totalAssets().
        if (beforeBalance > afterBalance) {
            // Idle funds were deposited.
            uint256 invested = Math.min(
                beforeBalance - afterBalance,
                _totalIdle
            );
            a.totalIdle -= invested;
            a.totalDebt += invested;
        } else if (afterBalance > beforeBalance) {
            // We default to use any funds freed as idle for cheaper withdraw/redeems.
            uint256 harvested = Math.min(
                afterBalance - beforeBalance,
                a.totalDebt
            );
            a.totalIdle += harvested;
            a.totalDebt -= harvested;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view returns (uint256) {
        AssetsData storage a = _assetsStorage();
        return a.totalIdle + a.totalDebt;
    }

    function totalSupply() public view returns (uint256) {
        return _erc20Storage().totalSupply - _unlockedShares();
    }

    function _unlockedShares() private view returns (uint256) {
        // should save 2 extra calls for most scenarios
        ProfitData storage p = _profitStorage();
        uint256 _fullProfitUnlockDate = p.fullProfitUnlockDate;
        uint256 unlockedShares;
        if (_fullProfitUnlockDate > block.timestamp) {
            unlockedShares =
                (p.profitUnlockingRate * (block.timestamp - p.lastReport)) /
                MAX_BPS_EXTENDED;
        } else if (_fullProfitUnlockDate != 0) {
            // All shares have been unlocked
            unlockedShares = _erc20Storage().balances[address(this)];
        }

        return unlockedShares;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply() is non-zero.

        return
            supply == 0
                ? assets
                : assets.mulDiv(supply, totalAssets(), Math.Rounding.Down);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply() is non-zero.

        return
            supply == 0
                ? shares
                : shares.mulDiv(totalAssets(), supply, Math.Rounding.Down);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply() is non-zero.

        return
            supply == 0
                ? shares
                : shares.mulDiv(totalAssets(), supply, Math.Rounding.Up);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply() is non-zero.

        return
            supply == 0
                ? assets
                : assets.mulDiv(supply, totalAssets(), Math.Rounding.Up);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    function maxDeposit(address _owner) public view returns (uint256) {
        return IBaseStrategy(address(this)).availableDepositLimit(_owner);
    }

    function maxMint(address _owner) public view returns (uint256 _maxMint) {
        _maxMint = IBaseStrategy(address(this)).availableDepositLimit(_owner);
        if (_maxMint != type(uint256).max) {
            _maxMint = convertToShares(_maxMint);
        }
    }

    function maxWithdraw(address _owner) public view returns (uint256) {
        return
            Math.min(
                convertToAssets(balanceOf(_owner)),
                IBaseStrategy(address(this)).availableWithdrawLimit(_owner)
            );
    }

    function maxRedeem(
        address _owner
    ) public view returns (uint256 _maxRedeem) {
        _maxRedeem = IBaseStrategy(address(this)).availableWithdrawLimit(
            _owner
        );
        if (_maxRedeem == type(uint256).max) {
            _maxRedeem = balanceOf(_owner);
        } else {
            _maxRedeem = Math.min(_maxRedeem, balanceOf(_owner));
        }
    }

    /*//////////////////////////////////////////////////////////////
                        Getter FUNCIONS
    //////////////////////////////////////////////////////////////*/

    // External view function to pull public variables from storage

    function apiVersion() external pure returns (string memory) {
        return API_VERSION;
    }

    function totalIdle() external view returns (uint256) {
        return _assetsStorage().totalIdle;
    }

    function totalDebt() external view returns (uint256) {
        return _assetsStorage().totalDebt;
    }

    function management() external view returns (address) {
        return _accessStorage().management;
    }

    function keeper() external view returns (address) {
        return _accessStorage().keeper;
    }

    function performanceFee() external view returns (uint16) {
        return _profitStorage().performanceFee;
    }

    function performanceFeeRecipient() external view returns (address) {
        return _profitStorage().performanceFeeRecipient;
    }

    function fullProfitUnlockDate() external view returns (uint256) {
        return _profitStorage().fullProfitUnlockDate;
    }

    function profitUnlockingRate() external view returns (uint256) {
        return _profitStorage().profitUnlockingRate;
    }

    function profitMaxUnlockTime() external view returns (uint256) {
        return _profitStorage().profitMaxUnlockTime;
    }

    function lastReport() external view returns (uint256) {
        return _profitStorage().lastReport;
    }

    function pricePerShare() external view returns (uint256) {
        return convertToAssets(10 ** IBaseStrategy(address(this)).decimals());
    }

    /*//////////////////////////////////////////////////////////////
                        SETTER FUNCIONS
    //////////////////////////////////////////////////////////////*/

    function setManagement(address _management) external onlyManagement {
        require(_management != address(0), "ZERO ADDRESS");
        _accessStorage().management = _management;

        emit UpdateManagement(_management);
    }

    function setKeeper(address _keeper) external onlyManagement {
        _accessStorage().keeper = _keeper;

        emit UpdateKeeper(_keeper);
    }

    function setPerformanceFee(uint16 _performanceFee) external onlyManagement {
        require(_performanceFee < MAX_BPS, "MAX BPS");
        _profitStorage().performanceFee = _performanceFee;

        emit UpdatePerformanceFee(_performanceFee);
    }

    function setPerformanceFeeRecipient(
        address _performanceFeeRecipient
    ) external onlyManagement {
        require(_performanceFeeRecipient != address(0), "ZERO ADDRESS");
        _profitStorage().performanceFeeRecipient = _performanceFeeRecipient;

        emit UpdatePerformanceFeeRecipient(_performanceFeeRecipient);
    }

    function setProfitMaxUnlockTime(
        uint256 _profitMaxUnlockTime
    ) external onlyManagement {
        _profitStorage().profitMaxUnlockTime = _profitMaxUnlockTime;

        emit UpdateProfitMaxUnlockTime(_profitMaxUnlockTime);
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL ERC-2535 VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets all facet addresses and their four byte function selectors.
     * @return facets_ Facet
     */
    function facets() external view returns (IDiamondLoupe.Facet[] memory) {
        return DiamondHelper(diamondHelper).facets();
    }

    /**
     * @notice Gets all the function selectors supported by a specific facet.
     * @param _facet The facet address.
     * @return facetFunctionSelectors_
     */
    function facetFunctionSelectors(
        address _facet
    ) external view returns (bytes4[] memory) {
        return DiamondHelper(diamondHelper).facetFunctionSelectors(_facet);
    }

    /**
     * @notice Get all the facet addresses used by a diamond.
     * @return facetAddresses_
     */
    function facetAddresses() external view returns (address[] memory) {
        return DiamondHelper(diamondHelper).facetAddresses();
    }

    /**
     * @notice Gets the facet that supports the given selector.
     * @dev If facet is not found return address(0).
     * @param _functionSelector The function selector.
     * @return facetAddress_ The facet address.
     */
    function facetAddress(
        bytes4 _functionSelector
    ) external view returns (address) {
        return DiamondHelper(diamondHelper).facetAddress(_functionSelector);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 FUNCIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the name of the token.
     * @return . The name the strategy is using for its token.
     */
    function name() public view returns (string memory) {
        return _erc20Storage().name;
    }

    /**
     * @notice Returns the symbol of the token, usually a shorter version of the name.
     * @dev Should be some iteration of 'ys + asset symbol'
     * @return . The symbol the strategy is using for its tokens.
     */
    function symbol() public view returns (string memory) {
        return _erc20Storage().symbol;
    }

    /**
     * @notice Returns the current balance for a given '_account'.
     * @dev If the '_account is the strategy then this will subtract the amount of
     * shares that have been unlocked since the last profit first.
     * @param account the address to return the balance for.
     * @return . The current balance in y shares of the '_account'.
     */
    function balanceOf(address account) public view returns (uint256) {
        if (account == address(this)) {
            return _erc20Storage().balances[account] - _unlockedShares();
        }
        return _erc20Storage().balances[account];
    }

    /**
     * @notice Transfer '_amount` of shares from `msg.sender` to `to`.
     * @dev
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - `to` cannot be the address of the strategy.
     * - the caller must have a balance of at least `_amount`.
     *
     * @param to The address shares will be transferred to.
     * @param amount The amount of shares to be transferred from sender.
     * @return . a boolean value indicating whether the operation succeeded.
     */
    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     * @param owner The address who owns the shares.
     * @param spender The address who would be moving the owners shares.
     * @return . The remaining amount of shares of `owner` that could be moved by `spender`.
     */
    function allowance(
        address owner,
        address spender
    ) public view returns (uint256) {
        return _erc20Storage().allowances[owner][spender];
    }

    /**
     * @notice Sets `amount` as the allowance of `spender` over the caller's tokens.
     * @dev
     *
     * NOTE: If `amount` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     *
     * @param spender the address to allow the shares to be moved by.
     * @param amount the amount of shares to allow `spender` to move.
     * @return . a boolean value indicating whether the operation succeeded.
     */
    function approve(address spender, uint256 amount) public returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * @dev
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP.
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `to` cannot be the address of the strategy.
     * - `from` must have a balance of at least `amount`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `amount`.
     *
     * Emits a {Transfer} event.
     *
     * @param from the address to be moving shares from.
     * @param to the address to be moving shares to.
     * @param amount the quantity of shares to move.
     * @return . a boolean value indicating whether the operation succeeded.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /**
     * @notice Atomically increases the allowance granted to `spender` by the caller.
     *
     * @dev This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - cannot give spender over uint256.max allowance
     *
     * @param spender the account that will be able to move the senders shares.
     * @param addedValue the extra amount to add to the current allowance.
     * @return . a boolean value indicating whether the operation succeeded.
     */
    function increaseAllowance(
        address spender,
        uint256 addedValue
    ) public returns (bool) {
        address owner = msg.sender;
        _approve(owner, spender, allowance(owner, spender) + addedValue);
        return true;
    }

    /**
     * @notice Atomically decreases the allowance granted to `spender` by the caller.
     *
     * @dev This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     *
     * @param spender the account that will be able to move less of the senders shares.
     * @param subtractedValue the amount to decrease the current allowance by.
     * @return . a boolean value indicating whether the operation succeeded.
     */
    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    ) public returns (bool) {
        address owner = msg.sender;
        _approve(owner, spender, allowance(owner, spender) - subtractedValue);
        return true;
    }

    /**
     * @dev Moves `amount` of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `to` cannot be the strategies address
     * - `from` must have a balance of at least `amount`.
     *
     */
    function _transfer(address from, address to, uint256 amount) private {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(to != address(this), "ERC20 transfer to strategy");
        ERC20Data storage e = _erc20Storage();

        e.balances[from] -= amount;
        unchecked {
            e.balances[to] += amount;
        }

        emit Transfer(from, to, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     *
     */
    function _mint(address account, uint256 amount) private {
        require(account != address(0), "ERC20: mint to the zero address");
        ERC20Data storage e = _erc20Storage();

        e.totalSupply += amount;
        unchecked {
            e.balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) private {
        require(account != address(0), "ERC20: burn from the zero address");
        ERC20Data storage e = _erc20Storage();

        e.balances[account] -= amount;
        unchecked {
            e.totalSupply -= amount;
        }
        emit Transfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _erc20Storage().allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `amount`.
     *
     * Does not update the allowance amount in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Might emit an {Approval} event.
     */
    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) private {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(
                currentAllowance >= amount,
                "ERC20: insufficient allowance"
            );
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                             EIP-2612 LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the current nonce for `owner`. This value must be
     * included whenever a signature is generated for {permit}.
     *
     * @dev Every successful call to {permit} increases ``owner``'s nonce by one. This
     * prevents a signature from being used multiple times.
     *
     * @param _owner the address of the account to return the nonce for.
     * @return . the current nonce for the account.
     */
    function nonces(address _owner) external view returns (uint256) {
        return _erc20Storage().nonces[_owner];
    }

    /**
     * @notice Sets `value` as the allowance of `spender` over ``owner``'s tokens,
     * given ``owner``'s signed approval.
     *
     * @dev IMPORTANT: The same issues {IERC20-approve} has related to transaction
     * ordering also apply here.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `deadline` must be a timestamp in the future.
     * - `v`, `r` and `s` must be a valid `secp256k1` signature from `owner`
     * over the EIP712-formatted function arguments.
     * - the signature must use ``owner``'s current nonce (see {nonces}).
     *
     * For more information on the signature format, see the
     * https://eips.ethereum.org/EIPS/eip-2612#specification[relevant EIP
     * section].
     */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        require(deadline >= block.timestamp, "ERC20: PERMIT_DEADLINE_EXPIRED");

        // Unchecked because the only math done is incrementing
        // the owner's nonce which cannot realistically overflow.
        unchecked {
            address recoveredAddress = ecrecover(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                                ),
                                owner,
                                spender,
                                value,
                                _erc20Storage().nonces[owner]++,
                                deadline
                            )
                        )
                    )
                ),
                v,
                r,
                s
            );

            require(
                recoveredAddress != address(0) && recoveredAddress == owner,
                "ERC20: INVALID_SIGNER"
            );

            _approve(recoveredAddress, spender, value);
        }
    }

    /**
     * @notice Returns the domain separator used in the encoding of the signature
     * for {permit}, as defined by {EIP712}.
     *
     * @dev This checks that the current chain id is the same as when the contract was deployed to
     * prevent replay attacks. If false it will calculate a new domain seperator based on the new chain id.
     *
     * @return . The domain seperator that will be used for any {permit} calls.
     */
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        ERC20Data storage e = _erc20Storage();
        return
            block.chainid == e.INITIAL_CHAIN_ID
                ? e.INITIAL_DOMAIN_SEPARATOR
                : _computeDomainSeparator();
    }

    /**
     * @dev Calculates and returns the domain seperator to be used in any
     * permit functions for the strategies {permit} calls.
     *
     * This will be used at the initilization of each new strategies storage.
     * It would then be used in the future in the case of any forks in which
     * the current chain id is not the same as the origin al.
     *
     */
    function _computeDomainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                    ),
                    keccak256(bytes(_erc20Storage().name)),
                    keccak256(bytes(API_VERSION)),
                    block.chainid,
                    address(this)
                )
            );
    }
}
