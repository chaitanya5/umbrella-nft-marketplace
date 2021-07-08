const { ethers } = require("hardhat");
const { expect } = require("chai");
require("dotenv").config();
const { LeafKeyCoder, LeafValueCoder, constants } = require('@umb-network/toolbox');

// Chain registry address (see https://umbrella-network.readme.io/docs/umb-token-contracts)
const REGISTRY_CONTRACT_ADDRESS = process.env.REGISTRY_CONTRACT_ADDRESS;
const label = 'BNB-USD'

describe("Marketplace", function () {
  let Marketplace, marketplace, ArtToken, art, priceRegistry, tx
  let daiUserBalance, daiContractBalance, LPBalanceOfUser

  const setup = async () => {
    [owner, alice] = await ethers.getSigners();
    Marketplace = await ethers.getContractFactory("Marketplace");
    ArtToken = await ethers.getContractFactory("ArtToken");
    console.log('owner', owner.address);
    priceRegistry = address(REGISTRY_CONTRACT_ADDRESS);
  }


  before(async () => {
    await setup();

    // Deploy the Liquidity Pool smart contract
    marketplace = await Marketplace.deploy(priceRegistry, keyEncoder(label));   // Taking DAI as Dollar 
    await marketplace.deployed();

    // console.log('mock DAI token deployed at', art.address);
    console.log('marketplace contract deployed at', marketplace.address);

  });

  it('Correctly deploys the marketplace smart contract', async () => {
    expect(await marketplace.owner()).to.equal(owner.address);
    expect(await marketplace.priceRegistry()).to.equal(priceRegistry);
    const keyPair = await marketplace.keyPair()
    console.log('keyPair', keyPair);
    expect(keyDecoder(keyPair)).to.equal(label);
  });

  it('Sets the price for each category type', async function () {
    tx = await marketplace.connect(owner).setPriceforCategory(0, 100);
    await tx.wait()

    const categoryPrice = await marketplace.categoryPrice(0);

    console.log('categoryPrice', categoryPrice.toString());
    expect(categoryPrice.toString()).to.equal('100');


  });

  it('Fetches BNB price for each category type', async function () {
    let price = await marketplace.fetchCategoryPrice(0)
    console.log('Price from Contract', price.toString());

    const priceAsNumber = valueDecoder(price, label);
    console.log('price As Number:', priceAsNumber);

  });

});


// Lsit of Helper functions
// Converts checksum
const address = (params) => {
  return ethers.utils.getAddress(params);
}

// Converts token units to smallest individual token unit, eg: 1 DAI = 10^18 units 
const parseUnits = (params) => {
  return ethers.utils.parseUnits(params.toString(), 18);
}

// Converts token units from smallest individual unit to token unit, opposite of parseUnits
const formatUnits = (params) => {
  return ethers.utils.formatUnits(params.toString(), 18);
}

// LeafKeyCoder => encode, string to convert into bytes32
const keyEncoder = (params) => {
  return LeafKeyCoder.encode(params)
}

// LeafKeyDeCoder => decode, bytes32 to convert into string
const keyDecoder = (params) => {
  return LeafKeyCoder.decode(params)
}


// LeafValueCoder => decode, price to number with label
const valueDecoder = (params, label) => {
  return LeafValueCoder.decode(params.toHexString(), label);
}
