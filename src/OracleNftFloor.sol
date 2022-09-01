// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

contract OracleNftFloor {
    function getFloorPrice(address _nftCollectionAddress) public pure returns (uint256) {
        return 100 ether;
    }
}
