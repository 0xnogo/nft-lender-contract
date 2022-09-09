// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

contract OracleNftFloor {
    uint256 public floorPrice = 1 ether;

    function getFloorPrice(address _nftCollectionAddress) public view returns (uint256) {
        return floorPrice;
    }

    function setFloorPrice(uint256 _floorPrice) public {
        floorPrice = _floorPrice;
    }
}
