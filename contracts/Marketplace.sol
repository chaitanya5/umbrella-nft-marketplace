//SPDX-License-Identifier: MIT

pragma solidity ^0.7.5;
pragma experimental ABIEncoderV2;

import "hardhat/console.sol";

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721Holder.sol";

import "@umb-network/toolbox/dist/contracts/IChain.sol";
import "@umb-network/toolbox/dist/contracts/IRegistry.sol";
import "@umb-network/toolbox/dist/contracts/lib/ValueDecoder.sol";

import "./interfaces/IMarketplace.sol";
import "./FeeManager.sol";

contract Marketplace is Ownable, Pausable, FeeManager, IMarketplace, ERC721Holder {
    using Address for address;
    using SafeMath for uint256;

    bytes32 public keyPair;
    IRegistry public priceRegistry;

    mapping (Category => uint256) public categoryPrice;     // In Dollars

    // From ERC721 registry assetId to Order (to avoid asset collision)
    mapping(address => mapping(uint256 => Order)) public orderByAssetId;

    // From ERC721 registry assetId to Bid (to avoid asset collision)
    mapping(address => mapping(uint256 => Bid)) public bidByOrderId;

    // 721 Interfaces
    bytes4 public constant _INTERFACE_ID_ERC721 = 0x80ac58cd;

    modifier priceforCategory(Category _type) {
        require(msg.value == fetchCategoryPrice(_type), "invalid category price");
        _;
    }

    /**
     * @dev Initialize this contract. Acts as a constructor
     * @param _priceRegistry - // uses umbrella-network
     * @param _keyPair - // uses umbrella-network
     */
    constructor (address _priceRegistry, bytes32 _keyPair) {
        keyPair = _keyPair;             // DAI-BNB
        setRegistry(_priceRegistry);    // uses umbrella-network
    }

    /**
     * @notice Change umbrella price registry address in case of updates.
     * @param _priceRegistry address of new registry contract.
     */
    function setRegistry(address _priceRegistry) public onlyOwner {
        require(_priceRegistry != address(0), "INVALID_AGG");
        priceRegistry = IRegistry(_priceRegistry);
        emit PriceRegistryChanged(address(_priceRegistry));
    }

    /**
     * @notice Change keyPair fetching from umbrella sdk.
     * @dev Never change keyPair as it should be fixed for a pair, only change if umbrella-sdk changes anytime.
     * @param _keyPair new keyPair.
     */
    function setKeyPair(bytes32 _keyPair) public onlyOwner {
        keyPair = _keyPair;         // DAI-BNB
        emit KeyPairChanged(keyPair);
    }

    /**
     * @dev Sets the price for each category type. Can only be called by owner
     * @param _type - Category Type
     * @param _amount - Enter in dollar values, eg: 100$
     */
    function setPriceforCategory(Category _type, uint256 _amount) public onlyOwner {
        categoryPrice[_type] = _amount;
        emit PriceforCategoryChanged(_type, _amount);
    }

    /**
     * @dev Fetches each Category Price from Umbrella's oracles
     * @param _type - Category Type
     */
    function fetchCategoryPrice(Category _type) view public returns (uint256) {
        (uint256 price, uint256 timestamp) = _chain().getCurrentValue(keyPair);
        console.log("umbChain:: price, timestamp", price, timestamp);
        require(price > 0 && timestamp > 0, "price does not exists");
        return uint256(price.mul(categoryPrice[_type]).div(10**5));
    }

    /**
     * @dev Sets the paused failsafe. Can only be called by owner
     * @param _setPaused - paused state
     */
    function setPaused(bool _setPaused) public onlyOwner {
        return (_setPaused) ? _pause() : _unpause();
    }

    /**
     * @dev Creates a new order
     * @param _nftAddress - Non fungible registry address
     * @param _assetId - ID of the published NFT
     * @param _type - Category Type
     * @param _expiresAt - Duration of the order (in hours)
     */
    function createOrder(address _nftAddress, uint256 _assetId, Category _type, uint256 _expiresAt) public whenNotPaused {
        _createOrder(_nftAddress, _assetId, fetchCategoryPrice(_type), _expiresAt);
    }

    /**
     * @dev Cancel an already published order
     *  can only be canceled by seller or the contract owner
     * @param _nftAddress - Address of the NFT registry
     * @param _assetId - ID of the published NFT
     */
    function cancelOrder(address _nftAddress, uint256 _assetId) public whenNotPaused {
        Order storage order = orderByAssetId[_nftAddress][_assetId];

        require(order.seller == msg.sender || msg.sender == owner(), "Marketplace: unauthorized sender");

        // Remove pending bid if any
        Bid storage bid = bidByOrderId[_nftAddress][_assetId];

        if (bid.id != 0) {
            _cancelBid(bid.id, _nftAddress, _assetId, bid.bidder, bid.price);
        }

        // Cancel order.
        _cancelOrder(order.id, _nftAddress, _assetId, msg.sender);
    }

    /**
     * @dev Executes the sale for a published NFT and checks for the asset fingerprint
     * @param _nftAddress - Address of the NFT registry
     * @param _assetId - ID of the published NFT
     */
    function safeExecuteOrder(address _nftAddress, uint256 _assetId) public payable whenNotPaused {
        // Get the current valid order for the asset or fail
        Order memory order = _getValidOrder(_nftAddress, _assetId);

        /// Check the execution price matches the order price
        require(order.price == msg.value, "Marketplace: invalid price");
        require(order.seller != msg.sender, "Marketplace: unauthorized sender");

        // market fee to cut
        uint256 saleShareAmount = 0;

        // Send market fees to owner
        if (FeeManager.cutPerMillion > 0) {
            // Calculate sale share
            saleShareAmount = order.price.mul(FeeManager.cutPerMillion).div(1e6);

            // Transfer share amount for marketplace Owner
            payable(owner()).transfer(saleShareAmount);
        }

        // Transfer accepted token amount minus market fee to seller
        order.seller.transfer(order.price.sub(saleShareAmount));

        // Remove pending bid if any
        Bid memory bid = bidByOrderId[_nftAddress][_assetId];

        if (bid.id != 0) {
            _cancelBid(bid.id, _nftAddress, _assetId, bid.bidder, bid.price);
        }

        _executeOrder(order.id, msg.sender, _nftAddress, _assetId, order.price);
    }

    /**
     * @dev Places a bid for a published NFT and checks for the asset fingerprint
     * @param _nftAddress - Address of the NFT registry
     * @param _assetId - ID of the published NFT
     * @param _expiresAt - Bid expiration time
     */
    function safePlaceBid(address _nftAddress, uint256 _assetId, uint256 _expiresAt)
        public payable whenNotPaused {
        _createBid(_nftAddress, _assetId, _expiresAt);
    }

    /**
     * @dev Cancel an already published bid
     *  can only be canceled by seller or the contract owner
     * @param _nftAddress - Address of the NFT registry
     * @param _assetId - ID of the published NFT
     */
    function cancelBid(address _nftAddress, uint256 _assetId) public whenNotPaused {
        Bid memory bid = bidByOrderId[_nftAddress][_assetId];

        require(bid.bidder == msg.sender || msg.sender == owner(),"Marketplace: Unauthorized sender");

        _cancelBid(bid.id, _nftAddress, _assetId, bid.bidder, bid.price);
    }

    /**
     * @dev Executes the sale for a published NFT by accepting a current bid
     * @param _nftAddress - Address of the NFT registry
     * @param _assetId - ID of the published NFT
     */
    function acceptBid(address _nftAddress, uint256 _assetId) public whenNotPaused {
        // check order validity
        Order memory order = _getValidOrder(_nftAddress, _assetId);

        // item seller is the only allowed to accept a bid
        require(order.seller == msg.sender, "Marketplace: unauthorized sender");

        Bid memory bid = bidByOrderId[_nftAddress][_assetId];

        require(bid.expiresAt >= block.timestamp, "Marketplace: the bid expired");

        // remove bid
        delete bidByOrderId[_nftAddress][_assetId];

        emit BidAccepted(bid.id);

        // calc market fees
        uint256 saleShareAmount = bid.price.mul(FeeManager.cutPerMillion).div(1e6);

        // transfer escrowed bid amount minus market fee to seller
        order.seller.transfer(bid.price.sub(saleShareAmount));

        _executeOrder(order.id, bid.bidder, _nftAddress, _assetId, bid.price);
    }

    /**
     * @dev Internal function gets Order by nftRegistry and assetId. Checks for the order validity
     * @param _nftAddress - Address of the NFT registry
     * @param _assetId - ID of the published NFT
     */
    function _getValidOrder(address _nftAddress, uint256 _assetId) internal view returns (Order memory order) {
        order = orderByAssetId[_nftAddress][_assetId];

        require(order.id != 0, "Marketplace: asset not published");
        require(order.expiresAt >= block.timestamp, "Marketplace: order expired");
    }

    /**
     * @dev Creates a new order
     * @param _nftAddress - Non fungible registry address
     * @param _assetId - ID of the published NFT
     * @param _priceInWei - Price in Wei
     * @param _expiresAt - Expiration time for the order
     */
    function _createOrder(address _nftAddress, uint256 _assetId, uint256 _priceInWei, uint256 _expiresAt) internal {
        // Check nft registry
        IERC721 nftRegistry = _requireERC721(_nftAddress);

        // Check order creator is the asset owner
        address assetOwner = nftRegistry.ownerOf(_assetId);

        require(
            assetOwner == msg.sender,
            "Marketplace: Only the asset owner can create orders"
        );

        require(_priceInWei > 0, "Marketplace: Price should be bigger than 0");

        require(
            _expiresAt > block.timestamp.add(1 minutes),
            "Marketplace: Publication should be more than 1 minute in the future"
        );

        // get NFT asset from seller
        nftRegistry.safeTransferFrom(assetOwner, address(this), _assetId);

        // create the orderId
        bytes32 orderId = keccak256(abi.encodePacked(block.timestamp, assetOwner, _nftAddress, _assetId, _priceInWei));

        // save order
        orderByAssetId[_nftAddress][_assetId] = Order({
            id: orderId,
            seller: payable(assetOwner),
            nftAddress: _nftAddress,
            price: _priceInWei,
            expiresAt: _expiresAt
        });

        emit OrderCreated(orderId, assetOwner, _nftAddress, _assetId, _priceInWei, _expiresAt);
    }

    /**
     * @dev Executes the sale for a published NFT
     * @param _orderId - Order Id to execute
     * @param _buyer - address
     * @param _nftAddress - Address of the NFT registry
     * @param _assetId - NFT id
     * @param _priceInWei - Order price
     */
    function _executeOrder(bytes32 _orderId, address _buyer, address _nftAddress, uint256 _assetId, uint256 _priceInWei) internal {
        // remove order
        delete orderByAssetId[_nftAddress][_assetId];

        // Transfer NFT asset
        IERC721(_nftAddress).safeTransferFrom(address(this), _buyer, _assetId);

        // Notify ..
        emit OrderSuccessful(_orderId, _buyer, _priceInWei);
    }

    /**
     * @dev Cancel an already published order
     *  can only be canceled by seller or the contract owner
     * @param _orderId - Bid identifier
     * @param _nftAddress - Address of the NFT registry
     * @param _assetId - ID of the published NFT
     * @param _seller - Address
     */
    function _cancelOrder(bytes32 _orderId, address _nftAddress, uint256 _assetId, address _seller) internal {
        delete orderByAssetId[_nftAddress][_assetId];

        /// send asset back to seller
        IERC721(_nftAddress).safeTransferFrom(address(this), _seller, _assetId);

        emit OrderCancelled(_orderId);
    }

    /**
     * @dev Creates a new bid on a existing order
     * @param _nftAddress - Non fungible registry address
     * @param _assetId - ID of the published NFT
     * @param _expiresAt - expires time
     */
    function _createBid(address _nftAddress, uint256 _assetId, uint256 _expiresAt) internal {
        // Checks order validity
        Order memory order = _getValidOrder(_nftAddress, _assetId);

        // check on expire time
        if (_expiresAt > order.expiresAt) {
            _expiresAt = order.expiresAt;
        }

        // Check price if theres previous a bid
        Bid memory bid = bidByOrderId[_nftAddress][_assetId];

        // if theres no previous bid, just check price > 0
        if (bid.id != 0) {
            if (bid.expiresAt >= block.timestamp) {
                require(
                    msg.value > bid.price,
                    "Marketplace: bid price should be higher than last bid"
                );

            } else {
                require(msg.value > 0, "Marketplace: bid should be > 0");
            }

            _cancelBid(bid.id, _nftAddress, _assetId, bid.bidder, bid.price);

        } else {
            require(msg.value > 0, "Marketplace: bid should be > 0");
        }

        // Transfer sale amount from bidder to escrow
        // acceptedToken.safeTransferFrom(msg.sender, address(this), _priceInWei);

        // Create bid
        bytes32 bidId = keccak256(abi.encodePacked(block.timestamp, msg.sender, order.id, msg.value, _expiresAt));

        // Save Bid for this order
        bidByOrderId[_nftAddress][_assetId] = Bid({
            id: bidId,
            bidder: msg.sender,
            price: msg.value,
            expiresAt: _expiresAt
        });

        emit BidCreated(bidId, _nftAddress, _assetId, msg.sender, msg.value, _expiresAt);
    }

    /**
     * @dev Cancel bid from an already published order
     *  can only be canceled by seller or the contract owner
     * @param _bidId - Bid identifier
     * @param _nftAddress - registry address
     * @param _assetId - ID of the published NFT
     * @param _bidder - Address
     * @param _escrowAmount - token price
     */
    function _cancelBid(bytes32 _bidId, address _nftAddress, uint256 _assetId, address payable _bidder, uint256 _escrowAmount) internal {
        delete bidByOrderId[_nftAddress][_assetId];

        // return escrow to canceled bidder
        _bidder.transfer(_escrowAmount);

        emit BidCancelled(_bidId);
    }

    /**
     * @notice Fetch the current umbrella chain address.
     * @dev umbrella Chain address keeps changing.
     */
    function _chain() internal view returns (IChain umbChain) {
        umbChain = IChain(priceRegistry.getAddress("Chain"));
        console.log("umbChain:");
        console.logAddress(address(umbChain));
    }

    function _requireERC721(address _nftAddress) internal view returns (IERC721) {
        require(_nftAddress.isContract(),"The NFT Address should be a contract");
        require(IERC721(_nftAddress).supportsInterface(_INTERFACE_ID_ERC721), "The NFT contract has an invalid ERC721 implementation");
        return IERC721(_nftAddress);
    }

}