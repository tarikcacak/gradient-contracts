// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CurveMath} from "./libs/CurveMath.sol";
import {ReentrancyGuard, Ownable2Step} from "./libs/Auth.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {IERC20, IUniswapV2Factory, IUniswapV2Pair, IUniswapV2Router02} from "./interfaces/IExternal.sol";

contract BondingCurve is ReentrancyGuard, Ownable2Step {

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant SALE_SUPPLY = 800_000_000e18;
    uint256 public constant LP_RESERVE = TOTAL_SUPPLY - SALE_SUPPLY;
    uint256 public constant BPS = 10_000;

    uint256 public constant MAX_TRADE_FEE_BPS = 200; // 2%
    uint256 public constant MAX_GRADUATION_FEE_BPS = 1_000; // 10%

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public immutable virtualEthStart;

    address public immutable router;
    address public immutable uniswapFactory;
    address public immutable weth;

    address public immutable treasury;

    address public factory;

    uint256 public tradeFeeBps = 100;
    uint256 public graduationFeeBps = 500;

    bool public buysPaused;

    uint256 public protocolFees;

    enum Status {
        NONE,
        BONDING,
        GRADUATING,
        GRADUATED
    }

    struct TokenState {
        uint256 vEth;
        uint256 vTok;
        uint256 realEth;
        address creator;
        address pair;
        Status status;
    }

    mapping(address => TokenState) public states;

    event TokenRegistered(
        address indexed token, address indexed creator, address indexed pair, uint256 vEth0, uint256 vTok0
    );

    event Trade(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 ethAmount, // gross ETH, inclusive of fee
        uint256 tokenAmount,
        uint256 fee,
        uint256 vEthAfter,
        uint256 vTokAfter,
        uint256 tokensSoldAfter
    );

    event GraduationStarted(address indexed token);
    event GraduationFailed(address indexed token, bytes reason);
    event Graduated(
        address indexed token,
        address indexed pair,
        uint256 ethToLp,
        uint256 tokensToLp,
        uint256 tokensBurned,
        uint256 lpBurned
    );
    event FeesClaimed(address indexed treasury, uint256 amount);
    event ParamsUpdated(uint256 tradeFeeBps, uint256 graduationFeeBps);
    event BuysPausedSet(bool paused);

    error NotFactory();
    error NotSelf();
    error FactoryAlreadySet();
    error AlreadyRegistered();
    error SupplyNotEscrowed();
    error NotBonding();
    error NotGraduating();
    error BuysArePaused();
    error Expired();
    error ZeroAmount();
    error Slippage();
    error ExceedsRealReserve();
    error FeeTooHigh();
    error EthTransferFailed();
    error ZeroAddress();

    constructor(address owner_, address treasury_, address router_, uint256 virtualEthStart_)
        Ownable2Step(owner_)
    {
        if (treasury_ == address(0) || router_ == address(0)) revert ZeroAddress();
        if (virtualEthStart_ == 0) revert ZeroAmount();

        treasury = treasury_;
        router = router_;
        uniswapFactory = IUniswapV2Router02(router_).factory();
        weth = IUniswapV2Router02(router_).WETH();
        virtualEthStart = virtualEthStart_;
    }

    function setFactory(address factory_) external onlyOwner {
        if (factory != address(0)) revert FactoryAlreadySet();
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    receive() external payable {
        protocolFees += msg.value;
    }

    function registerToken(address token, address creator) external onlyFactory returns (address pair) {
        TokenState storage s = states[token];
        if (s.status != Status.NONE) revert AlreadyRegistered();

        if (LaunchToken(token).balanceOf(address(this)) != TOTAL_SUPPLY) revert SupplyNotEscrowed();

        pair = IUniswapV2Factory(uniswapFactory).getPair(token, weth);
        if (pair == address(0)) {
            pair = IUniswapV2Factory(uniswapFactory).createPair(token, weth);
        }

        s.vEth = virtualEthStart;
        s.vTok = TOTAL_SUPPLY;
        s.realEth = 0;
        s.creator = creator;
        s.pair = pair;
        s.status = Status.BONDING;

        emit TokenRegistered(token, creator, pair, virtualEthStart, TOTAL_SUPPLY);
    }

    function collectCreateFee() external payable onlyFactory {
        protocolFees += msg.value;
    }

    function _feeOf(uint256 amount, uint256 feeBps) internal pure returns (uint256) {
        return (amount * feeBps + BPS - 1) / BPS;
    }

    function _quoteBuy(uint256 vEth, uint256 vTok, uint256 ethIn, uint256 feeBps)
        internal
        pure
        returns (uint256 tokensOut, uint256 fee, uint256 refund, uint256 netIn)
    {
        if (ethIn == 0) return (0, 0, 0, 0);

        uint256 grossUsed = ethIn;
        fee = _feeOf(ethIn, feeBps);
        netIn = ethIn - fee;
        tokensOut = CurveMath.buyQuote(vEth, vTok, netIn);

        uint256 maxOut = vTok - LP_RESERVE; // tokens still sellable on the curve
        if (tokensOut > maxOut) {

            tokensOut = maxOut;
            netIn = CurveMath.ethInForExactTokens(vEth, vTok, tokensOut);

            uint256 denom = BPS - feeBps;
            grossUsed = (netIn * BPS + denom - 1) / denom;
            if (grossUsed > ethIn) grossUsed = ethIn;

            fee = grossUsed - netIn;
        }

        refund = ethIn - grossUsed;
    }

    function quoteBuy(address token, uint256 ethIn)
        external
        view
        returns (uint256 tokensOut, uint256 fee, uint256 refund, uint256 priceImpactBps)
    {
        TokenState storage s = states[token];
        if (s.status != Status.BONDING) revert NotBonding();
        uint256 netIn;
        (tokensOut, fee, refund, netIn) = _quoteBuy(s.vEth, s.vTok, ethIn, tradeFeeBps);
        priceImpactBps = CurveMath.buyPriceImpactBps(s.vEth, s.vTok, netIn);
    }

    function quoteSell(address token, uint256 tokenIn)
        external
        view
        returns (uint256 ethOut, uint256 fee, uint256 priceImpactBps)
    {
        TokenState storage s = states[token];
        if (s.status != Status.BONDING) revert NotBonding();

        uint256 gross = CurveMath.sellQuote(s.vEth, s.vTok, tokenIn);
        fee = _feeOf(gross, tradeFeeBps);
        ethOut = gross - fee;

        uint256 spot = (tokenIn * s.vEth) / s.vTok;
        priceImpactBps = spot > gross ? ((spot - gross) * BPS) / spot : 0;
    }

    function priceOf(address token) external view returns (uint256) {
        TokenState storage s = states[token];
        if (s.status != Status.BONDING) return 0;
        return CurveMath.spotPriceE18(s.vEth, s.vTok);
    }

    function progressBps(address token) external view returns (uint256) {
        TokenState storage s = states[token];
        if (s.status == Status.NONE) return 0;
        if (s.status != Status.BONDING) return BPS;
        return ((TOTAL_SUPPLY - s.vTok) * BPS) / SALE_SUPPLY;
    }

    function buy(address token, uint256 minTokensOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256)
    {
        return _buy(token, msg.sender, minTokensOut, deadline);
    }

    function buyFor(address token, address recipient, uint256 minTokensOut, uint256 deadline)
        external
        payable
        onlyFactory
        nonReentrant
        returns (uint256)
    {
        return _buy(token, recipient, minTokensOut, deadline);
    }

    function _buy(address token, address recipient, uint256 minTokensOut, uint256 deadline)
        internal
        returns (uint256)
    {
        if (block.timestamp > deadline) revert Expired();
        if (buysPaused) revert BuysArePaused();
        if (msg.value == 0) revert ZeroAmount();

        TokenState storage s = states[token];
        if (s.status != Status.BONDING) revert NotBonding();

        (uint256 tokensOut, uint256 fee, uint256 refund, uint256 netIn) =
            _quoteBuy(s.vEth, s.vTok, msg.value, tradeFeeBps);

        if (tokensOut == 0) revert ZeroAmount();
        if (tokensOut < minTokensOut) revert Slippage();

        s.vEth += netIn;
        s.vTok -= tokensOut;
        s.realEth += netIn;
        protocolFees += fee;

        LaunchToken(token).transfer(recipient, tokensOut);
        if (refund > 0) _sendEth(recipient, refund);

        emit Trade(
            token, recipient, true, msg.value - refund, tokensOut, fee, s.vEth, s.vTok, TOTAL_SUPPLY - s.vTok
        );

        if (s.vTok == LP_RESERVE) {
            s.status = Status.GRADUATING;
            emit GraduationStarted(token);
            try this.performGraduation(token) {}
            catch (bytes memory reason) {
                s.status = Status.BONDING;
                emit GraduationFailed(token, reason);
            }
        }

        return tokensOut;
    }

    function sell(address token, uint256 tokenIn, uint256 minEthOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256)
    {
        if (block.timestamp > deadline) revert Expired();
        if (tokenIn == 0) revert ZeroAmount();

        TokenState storage s = states[token];
        if (s.status != Status.BONDING) revert NotBonding();

        uint256 gross = CurveMath.sellQuote(s.vEth, s.vTok, tokenIn);
        if (gross == 0) revert ZeroAmount();

        if (gross > s.realEth) revert ExceedsRealReserve();

        uint256 fee = _feeOf(gross, tradeFeeBps);
        uint256 netOut = gross - fee;
        if (netOut == 0) revert ZeroAmount();
        if (netOut < minEthOut) revert Slippage();

        s.vEth -= gross;
        s.vTok += tokenIn;
        s.realEth -= gross;
        protocolFees += fee;

        LaunchToken(token).transferFrom(msg.sender, address(this), tokenIn);
        _sendEth(msg.sender, netOut);

        emit Trade(token, msg.sender, false, gross, tokenIn, fee, s.vEth, s.vTok, TOTAL_SUPPLY - s.vTok);

        return netOut;
    }


    function graduate(address token) external nonReentrant {
        TokenState storage s = states[token];
        if (s.status == Status.BONDING) {
            if (s.vTok != LP_RESERVE) revert NotGraduating();
            s.status = Status.GRADUATING;
            emit GraduationStarted(token);
        }
        _graduate(token);
    }

    function performGraduation(address token) external {
        if (msg.sender != address(this)) revert NotSelf();
        _graduate(token);
    }

    function _graduate(address token) internal {
        TokenState storage s = states[token];
        if (s.status != Status.GRADUATING) revert NotGraduating();

        uint256 realEth = s.realEth;
        uint256 gradFee = (realEth * graduationFeeBps) / BPS;
        uint256 ethForLp = realEth - gradFee;

        uint256 tokensForLp = (ethForLp * s.vTok) / s.vEth;
        if (tokensForLp > LP_RESERVE) tokensForLp = LP_RESERVE;
        if (tokensForLp == 0 || ethForLp == 0) revert ZeroAmount();

        s.status = Status.GRADUATED;
        s.realEth = 0;
        s.vTok = 0;
        protocolFees += gradFee;

        LaunchToken(token).unlockTrading();
        _seedPool(token, s.pair, tokensForLp, ethForLp);
    }

    function _seedPool(address token, address pair, uint256 tokensForLp, uint256 ethForLp) internal {
        LaunchToken t = LaunchToken(token);
        bool virginPair = IUniswapV2Pair(pair).totalSupply() == 0;

        if (virginPair && (t.balanceOf(pair) > 0 || IERC20(weth).balanceOf(pair) > 0)) {
            IUniswapV2Pair(pair).skim(treasury);
        }

        t.approve(router, tokensForLp);

        (uint256 usedTok, uint256 usedEth, uint256 liquidity) = IUniswapV2Router02(router).addLiquidityETH{
            value: ethForLp
        }(
            token,
            tokensForLp,
            virginPair ? tokensForLp : 0,
            virginPair ? ethForLp : 0,
            address(this),
            block.timestamp
        );

        if (liquidity > 0) IERC20(pair).transfer(DEAD, liquidity);

        if (usedTok < tokensForLp) t.approve(router, 0);

        uint256 burned = LP_RESERVE - usedTok;
        if (burned > 0) t.burn(burned);

        emit Graduated(token, pair, usedEth, usedTok, burned, liquidity);
    }

    function claimFees() external nonReentrant {
        uint256 amount = protocolFees;
        if (amount == 0) revert ZeroAmount();
        protocolFees = 0;
        _sendEth(treasury, amount);
        emit FeesClaimed(treasury, amount);
    }

    function setFees(uint256 tradeFeeBps_, uint256 graduationFeeBps_) external onlyOwner {
        if (tradeFeeBps_ > MAX_TRADE_FEE_BPS || graduationFeeBps_ > MAX_GRADUATION_FEE_BPS) revert FeeTooHigh();
        tradeFeeBps = tradeFeeBps_;
        graduationFeeBps = graduationFeeBps_;
        emit ParamsUpdated(tradeFeeBps_, graduationFeeBps_);
    }

    function setBuysPaused(bool paused) external onlyOwner {
        buysPaused = paused;
        emit BuysPausedSet(paused);
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
