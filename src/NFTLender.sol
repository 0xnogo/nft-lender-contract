// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { console } from "forge-std/console.sol";

import "./OracleNftFloor.sol";

contract NFTLender {
    uint256 public constant INTEREST_RATE = 316887385; // 10% interest rate per sec per 0.001Eth
    uint256 public constant LIQUIDATION_THRESHOLD = 8000; // multiplied by 100 to avoind round down to 1
    uint256 public constant LTV = 75;
    uint256 public constant HEALTH_FACTOR = 100; // // multiplied by 100 to avoind round down to 1

    OracleNftFloor public oracle;

    mapping(address => Nft[]) public lenders;
    mapping(address => Loan) public borrowers;

    struct Nft {
        address collectionAddress;
        uint256 tokenId;
        uint256 startTime;
    }

    struct Loan {
        uint256 amount;
        uint256 startTime;
        uint256 lastReimbursment;
    }

    event Deposit(address indexed lender, address collection, uint256 tokenId);
    event Withdraw(address indexed lender, address collection, uint256 tokenId);
    event Borrow(address indexed borrower, uint256 amount);
    event Liquidate(address indexed liquidator, address collection, uint256 tokenId);

    constructor(address _oracleAddress) {
        oracle = OracleNftFloor(_oracleAddress);
    }

    function deposit(address _collectionAddress, uint256 _tokenId) public {
        IERC721 collection = IERC721(_collectionAddress);

        require(
            collection.ownerOf(_tokenId) == msg.sender || collection.getApproved(_tokenId) == address(this),
            "Not owner nor approved"
        );

        collection.transferFrom(msg.sender, address(this), _tokenId);
        lenders[msg.sender].push(Nft(address(collection), _tokenId, block.timestamp));

        emit Deposit(msg.sender, address(collection), _tokenId);
    }

    function borrow(uint256 _amountAsked) public {
        uint256 maxAmountLoan = _maxAmountLoan(msg.sender);
        require(_amountAsked <= maxAmountLoan, "Asked amount bigger than collateral");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = payable(msg.sender).call{ value: _amountAsked }("");
        require(success, "eth reimbursment failed");

        borrowers[msg.sender] = Loan(_amountAsked, block.timestamp, block.timestamp);

        emit Borrow(msg.sender, _amountAsked);
    }

    function withdraw() public payable {
        Loan memory loanFromUser = borrowers[msg.sender];
        Nft[] memory nftsFromUser = lenders[msg.sender];

        require(nftsFromUser.length != 0, "No deposit made");
        require(loanFromUser.startTime != 0, "No loan made");

        if (loanFromUser.lastReimbursment != block.timestamp) {
            _reimburseDebt(msg.sender);
        }

        for (uint256 i = 0; i < nftsFromUser.length; i++) {
            IERC721 nft = IERC721(nftsFromUser[i].collectionAddress);
            nft.transferFrom(address(this), msg.sender, nftsFromUser[i].tokenId);
            emit Withdraw(msg.sender, nftsFromUser[i].collectionAddress, nftsFromUser[i].tokenId);
        }
    }

    function reimburseDebt() public payable {
        _reimburseDebt(msg.sender);
    }

    function liquidate(address _userToLiquidate) public payable {
        Nft[] memory nftsToLiquidate = lenders[_userToLiquidate];
        Loan memory loanToLiquidate = borrowers[_userToLiquidate];

        uint256 threshold = (_collateral(_userToLiquidate) * LIQUIDATION_THRESHOLD) / 100;
        uint256 healthFactor = threshold / loanToLiquidate.amount;
        require(healthFactor <= HEALTH_FACTOR, "Position not undercollateralized");

        _reimburseDebt(_userToLiquidate);

        for (uint256 i = 0; i < nftsToLiquidate.length; i++) {
            IERC721 nft = IERC721(nftsToLiquidate[i].collectionAddress);
            nft.transferFrom(address(this), msg.sender, nftsToLiquidate[i].tokenId);
            emit Liquidate(msg.sender, address(nft), nftsToLiquidate[i].tokenId);
        }
    }

    // TODO(nogo): to implement with an Oracle
    // For simplicity and demo, hardcoded value is provided
    function getFloorPrice(address _nftCollectionAddress) public view returns (uint256) {
        return oracle.getFloorPrice(_nftCollectionAddress);
    }

    function _collateral(address _for) private view returns (uint256) {
        Nft[] memory nftsFromSender = lenders[_for];
        require(nftsFromSender.length != 0, "No collateral");

        uint256 collateral;
        for (uint256 i = 0; i < nftsFromSender.length; i++) {
            // making an external call to allow mocking call
            collateral += this.getFloorPrice(nftsFromSender[i].collectionAddress);
        }

        return collateral;
    }

    function _maxAmountLoan(address _for) private view returns (uint256) {
        Nft[] memory nftsFromSender = lenders[_for];
        require(nftsFromSender.length != 0, "No collateral");
        return (_collateral(_for) * LTV) / 100;
    }

    function _reimburseDebt(address _user) private {
        Loan memory loanFromUser = borrowers[_user];

        uint256 timeElapsed = block.timestamp - loanFromUser.lastReimbursment;
        uint256 interest = (loanFromUser.amount / 1e15) * INTEREST_RATE;
        uint256 fee = timeElapsed * interest;
        uint256 fullDebt = loanFromUser.amount + fee;

        require(msg.value >= fullDebt, "value sent not covering debt");

        uint256 difference = msg.value - fullDebt;

        if (difference > 0) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = _user.call{ value: difference }("");
            require(success, "eth reimbursment failed");
        }

        borrowers[_user] = Loan(loanFromUser.amount, loanFromUser.startTime, block.timestamp);
    }
}
