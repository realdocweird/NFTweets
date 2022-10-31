// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@chainlink/contracts/src/v0.8/KeeperCompatible.sol";

interface INFTWEETS{
    function safeMint(address to, string memory uri, bytes32 tweetHash) external;
}

contract NFTweetMinterV1 is Pausable, AccessControl, KeeperCompatibleInterface {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    INFTWEETS NFTWEETS;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    IERC721 public NFTweets;
    IERC20 public AcceptedPayment;
    uint256 public MinPrice = 1 ether; // in TOR
    uint256 public OfferDevFee = 1 ether; // in FTM
    uint256 public SaleDevFee = 10; // %
    uint8 public maxEndTime = 30;
    address public DevWallet ;
    address AllowedSigner = address(0x1Bc9E9b22ae1e70b36cab0a0E7DdBEAb10A0C27D);

    struct Order {
        bool ended;
        uint256 tweetId;
        uint256 tweetCreatorId;
        uint256 offerAmount;
        uint256 listedAt;
        uint256 endTime;
        address maker;        
    }

    mapping(uint256 => Order) public orders; // tweetId => Order
    uint256[] public tweetOrders;
    mapping(bytes32 => bool) public usedSignatures; // used signatures

    uint public immutable interval;
    uint public lastTimeStamp;

    event mintOfferSent(uint256 indexed tweetId, address indexed requestUser, uint256 offerAmount, uint256 endTime);
    event mintOfferAccepted(uint256 indexed tweetId, address indexed requestUser, address indexed receiverUser, string uri, uint256 amount);

    
    constructor(uint updateInterval) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        DevWallet = msg.sender;
        interval = updateInterval;
        lastTimeStamp = block.timestamp;
    }

    function setMintOffer(uint256 _tweetId, uint256 _tweetCreatorId, uint256 _offerAmount, uint8 _endTime) public payable{
        require(msg.value >= OfferDevFee, "Insufficient funds");
        require(_offerAmount >= MinPrice, "Offer too low");
        require(_endTime <= maxEndTime , "Reduce endtime");
        require(_offerAmount > orders[_tweetId].offerAmount , "There is already an higher offer");
        require(AcceptedPayment.allowance(msg.sender, address(this)) >= _offerAmount && AcceptedPayment.balanceOf(msg.sender) >= _offerAmount, "Insufficient allowance or funds");
        AcceptedPayment.safeTransferFrom(msg.sender, address(this), _offerAmount);
        if (orders[_tweetId].offerAmount > 0) { // if there is an active offer
            AcceptedPayment.transfer(orders[_tweetId].maker,orders[_tweetId].offerAmount);
        }
        Order storage order = orders[_tweetId];
        order.ended = false;
        order.tweetId = _tweetId;
        order.tweetCreatorId = _tweetCreatorId;
        order.offerAmount = _offerAmount;
        order.listedAt = block.timestamp;
        order.endTime = block.timestamp + (_endTime * 1 days);
        order.maker = msg.sender;        
        tweetOrders.push(_tweetId);
        emit mintOfferSent(_tweetId, msg.sender, _offerAmount, block.timestamp + (_endTime * 1 days));
    }

    function VerifyTweetData(bytes32 _hashedMessage, uint8 _v, bytes32 _r, bytes32 _s, uint256 _tweetId, string memory uri) internal view returns (bool) {
        require(usedSignatures[_hashedMessage] != true, "Signature expired");
        bytes memory prefix = "\x19Ethereum Signed Message:\n32";
        bytes32 prefixedHashMessage = keccak256(abi.encodePacked(prefix, _hashedMessage));        
        address signer = ecrecover(prefixedHashMessage, _v, _r, _s);
        require(AllowedSigner == signer, "Signer not allowed");
        bytes32 hashTweetOwner = keccak256(abi.encodePacked( address(msg.sender), _tweetId, uri ) );
        require(hashTweetOwner == _hashedMessage, "Input data is not valid");
        return true;
    }

    function mintSelfTweet(uint256 _tweetId, string memory uri, bytes32 _hashedMessage, uint8 _v, bytes32 _r, bytes32 _s) public payable{
        require(orders[_tweetId].ended != true, "Already sold");
        require(msg.value >= OfferDevFee, "Insufficient funds");
        require(VerifyTweetData(_hashedMessage, _v, _r, _s, _tweetId, uri), "Data is not valid");
        usedSignatures[_hashedMessage] = true;
        if (orders[_tweetId].offerAmount >= 1 ether) { // if there is an active offer
            AcceptedPayment.transfer(orders[_tweetId].maker, orders[_tweetId].offerAmount); // refund the offer
            cancelOrder(_tweetId);
        }
        NFTWEETS.safeMint(msg.sender, uri, _hashedMessage);
    }

    function acceptMintOffer(uint256 _tweetId, string memory uri, bytes32 _hashedMessage, uint8 _v, bytes32 _r, bytes32 _s) public {
        require(orders[_tweetId].ended == false, "Already Sold");
        require(block.timestamp < orders[_tweetId].endTime, "Offer Expired");
        require(VerifyTweetData(_hashedMessage, _v, _r, _s, _tweetId, uri), "Data is not valid");
        usedSignatures[_hashedMessage] = true;
        uint256 SaleDevPercent = orders[_tweetId].offerAmount.mul(SaleDevFee).div(100);
        uint256 TweetOwnerAmount = orders[_tweetId].offerAmount.sub(SaleDevPercent);
        AcceptedPayment.transfer(msg.sender, TweetOwnerAmount);
        AcceptedPayment.transfer(DevWallet, SaleDevPercent);
        NFTWEETS.safeMint(orders[_tweetId].maker, uri, _hashedMessage);
        cancelOrder(_tweetId);
        emit mintOfferAccepted(_tweetId, msg.sender, orders[_tweetId].maker, uri, orders[_tweetId].offerAmount);
    }

    function cancelOrder(uint256 _tweetId) internal returns (bool removed) {
        for(uint i = 0; i < tweetOrders.length; i++) {
            if (orders[tweetOrders[i]].tweetId == _tweetId) {
                orders[tweetOrders[i]].ended = true; // end the order
                tweetOrders[i] = tweetOrders[tweetOrders.length - 1];
                tweetOrders.pop(); // remove the order
                return (true);
            }
        }
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory) {
        if ((block.timestamp - lastTimeStamp) > interval && tweetOrders.length > 0) {
            upkeepNeeded = true;
        } else {
            upkeepNeeded = false;
        }        
    }

    function performUpkeep(bytes calldata) external override onlyRole(KEEPER_ROLE) {
        if ((block.timestamp - lastTimeStamp) > interval ) {
            lastTimeStamp = block.timestamp;
        }
        for(uint i = 0; i < tweetOrders.length; i++) {
            if (block.timestamp >= orders[tweetOrders[i]].endTime && orders[tweetOrders[i]].ended == false ) {
                AcceptedPayment.transfer(orders[tweetOrders[i]].maker,orders[tweetOrders[i]].offerAmount); // refund the offer
                orders[tweetOrders[i]].ended = true; // end the order
                tweetOrders[i] = tweetOrders[tweetOrders.length - 1];
                tweetOrders.pop(); // remove the order
            }
        }
    }

    function setNFTContract(address _NFTweets) public onlyRole(DEFAULT_ADMIN_ROLE) {
        NFTweets = IERC721(_NFTweets);
        NFTWEETS = INFTWEETS(_NFTweets);
    }

    function setPaymentToken(address _Token) public onlyRole(DEFAULT_ADMIN_ROLE) {
        AcceptedPayment = IERC20(_Token);
    }

    function setMinPrice(uint256 _MinPrice) public onlyRole(DEFAULT_ADMIN_ROLE) {
        MinPrice = _MinPrice;
    }

    function setDevFee(uint256 _OfferDevFee, uint256 _SaleDevFee) public onlyRole(DEFAULT_ADMIN_ROLE) {
        OfferDevFee = _OfferDevFee;
        SaleDevFee = _SaleDevFee;
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function withdrawDevFees() public payable onlyRole(DEFAULT_ADMIN_ROLE) {
        (bool os, ) = payable(DevWallet).call{value: address(this).balance}("");
        require(os);
    }
}