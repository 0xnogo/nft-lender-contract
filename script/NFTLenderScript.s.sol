// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.4;

import { Script } from "forge-std/Script.sol";
import { NFTLender } from "../src/NFTLender.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/tutorials/solidity-scripting
contract NFTLenderScript is Script {
    NFTLender internal nftLender;

    function run() public {
        vm.startBroadcast();
        nftLender = new NFTLender();
        vm.stopBroadcast();
    }
}
