// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "./libs/Clones.sol";
import {Ownable2Step} from "./libs/Auth.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {BondingCurve} from "./BondingCurve.sol";

contract TokenFactory is Ownable2Step {
    address public immutable implementation;
    BondingCurve public immutable curve;

    uint256 public createFee;

    address[] public allTokens;
    mapping(address => address[]) public tokensByCreator;

    event TokenCreated(
        address indexed token,
        address indexed creator,
        address indexed pair,
        string name,
        string symbol,
        string metadataURI,
        uint256 vEth0,
        uint256 vTok0,
        uint256 index
    );
    event CreateFeeUpdated(uint256 createFee);

    error InsufficientFee();
    error EmptyMetadata();

    constructor(address owner_, address curve_, uint256 createFee_) Ownable2Step(owner_) {
        curve = BondingCurve(payable(curve_));
        implementation = address(new LaunchToken());
        createFee = createFee_;
    }

    function createToken(string calldata name_, string calldata symbol_, string calldata metadataURI)
        external
        payable
        returns (address token)
    {
        if (msg.value < createFee) revert InsufficientFee();
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert EmptyMetadata();

        token = Clones.clone(implementation);
        LaunchToken(token).initialize(name_, symbol_, address(curve), curve.TOTAL_SUPPLY());

        address pair = curve.registerToken(token, msg.sender);

        allTokens.push(token);
        tokensByCreator[msg.sender].push(token);

        emit TokenCreated(
            token,
            msg.sender,
            pair,
            name_,
            symbol_,
            metadataURI,
            curve.virtualEthStart(),
            curve.TOTAL_SUPPLY(),
            allTokens.length - 1
        );

        uint256 fee = createFee;
        if (fee > 0) curve.collectCreateFee{value: fee}();

        uint256 initialBuy = msg.value - fee;
        if (initialBuy > 0) {
            curve.buyFor{value: initialBuy}(token, msg.sender, 0, block.timestamp);
        }
    }

    function totalTokens() external view returns (uint256) {
        return allTokens.length;
    }

    function createdBy(address creator) external view returns (address[] memory) {
        return tokensByCreator[creator];
    }

    function setCreateFee(uint256 createFee_) external onlyOwner {
        createFee = createFee_;
        emit CreateFeeUpdated(createFee_);
    }
}
