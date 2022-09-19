# NFT Lender

Introducing you: NFTLender, an nft-based lending protocol on Goerli.

Borrow/deposit/liquidate now at [http://nftlender.vercel.app](http://nftlender.vercel.app)

Twitter 🧵: https://twitter.com/0xnogo/status/1571552572821090304

![plot](./screenshot.png)

## Addresses

- NFTLender contract:https://goerli.etherscan.io/tx/0x643de5253975d289c5966342094f9be8dbbbdba7
- Oracle contract: https://goerli.etherscan.io/tx/0x146d51b7c31bd7ef2577bb0c247f63741ba981e7
- Dummy NFT contract: https://goerli.etherscan.io/tx/0x8db9ec083bc954c57991b33bdd96ddaf9eca027c

## Why?

I haven’t study the competition nor checked if there is a market for it. The sole purpose of his project is educational. UI can be buggy and important features like oracle price feed are missing. But it was fun to build 🤜🤛

## Key features

### Deposit

The idea is to allow users to deposit their nfts as collateral (=floor price of the collection). Built a fake Oracle price feed as I was not to find one for nft floor price.

### Borrow

TVL is 75% so for 1 eth worth of nft staked, you can borrow up to 0.75 ETH. Loans can be split an unlimited number of time. example: 0.20eth and 0.20eth and 0.35eth.

### Reimburse

Interest rate is 10% annualized. It is possible to reimburse only one loan or all. Reimbursing will allow you to increase your health factor and avoid liquidation (=threshold at 80%).

### Withdraw

For withdrawing, as long as you are collateralized enough, it is possible to withdraw nfts. Of course, if the health factor < 1 after a potential withdrawal, you will be asked to reimburse first.

### Admin

Admin tab in order to play with all that. You can mint an NFT and deposit it but also change the price coming from the fake oracle feed to trigger liquidations.

## Developing

```
forge build
forge test -vvvv
```

## Some future ideas

- Oracle price feed
