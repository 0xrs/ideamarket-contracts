// SPDX-License-Identifier: MIT
pragma solidity ^0.6.9;
pragma experimental ABIEncoderV2;

import "../util/Ownable.sol";
import "./IIdeaTokenExchange.sol";
import "./IIdeaToken.sol";
import "./IIdeaTokenFactory.sol";
import "./IInterestManager.sol";
import "@openzeppelin/upgrades/contracts/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/**
 * @title IdeaTokenExchange
 * @author Alexander Schlindwein
 *
 * @dev Exchanges Dai <-> IdeaTokens using a bonding curve. Sits behind a proxy
 */
contract IdeaTokenExchange is IIdeaTokenExchange, Initializable, Ownable {
    using SafeMath for uint256;

    struct TokenExchangeInfo {
        uint daiInToken; // The amount of Dai collected by trading
        uint interestShares;
        uint generatedInterest;
        uint withdrawnInterest;
    }

    mapping(address => TokenExchangeInfo) _tokensExchangeInfo;
    mapping(address => address) _authorizedInterestWithdrawers;

    address _tradingFeeRecipient;

    IIdeaTokenFactory _ideaTokenFactory;
    IInterestManager _interestManager;
    IERC20 _dai;

    /**
     * @dev Initializes the contract
     *
     * @param owner The owner of the contract
     * @param tradingFeeRecipient The address of the recipient of the trading fee
     * @param ideaTokenFactory The address of the IdeaTokenFactory
     * @param interestManager The address of the InterestManager
     * @param dai The address of Dai
     */
    function initialize(address owner,
                        address tradingFeeRecipient,
                        address ideaTokenFactory,
                        address interestManager,
                        address dai) external initializer {
        setOwnerInternal(owner);
        _tradingFeeRecipient = tradingFeeRecipient;
        _ideaTokenFactory = IIdeaTokenFactory(ideaTokenFactory);
        _interestManager = IInterestManager(interestManager);
        _dai = IERC20(dai);
    }

    /**
     * @dev Burns IdeaTokens in exchange for Dai
     *
     * @param ideaToken The IdeaToken to sell
     * @param amount The amount of IdeaTokens to sell
     * @param minPrice The minimum allowed price in Dai for selling `amount` IdeaTokens
     * @param recipient The recipient of the redeemed Dai
     */
    function sellTokens(address ideaToken, uint amount, uint minPrice, address recipient) external override {
        IIdeaTokenFactory.IDPair memory idPair = _ideaTokenFactory.getTokenIDPair(ideaToken);
        require(idPair.exists, "sellTokens: token does not exist");
        IIdeaTokenFactory.MarketDetails memory marketDetails = _ideaTokenFactory.getMarketDetailsByID(idPair.marketID);
        require(marketDetails.exists, "sellTokens: market does not exist");

        uint rawPrice = getRawPriceForSellingTokens(marketDetails.baseCost,
                                                    marketDetails.priceRise,
                                                    marketDetails.tokensPerInterval,
                                                    IERC20(ideaToken).totalSupply(),
                                                    amount);
        uint fee = rawPrice.mul(marketDetails.tradingFeeRate).div(marketDetails.tradingFeeRateScale);
        uint finalPrice = rawPrice.sub(fee);

        require(finalPrice >= minPrice, "sellTokens: price subceeds min price");
        require(IIdeaToken(ideaToken).balanceOf(msg.sender) >= amount, "sellTokens: not enough tokens");

        IIdeaToken(ideaToken).burn(msg.sender, amount);
        _interestManager.redeem(address(this), finalPrice.add(fee));

        require(_dai.transfer(recipient, finalPrice), "sellTokens: dai transfer failed");
        if(fee > 0) {
            require(_dai.transfer(_tradingFeeRecipient, fee), "sellTokens: dai fee transfer failed");
        }

        // TODO: Update tokens interest
    }

    /**
     * @dev Returns the price for selling IdeaTokens
     *
     * @param ideaToken The IdeaToken to sell
     * @param amount The amount of IdeaTokens to sell
     *
     * @return The price in Dai for selling `amount` IdeaTokens
     */
    function getPriceForSellingTokens(address ideaToken, uint amount) external view override returns (uint) {
        IIdeaTokenFactory.IDPair memory idPair = _ideaTokenFactory.getTokenIDPair(ideaToken);
        IIdeaTokenFactory.MarketDetails memory marketDetails = _ideaTokenFactory.getMarketDetailsByID(idPair.marketID);

        uint rawPrice = getRawPriceForSellingTokens(marketDetails.baseCost,
                                                    marketDetails.priceRise,
                                                    marketDetails.tokensPerInterval,
                                                    IERC20(ideaToken).totalSupply(),
                                                    amount);

        uint fee = rawPrice.mul(marketDetails.tradingFeeRate).div(marketDetails.tradingFeeRateScale);

        return rawPrice.sub(fee);
    }

    /**
     * @dev Returns the price for selling IdeaTokens without any fees applied
     *
     * @param b The baseCost of the token
     * @param r The priceRise of the token
     * @param t The amount of tokens per interval
     * @param supply The current total supply of the token
     * @param amount The amount of IdeaTokens to sell
     *
     * @return Returns the price for selling `amount` IdeaTokens without any fees applied
     */
    function getRawPriceForSellingTokens(uint b, uint r, uint t, uint supply, uint amount) internal pure returns (uint) {
        uint costForSupply = getCostFromZeroSupply(b, r, t, supply);
        uint costForSupplyMinusAmount = getCostFromZeroSupply(b, r, t, supply.sub(amount));

        uint rawCost = costForSupply.sub(costForSupplyMinusAmount);
        return rawCost;
    }

    /**
     * @dev Mints IdeaTokens in exchange for Dai
     *
     * @param ideaToken The IdeaToken to buy
     * @param amount The amount of IdeaTokens to buy
     * @param maxCost The maximum allowed cost in Dai to buy `amount` IdeaTokens
     * @param recipient The recipient of the bought IdeaTokens
     */
    function buyTokens(address ideaToken, uint amount, uint maxCost, address recipient) external override {
        IIdeaTokenFactory.IDPair memory idPair = _ideaTokenFactory.getTokenIDPair(ideaToken);
        require(idPair.exists, "buyTokens: token does not exist");
        IIdeaTokenFactory.MarketDetails memory marketDetails = _ideaTokenFactory.getMarketDetailsByID(idPair.marketID);
        require(marketDetails.exists, "buyTokens: market does not exist");

        uint rawCost = getRawCostForBuyingTokens(marketDetails.baseCost,
                                                 marketDetails.priceRise,
                                                 marketDetails.tokensPerInterval,
                                                 IERC20(ideaToken).totalSupply(),
                                                 amount);

        uint fee = rawCost.mul(marketDetails.tradingFeeRate).div(marketDetails.tradingFeeRateScale);
        uint finalCost = rawCost.add(fee);

        require(finalCost <= maxCost, "buyTokens: cost exceeds maxCost");
        require(_dai.allowance(msg.sender, address(this)) >= finalCost, "buyTokens: not enough allowance");
        require(_dai.transferFrom(msg.sender, address(_interestManager), rawCost), "buyTokens: dai transfer failed");

        if(fee > 0) {
            require(_dai.transferFrom(msg.sender, _tradingFeeRecipient, fee), "buyTokens: fee transfer failed");
        }

        // TODO: Update tokens interest

        _interestManager.invest(rawCost);
        IIdeaToken(ideaToken).mint(recipient, amount);
    }

    /**
     * @dev Returns the cost for buying IdeaTokens
     *
     * @param ideaToken The IdeaToken to sell
     * @param amount The amount of IdeaTokens to buy
     *
     * @return The cost in Dai for buying `amount` IdeaTokens
     */
    function getCostForBuyingTokens(address ideaToken, uint amount) external view override returns (uint) {
        IIdeaTokenFactory.IDPair memory idPair = _ideaTokenFactory.getTokenIDPair(ideaToken);
        IIdeaTokenFactory.MarketDetails memory marketDetails = _ideaTokenFactory.getMarketDetailsByID(idPair.marketID);

        uint rawCost = getRawCostForBuyingTokens(marketDetails.baseCost,
                                                 marketDetails.priceRise,
                                                 marketDetails.tokensPerInterval,
                                                 IERC20(ideaToken).totalSupply(),
                                                 amount);

        uint fee = rawCost.mul(marketDetails.tradingFeeRate).div(marketDetails.tradingFeeRateScale);

        return rawCost.add(fee);
    }

    /**
     * @dev Returns the cost for buying IdeaTokens without any fees applied
     *
     * @param b The baseCost of the token
     * @param r The priceRise of the token
     * @param t The amount of tokens per interval
     * @param supply The current total supply of the token
     * @param amount The amount of IdeaTokens to buy
     *
     * @return The cost for buying `amount` IdeaTokens without any fees applied
     */
    function getRawCostForBuyingTokens(uint b, uint r, uint t, uint supply, uint amount) internal pure returns (uint) {
        uint costForSupply = getCostFromZeroSupply(b, r, t, supply);
        uint costForSupplyPlusAmount = getCostFromZeroSupply(b, r, t, supply.add(amount));

        uint rawCost = costForSupplyPlusAmount.sub(costForSupply);
        return rawCost;
    }

    /**
     * @dev Returns the cost for buying IdeaTokens without any fees applied from 0 supply
     *
     * @param b The baseCost of the token
     * @param r The priceRise of the token
     * @param t The amount of tokens per interval
     * @param amount The amount of IdeaTokens to buy
     *
     * @return The cost for buying `amount` IdeaTokens without any fees applied from 0 supply
     */
    function getCostFromZeroSupply(uint b, uint r, uint t, uint amount) internal pure returns (uint) {
        uint n = amount.div(t);
        return getCostForCompletedIntervals(b, r, t, n).add(amount.sub(n.mul(t)).mul(b.add(n.mul(r)))).div(10**18);
    }

    /**
     * @dev Returns the cost for completed intervals from 0 supply
     *
     * @param b The baseCost of the token
     * @param r The priceRise of the token
     * @param t The amount of tokens per interval
     * @param n The amount of completed intervals
     *
     * @return Returns the cost for `n` completed intervals from 0 supply
     */
    function getCostForCompletedIntervals(uint b, uint r, uint t, uint n) internal pure returns (uint) {
        return n.mul(t).mul(b.sub(r)).add(r.mul(t).mul(n.mul(n.add(1)).div(2)));
    }

    /**
     * @dev Withdraws available interest for a publisher
     *
     * @param token The token from which the generated interest is to be withdrawn
     */
    function withdrawInterest(address token) external {
        require(_authorizedInterestWithdrawers[token] == msg.sender, "withdrawInterest: not authorized");

        TokenExchangeInfo storage exchangeInfo = _tokensExchangeInfo[token];
        exchangeInfo.generatedInterest = exchangeInfo.generatedInterest.add(getPendingInterest(token));

        uint interestPayable = exchangeInfo.generatedInterest.sub(exchangeInfo.withdrawnInterest);
        if(interestPayable == 0) {
            return;
        }

        exchangeInfo.withdrawnInterest = exchangeInfo.generatedInterest;
        _interestManager.redeem(msg.sender, interestPayable);
    }

    /**
     * @dev Returns the interest available to be paid out
     *
     * @param token The token from which the generated interest is to be withdrawn
     *
     * @return The interest available to be paid out
     */
    function getInterestPayable(address token) public returns (uint) {
        TokenExchangeInfo storage exchangeInfo = _tokensExchangeInfo[token];
        return exchangeInfo.generatedInterest.add(getPendingInterest(token)).sub(exchangeInfo.withdrawnInterest);
    }

    /**
     * @dev Returns the new interest which has been generated since last updated
     *
     * @param token The token for which to check the interest
     *
     * @return The new interest which has been generated since last updated
     */
    function getPendingInterest(address token) internal returns (uint) {
        TokenExchangeInfo storage exchangeInfo = _tokensExchangeInfo[token];

        _interestManager.accrueInterest();
        uint exchangeRate = _interestManager.getExchangeRate();

        uint want = exchangeInfo.interestShares.mul(exchangeRate); // TODO: Decimals
        uint have = exchangeInfo.daiInToken.add(exchangeInfo.generatedInterest).sub(exchangeInfo.withdrawnInterest);

        return want.sub(have);
    }

    /**
     * @dev Authorizes an address which is allowed to withdraw interest for a token
     *
     * @param token The token for which to authorize an address
     * @param withdrawer The address to be authorized
     */
    function authorizeInterestWithdrawer(address token, address withdrawer) external {
        require(msg.sender == _owner || msg.sender == _authorizedInterestWithdrawers[token], "authorizeInterestWithdrawer: not authorized");
        _authorizedInterestWithdrawers[token] = withdrawer;
    }
}