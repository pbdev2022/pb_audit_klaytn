// SPDX-License-Identifier: MIT
pragma solidity ^0.5.6;

import "../errrpt/ErrorReporter.sol";
import "../asset/PToken.sol";
import "../_govtoken/Clank.sol";
import "../oracle/PriceOracle.sol";
import "../math/DoubleMath.sol";
import "../math/UintSafeConvert.sol";
import "./PBAdminInterface.sol";
import "./PBAdminStorage.sol";

contract PBAdminImpl is PBAdminStorage, PBAdminInterface, PBAdminErrorReporter, ExpMath, DoubleMath, UintSafeConvert {    
    using SafeMath for uint;

    event MarketListed(PToken pToken);
    event MarketEntered(PToken pToken, address account);
    event MarketExited(PToken pToken, address account);
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);
    event NewCollateralFactor(PToken pToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);
    event ActionPaused2(string action, bool pauseState);
    event ActionPaused3(PToken pToken, string action, bool pauseState);
    event DistributedSupplierPB(PToken indexed pToken, address indexed supplier, uint pbDelta, uint pbSupplyIndex);
    event NewBorrowCap(PToken indexed pToken, uint newBorrowCap);
    event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);
    event ClankGranted(address recipient, uint amount);
    event ClankSupplySpeedUpdated(PToken indexed pToken, uint newSpeed);

    uint224 public constant pbInitialIndex = 1e36;
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    address public clankAddress;

    constructor() public {
        admin = msg.sender;
    }

    function setClankAddress(address clankAddress_) public {
        require(msg.sender == admin, "Adm:only admin can set clank address");
        clankAddress = clankAddress_;
    }

    function getAssetsIn(address account) external view returns (PToken[] memory) {
        PToken[] memory assetsIn = accountAssets[account];
        return assetsIn;
    }

    function checkMembership(address account, PToken pToken) external view returns (bool) {
        return marketsAccountMembership[address(pToken)][account];
    }

    function enterMarkets(address[] memory pTokenAddrs) public returns (uint[] memory) {
        uint len = pTokenAddrs.length;
        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            PToken pToken = PToken(pTokenAddrs[i]);
            results[i] = uint(_addToMarketInternal(pToken, msg.sender));
        }

        return results;
    }    

    function _addToMarketInternal(PToken pToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(pToken)];
        if (!marketToJoin.isListed) {
            return Error.MARKET_NOT_LISTED;
        }

        if (marketsAccountMembership[address(pToken)][borrower] == false) {
            marketsAccountMembership[address(pToken)][borrower] = true;
            accountAssets[borrower].push(pToken);
            emit MarketEntered(pToken, borrower);            
        }

        return Error.NO_ERROR;
    }

    function exitMarket(address pTokenAddr) external returns (uint) {
        PToken pToken = PToken(pTokenAddr);

        (uint oErr, uint tokensHeld, uint amountOwed, uint amountGDROwed) = pToken.getAccountSnapshot(msg.sender);

        require(oErr == 0, "Adm:exitMarket-getAccountSnapshot failed"); 
        require(amountOwed == 0, "Adm:exitMarket-nonzero borrow balance");
        require(amountGDROwed == 0, "Adm:exitMarket-nonzero borrow GDR balance");

        uint allowed = _redeemAllowedInternal(pTokenAddr, msg.sender, tokensHeld);
        require(allowed == 0, "Adm:exitMarket-allowed!=0");

        if (!marketsAccountMembership[address(pToken)][msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        delete marketsAccountMembership[address(pToken)][msg.sender];

        PToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == pToken) {
                assetIndex = i;
                break;
            }
        }
        assert(assetIndex < len);

        PToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        emit MarketExited(pToken, msg.sender);

        return uint(Error.NO_ERROR);
    }

    function mintAllowed(address pTokenAddr, address minter, uint mintAmount) external returns (uint) {
        require(!mintGuardianPaused[pTokenAddr], "Adm:mint is paused");
        if (!markets[pTokenAddr].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!marketsAccountMembership[pTokenAddr][minter]) {    
            require(msg.sender == pTokenAddr, "Adm:sender must be pToken");
            Error err = _addToMarketInternal(PToken(msg.sender), minter);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }
            assert(marketsAccountMembership[pTokenAddr][minter]);
        }        

        mintAmount;

        _updateClankSupplyIndex(pTokenAddr);
        _distributeSupplierClank(pTokenAddr, minter);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowed(address pTokenAddr, address redeemer, uint redeemTokens) external returns (uint) {
        uint allowed = _redeemAllowedInternal(pTokenAddr, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        _updateClankSupplyIndex(pTokenAddr);
        _distributeSupplierClank(pTokenAddr, redeemer);

        return uint(Error.NO_ERROR);
    }

    function _redeemAllowedInternal(address pTokenAddr, address redeemer, uint redeemTokens) internal view returns (uint) {
        if (!markets[pTokenAddr].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!marketsAccountMembership[pTokenAddr][redeemer]) {    
            return uint(Error.NO_ERROR);
        }

        (Error err, , uint shortfall) = _getHypotheticalAccountLiquidityInternal(redeemer, PToken(pTokenAddr), redeemTokens, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }

        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    function redeemVerify(address pTokenAddr, address redeemer, uint redeemAmount, uint redeemTokens) external{
        pTokenAddr;
        redeemer;
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    function borrowAllowed(address pTokenAddr, address borrower, uint borrowAmount) external returns (uint) {
        require(!borrowGuardianPaused[pTokenAddr], "Adm:borrow is paused");

        if (!markets[pTokenAddr].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!marketsAccountMembership[pTokenAddr][borrower]) {    
            require(msg.sender == pTokenAddr, "Adm:sender must be pTokenAddr");
            Error err = _addToMarketInternal(PToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }
            assert(marketsAccountMembership[pTokenAddr][borrower]);
        }

        if (oracle.getUnderlyingPrice(PToken(pTokenAddr)) == 0) {
            return uint(Error.PRICE_ERROR);
        }

        uint borrowCap = borrowCaps[pTokenAddr];
        if (borrowCap != 0) {
            uint totalBorrows = PToken(pTokenAddr).totalBorrows();
            uint nextTotalBorrows = totalBorrows.add(borrowAmount);
            require(nextTotalBorrows < borrowCap, "Adm:market borrow cap reached");
        }

        (Error err2, , uint shortfall) = _getHypotheticalAccountLiquidityInternal(borrower, PToken(pTokenAddr), 0, borrowAmount);
        if (err2 != Error.NO_ERROR) {
            return uint(err2);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    function repayBorrowAllowed(
        address pTokenAddr,
        address payer,
        address borrower,
        uint repayAmount) external returns (uint) {

        payer;
        borrower;
        repayAmount;

        if (!markets[pTokenAddr].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        return uint(Error.NO_ERROR);
    }

    function liquidateBorrowAllowed(
        address pTokenAddrBorrowed,
        address pTokenAddrCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) external returns (uint) {

        liquidator;

        if (!markets[pTokenAddrBorrowed].isListed || !markets[pTokenAddrCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        uint borrowBalance = PToken(pTokenAddrBorrowed).borrowBalanceStored(borrower);

        if (isDeprecated(PToken(pTokenAddrBorrowed))) {
            require(borrowBalance >= repayAmount, "Adm:Can not repay more than the total borrow");
        } else {
            (Error err, , uint shortfall) = _getAccountLiquidityInternal(borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            if (shortfall == 0) {
                return uint(Error.INSUFFICIENT_SHORTFALL);
            }

            uint maxClose = mulExpUnitTrunc(Exp({mantissa: closeFactorMantissa}), borrowBalance);
            if (repayAmount > maxClose) {
                return uint(Error.TOO_MUCH_REPAY);
            }
        }
        return uint(Error.NO_ERROR);
    }

    function seizeAllowed(
        address pTokenAddrCollateral,
        address pTokenAddrBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external returns (uint) {

        require(!seizeGuardianPaused, "Adm:seize is paused");

        seizeTokens;

        if (!markets[pTokenAddrCollateral].isListed || !markets[pTokenAddrBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (PToken(pTokenAddrCollateral).pbAdmin() != PToken(pTokenAddrBorrowed).pbAdmin()) {
            return uint(Error.PB_ADMIN_MISMATCH);
        }

        _updateClankSupplyIndex(pTokenAddrCollateral);
        _distributeSupplierClank(pTokenAddrCollateral, borrower);
        _distributeSupplierClank(pTokenAddrCollateral, liquidator);

        return uint(Error.NO_ERROR);
    }

    function transferAllowed(address pTokenAddr, address src, address dst, uint transferTokens) external returns (uint) {
        require(!transferGuardianPaused, "Adm:transfer is paused");

        uint allowed = _redeemAllowedInternal(pTokenAddr, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        _updateClankSupplyIndex(pTokenAddr);
        _distributeSupplierClank(pTokenAddr, src);
        _distributeSupplierClank(pTokenAddr, dst);

        return uint(Error.NO_ERROR);
    }

    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint pTokenBalance;
        uint borrowBalance;
        uint borrowGDRBalance;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = _getHypotheticalAccountLiquidityInternal(account, PToken(address(0)), 0, 0);
        return (uint(err), liquidity, shortfall);
    }

    function _getAccountLiquidityInternal(address account) internal view returns (Error, uint, uint) {
        return _getHypotheticalAccountLiquidityInternal(account, PToken(address(0)), 0, 0);
    }

    function getHypotheticalAccountLiquidity(
        address account,
        address pTokenAddrModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint, uint) {

        (Error err, uint liquidity, uint shortfall) = _getHypotheticalAccountLiquidityInternal(account, PToken(pTokenAddrModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    function _getHypotheticalAccountLiquidityInternal(
        address account,
        PToken pTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (Error, uint, uint) {

        if (address(oracle) == address(0)) {
            return (Error.PRICE_ERROR, 0, 0);            
        }

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;

        PToken[] memory assets = accountAssets[account];

        for (uint i = 0; i < assets.length; i++) {
            PToken asset = assets[i];

            (oErr, vars.pTokenBalance, vars.borrowBalance, vars.borrowGDRBalance) = asset.getAccountSnapshot(account);

            if (oErr != 0) { 
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});

            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});
            vars.tokensToDenom = mulExp(vars.collateralFactor, vars.oraclePrice);
            vars.sumCollateral = mulExpUintTruncAddUint(vars.tokensToDenom, vars.pTokenBalance, vars.sumCollateral);
            vars.sumBorrowPlusEffects = mulExpUintTruncAddUint(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

            if (asset == pTokenModify) {
                vars.sumBorrowPlusEffects = mulExpUintTruncAddUint(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);
                vars.sumBorrowPlusEffects = mulExpUintTruncAddUint(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
            }
        }

        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    function liquidateCalculateSeizeTokens(address pTokenAddrBorrowed, address pTokenAddrCollateral, uint actualRepayAmount) external view returns (uint, uint) {
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(PToken(pTokenAddrBorrowed));
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(PToken(pTokenAddrCollateral));

        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mulExp(Exp({mantissa: liquidationIncentiveMantissa}), Exp({mantissa: priceBorrowedMantissa}));
        denominator = Exp({mantissa: priceCollateralMantissa});
        ratio = divExp(numerator, denominator);

        seizeTokens = mulUintExp(actualRepayAmount, ratio);

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    function setPriceOracle(PriceOracle newOracle) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        PriceOracle oldOracle = oracle;
        oracle = newOracle;

        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    function setCloseFactor(uint newCloseFactorMantissa) external {
    	require(msg.sender == admin, "Adm:only admin can set close factor");

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;

        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);
    }

    function setCollateralFactor(PToken pToken, uint newCollateralFactorMantissa) external {
    	require(msg.sender == admin, "Adm:only admin can set collateral factor");

        Market storage market = markets[address(pToken)];
    	require(market.isListed, "Adm:market not listed");

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});

        require(!lessThanExp(highLimit, newCollateralFactorExp), "Adm:invalid collateral factor");
        require(address(oracle) != address(0), "Adm:price oracle not set yet");
        require (!(newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(pToken) == 0) , "Adm:collateral factor price error");

        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        emit NewCollateralFactor(pToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);
    }

    function setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external {
    	require(msg.sender == admin, "Adm:unauthorized");

        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);
    }

    function supportMarket(PToken pToken) external {
    	require(msg.sender == admin, "Adm:unauthorized");
    	require(markets[address(pToken)].isListed == false, "Adm:market already listed");
        require(pToken.isPToken(), "Adm:invalid pToken");

        markets[address(pToken)] = Market({isListed: true, collateralFactorMantissa: 0});

        _addMarketInternal(address(pToken));
        _initializeMarket(address(pToken));

        emit MarketListed(pToken);
    }

    function unlistMarket(PToken pToken) public {
    	require(msg.sender == admin, "Adm:unauthorized");
    	require(markets[address(pToken)].isListed == true, "Adm:market note listed");

        markets[address(pToken)].isListed = false;
        _removeMarketInternal(address(pToken));
    }    

    function _addMarketInternal(address pTokenAddr) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != PToken(pTokenAddr), "Adm:market already added");
        }
        allMarkets.push(PToken(pTokenAddr));
    }

    function _removeMarketInternal(address pTokenAddr) internal {
        uint len = allMarkets.length;
        require(len > 0, "Adm:empty allMarkets");
        uint marketIndex = allMarkets.length;
        for (uint i = 0; i < len; i ++) {
            if (allMarkets[i] == PToken(pTokenAddr)) {
                marketIndex = i;
                break;
            }
        }
        assert (marketIndex < len);
        allMarkets[marketIndex] = allMarkets[len - 1];
        allMarkets.pop();
    }

    function _initializeMarket(address pTokenAddr) internal {
        uint32 blockNumber = safe32(getBlockNumber());

        PBMarketState storage supplyState = clankSupplyState[pTokenAddr];

        if (supplyState.index == 0) {
            supplyState.index = pbInitialIndex;
        }

        supplyState.block = blockNumber;
    }

    function setMarketBorrowCaps(PToken[] calldata pTokens, uint[] calldata newBorrowCaps) external {
    	require(msg.sender == admin || msg.sender == borrowCapGuardian, "Adm:only admin or borrow cap guardian can set borrow caps"); 

        uint numMarkets = pTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "Adm:invalid input");

        for(uint i = 0; i < numMarkets; i++) {
            borrowCaps[address(pTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(pTokens[i], newBorrowCaps[i]);
        }
    }

    function setBorrowCapGuardian(address newBorrowCapGuardian) external {
        require(msg.sender == admin, "Adm:only admin can set borrow cap guardian");
        address oldBorrowCapGuardian = borrowCapGuardian;
        borrowCapGuardian = newBorrowCapGuardian;
        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    function setPauseGuardian(address newPauseGuardian) public {
    	require(msg.sender == admin, "Adm:unauthorized");        
        address oldPauseGuardian = pauseGuardian;
        pauseGuardian = newPauseGuardian;
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);
    }

    function setMintPaused(PToken pToken, bool state) public returns (bool) {
        require(markets[address(pToken)].isListed, "Adm:cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "Adm:only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "Adm:only admin can unpause");

        mintGuardianPaused[address(pToken)] = state;
        emit ActionPaused3(pToken, "Mint", state);
        return state;
    }

    function setBorrowPaused(PToken pToken, bool state) public returns (bool) {
        require(markets[address(pToken)].isListed, "Adm:cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "Adm:only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "Adm:only admin can unpause");

        borrowGuardianPaused[address(pToken)] = state;
        emit ActionPaused3(pToken, "Borrow", state);
        return state;
    }

    function setTransferPaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "Adm:only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "Adm:only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPaused2("Transfer", state);
        return state;
    }

    function setSeizePaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "Adm:only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "Adm:only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPaused2("Seize", state);
        return state;
    }

    function _updateClankSupplyIndex(address pTokenAddr) internal {
        PBMarketState storage supplyState = clankSupplyState[pTokenAddr];
        uint supplySpeed = clankSupplySpeeds[pTokenAddr];
        uint32 blockNumber = safe32(getBlockNumber());
        uint deltaBlocks = uint(blockNumber).sub(uint(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint supplyTokens = PToken(pTokenAddr).totalSupply();
            uint clankAccrued = deltaBlocks.mul(supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fractionDouble(clankAccrued, supplyTokens) : Double({mantissa: 0});
            supplyState.index = safe224(addDouble(Double({mantissa: supplyState.index}), ratio).mantissa);
            supplyState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            supplyState.block = blockNumber;
        }
    }

    function _distributeSupplierClank(address pTokenAddr, address supplier) internal {
        PBMarketState storage supplyState = clankSupplyState[pTokenAddr];
        uint clankSupplyIndex = supplyState.index;
        uint supplierIndex = clankSupplierIndex[pTokenAddr][supplier];

        clankSupplierIndex[pTokenAddr][supplier] = clankSupplyIndex;

        if (supplierIndex == 0 && clankSupplyIndex >= pbInitialIndex) {
            supplierIndex = pbInitialIndex;
        }

        if (clankSupplyIndex > supplierIndex) {
            Double memory deltaIndex = Double({mantissa: clankSupplyIndex.sub(supplierIndex)});            
            uint supplierTokens = PToken(pTokenAddr).balanceOf(supplier);
            uint supplierDelta = mulUintDouble(supplierTokens, deltaIndex);
            uint supplierAccrued = pTokenClankAccrued[pTokenAddr][supplier].add(supplierDelta);
            pTokenClankAccrued[pTokenAddr][supplier] = supplierAccrued;

            emit DistributedSupplierPB(PToken(pTokenAddr), supplier, supplierDelta, clankSupplyIndex);
        }
    }

    function claimClank(address holder) public {
        claimClank2(holder, allMarkets);
    }

    function claimClank2(address holder, PToken[] memory pTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimClank3(holders, pTokens);
    }

    function claimClank3(address[] memory holders, PToken[] memory pTokens) public {
        for (uint i = 0; i < pTokens.length; i++) {
            PToken pToken = pTokens[i];
            require(markets[address(pToken)].isListed, "Adm:market must be listed");
            _updateClankSupplyIndex(address(pToken));
            for (uint j = 0; j < holders.length; j++) {
                _distributeSupplierClank(address(pToken), holders[j]);
            }
        }

        for (uint j = 0 ; j < holders.length ; j++) {
            for (uint k = 0 ; k < pTokens.length ; k++) {
                PToken pToken = pTokens[k];
                address holder = holders[j];
                uint256 clankAccrued = pTokenClankAccrued[address(pToken)][holder];
                if (clankAccrued > 0) {
                    uint256 grantedClank = _grantClankInternal(holder, clankAccrued);
                    if (grantedClank == 0) {
                        pTokenClankAccrued[address(pToken)][holder] = 0;
                    }
                }    
            }
        }
    }

    function _grantClankInternal(address user, uint amount) internal returns (uint) {    
        Clank clank = Clank(getClankAddress());
        uint clankRemaining = clank.balanceOf(address(this));
        if (amount > 0 && amount <= clankRemaining) {
            clank.transfer(user, amount);
            return 0;
        }
        return amount;
    }

    function grantClank(address recipient, uint amount) public {   
        require(msg.sender == admin, "Adm:only admin can grant Clank");
        uint amountLeft = _grantClankInternal(recipient, amount);
        require(amountLeft == 0, "Adm:insufficient Clank for grant");
        emit ClankGranted(recipient, amount);
    }

    function setClankSpeed(PToken[] memory pTokens, uint[] memory supplySpeeds) public {
        require(msg.sender == admin, "Adm:only admin can set clank speed");        

        uint numTokens = pTokens.length;
        require(numTokens == supplySpeeds.length, "Adm:_setCompSpeeds invalid input");

        for (uint i = 0; i < numTokens; ++i) {
            _setClankSpeedInternal(pTokens[i], supplySpeeds[i]);
        }
    }    

    function _setClankSpeedInternal(PToken pToken, uint supplySpeed) internal {
        Market storage market = markets[address(pToken)];
        require(market.isListed, "comp market is not listed");

        if (clankSupplySpeeds[address(pToken)] != supplySpeed) {
            _updateClankSupplyIndex(address(pToken));

            clankSupplySpeeds[address(pToken)] = supplySpeed;
            emit ClankSupplySpeedUpdated(pToken, supplySpeed);
        }
    }

    function getAllMarkets() public view returns (PToken[] memory) {
        return allMarkets;
    }

    function isDeprecated(PToken pToken) public view returns (bool) {
        return
            markets[address(pToken)].collateralFactorMantissa == 0 && 
            borrowGuardianPaused[address(pToken)] == true && 
            pToken.reserveFactorMantissa() == 1e18
        ;
    }

    function getAccruedTokens(address pTokenAddr, address holder) external view returns (uint256) {
        return pTokenClankAccrued[pTokenAddr][holder];
    }

    function getClankBalance(address holder) external view returns (uint256) {
        Clank clank = Clank(getClankAddress());
        return clank.balanceOf(holder);
    }

    function clankTransferIn(address pTokenAddr, address payer, uint pTokenAmount) external returns (bool) {
        Clank clank = Clank(getClankAddress());
        uint256 clankAmount = pTokenAmount.mul(oracle.getUnderlyingPrice(PToken(pTokenAddr))).div(oracle.getDirectPrice(getClankAddress()));
        return clank.transferFrom(payer, address(this), clankAmount);
    }

    function getBlockNumber() public view returns (uint) {
        return block.number;
    }

    function getClankAddress() public view returns (address) {
        require(clankAddress != address(0), "Adm:clank address is not set yet");
        return clankAddress;
    }
}
