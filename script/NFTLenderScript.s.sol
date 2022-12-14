// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

import { Script } from "forge-std/Script.sol";
import { NFTLender } from "../src/NFTLender.sol";
import "../src/OracleNftFloor.sol";
import { DummyNFT } from "../test/DummyNFT.sol";

contract NFTLenderScript is Script {
    NFTLender internal nftLender;
    OracleNftFloor internal oracle;
    DummyNFT internal dummyNft;

    function run() public {
        vm.startBroadcast();

        if (block.chainid == 31337 || block.chainid == 5) {
            dummyNft = new DummyNFT();
        }
        oracle = new OracleNftFloor();
        nftLender = new NFTLender(address(oracle));
        vm.stopBroadcast();
    }
}
