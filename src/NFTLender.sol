// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { console } from "forge-std/console.sol";

import "./OracleNftFloor.sol";

contract NFTLender {
    uint256 public constant INTEREST_RATE = 316887385; // 10% - interest rate per sec per 0.001Eth
    uint256 public constant LIQUIDATION_THRESHOLD = 8000; // multiplied by 100 to avoid round down to 1
    uint256 public constant LTV = 75;
    uint256 public constant HEALTH_FACTOR = 100; // // multiplied by 100 to avoid round down to 1

    OracleNftFloor public oracle;

    mapping(address => Nft[]) public lenders;
    mapping(address => Loan[]) public borrowers;

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
    event Borrow(address indexed from, uint256 amount);
    event Reimburse(address indexed from, uint256 amount, uint256 loanId);
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
        uint256 amountLoanforUser = _withdrawAmountLeft(msg.sender);
        require(_amountAsked <= amountLoanforUser, "Asked amount bigger than amount allowed");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = payable(msg.sender).call{ value: _amountAsked }("");
        require(success, "eth payment failed");

        borrowers[msg.sender].push(Loan(_amountAsked, block.timestamp, block.timestamp));

        emit Borrow(msg.sender, _amountAsked);
    }

    function withdraw(address _address, uint256 _id) public {
        Nft[] memory nftsFromUser = lenders[msg.sender];

        require(nftsFromUser.length != 0, "No deposit made");

        Nft memory nftToWithdraw;
        uint256 nftToWithdrawIndex;
        uint256 collateralToWithdraw;

        for (uint256 i = 0; i < nftsFromUser.length; i++) {
            if (nftsFromUser[i].collectionAddress == _address && nftsFromUser[i].tokenId == _id) {
                nftToWithdraw = nftsFromUser[i];
                collateralToWithdraw = this.getFloorPrice(nftToWithdraw.collectionAddress);
                nftToWithdrawIndex = i;
                break;
            }
        }
        require(nftToWithdraw.collectionAddress != address(0), "Nft not found");

        uint256 fullDebt = _getFullDebt(msg.sender);
        if (fullDebt > 0) {
            uint256 collateralBeforeWithdraw = _collateral(msg.sender);
            uint256 collateralAfterWithdraw = collateralBeforeWithdraw - collateralToWithdraw;
            uint256 liquidationThreshold = (collateralAfterWithdraw * LIQUIDATION_THRESHOLD) / 100;
            uint256 healthFactor = liquidationThreshold / fullDebt;
            require(healthFactor > HEALTH_FACTOR, "Colleral left not sufficient");
        }

        IERC721 nft = IERC721(nftToWithdraw.collectionAddress);
        nft.transferFrom(address(this), msg.sender, nftToWithdraw.tokenId);
        _removeItemFromNftArray(msg.sender, nftToWithdrawIndex);
        emit Withdraw(msg.sender, nftToWithdraw.collectionAddress, nftToWithdraw.tokenId);
    }

    function withdrawAndReimburseAll() public payable {
        Nft[] memory nftsFromUser = lenders[msg.sender];

        require(nftsFromUser.length != 0, "No deposit made");

        _reimburseAllDebt(msg.sender, payable(msg.sender));

        for (uint256 i = 0; i < nftsFromUser.length; i++) {
            IERC721 nft = IERC721(nftsFromUser[i].collectionAddress);
            nft.transferFrom(address(this), msg.sender, nftsFromUser[i].tokenId);
            emit Withdraw(msg.sender, nftsFromUser[i].collectionAddress, nftsFromUser[i].tokenId);
        }
        delete lenders[msg.sender];
    }

    function reimburseLoan(uint256 _loanId) public payable {
        uint256 remainder = _reimburseDebt(payable(msg.sender), msg.value, _loanId);
        _removeItemFromLoanArray(msg.sender, _loanId);

        if (remainder > 0) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = payable(msg.sender).call{ value: remainder }("");
            require(success, "eth reimbursment failed");
        }
    }

    function reimburseAllDebt() public payable {
        _reimburseAllDebt(msg.sender, payable(msg.sender));
    }

    function liquidateAll(address _userToLiquidate) public payable {
        Nft[] memory nftsToLiquidate = lenders[_userToLiquidate];

        uint256 healthFactor = _getHealthFactor(_userToLiquidate);
        require(healthFactor <= HEALTH_FACTOR, "Position not undercollateralized");

        for (uint256 i = 0; i < nftsToLiquidate.length; i++) {
            IERC721 nft = IERC721(nftsToLiquidate[i].collectionAddress);
            nft.transferFrom(address(this), msg.sender, nftsToLiquidate[i].tokenId);
            emit Liquidate(msg.sender, address(nft), nftsToLiquidate[i].tokenId);
        }

        delete lenders[_userToLiquidate];

        _reimburseAllDebt(_userToLiquidate, payable(msg.sender));
    }

    // TODO(nogo): to implement with an Oracle
    // For simplicity and demo, hardcoded value is provided
    function getFloorPrice(address _nftCollectionAddress) public view returns (uint256) {
        return oracle.getFloorPrice(_nftCollectionAddress);
    }

    function maxAmountLoan(address _for) public view returns (uint256) {
        return _maxAmountLoan(_for);
    }

    function getFullDebt() public view returns (uint256) {
        return _getFullDebt(msg.sender);
    }

    function getDepositFor(address _user) public view returns (Nft[] memory) {
        return lenders[_user];
    }

    function getLoanFor(address _user) public view returns (Loan[] memory) {
        return borrowers[_user];
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

    function _getDebtAmountForLoan(Loan memory _loanFromUser) private view returns (uint256 debtForLoan) {
        uint256 timeElapsed = block.timestamp - _loanFromUser.lastReimbursment;
        uint256 interest = (_loanFromUser.amount / 1e15) * INTEREST_RATE;
        uint256 fee = timeElapsed * interest;
        debtForLoan = _loanFromUser.amount + fee;
    }

    function _maxAmountLoan(address _for) private view returns (uint256) {
        Nft[] memory nftsFromSender = lenders[_for];
        if (nftsFromSender.length == 0) return 0;
        return (_collateral(_for) * LTV) / 100;
    }

    function _getFullDebt(address _user) private view returns (uint256 fullDebt) {
        Loan[] memory loansFromUser = borrowers[_user];

        for (uint256 i; i < loansFromUser.length; i++) {
            fullDebt += _getDebtAmountForLoan(loansFromUser[i]);
        }
    }

    function _withdrawAmountLeft(address _for) private view returns (uint256 amountLeft) {
        amountLeft = _maxAmountLoan(_for) - _getFullDebt(_for);
        assert(amountLeft >= 0);
    }

    function _borrowedAmountWithoutDebt(address _for) private view returns (uint256 borrowedAmount) {
        Loan[] memory loansFromUser = borrowers[_for];

        for (uint256 i = 0; i < loansFromUser.length; i++) {
            borrowedAmount += loansFromUser[i].amount;
        }
    }

    function _getHealthFactor(address _for) private view returns (uint256 healthFactor) {
        uint256 liquidationThreshold = (_collateral(_for) * LIQUIDATION_THRESHOLD) / 100;
        healthFactor = liquidationThreshold / _getFullDebt(_for);
    }

    function _reimburseAllDebt(address _userToLiquidate, address payable _for) private {
        Loan[] memory loansFromUser = borrowers[_userToLiquidate];

        uint256 remainder = msg.value;
        for (uint256 i = 0; i < loansFromUser.length; i++) {
            remainder = _reimburseDebt(_userToLiquidate, remainder, i);
        }

        delete borrowers[_userToLiquidate];

        if (remainder > 0) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = payable(_for).call{ value: remainder }("");
            require(success, "eth reimbursment failed");
        }
    }

    function _reimburseDebt(
        address _user,
        uint256 _value,
        uint256 _loanId
    ) private returns (uint256 difference) {
        Loan memory loanFromUser = borrowers[_user][_loanId];

        uint256 debtForLoan = _getDebtAmountForLoan(loanFromUser);

        require(_value >= debtForLoan, "value sent not covering debt");

        borrowers[_user][_loanId] = Loan(loanFromUser.amount, loanFromUser.startTime, block.timestamp);

        difference = _value - debtForLoan;

        emit Reimburse(_user, debtForLoan, _loanId);
    }

    function _removeItemFromNftArray(address _for, uint256 _index) private {
        lenders[_for][_index] = lenders[_for][lenders[_for].length - 1];
        lenders[_for].pop();
    }

    function _removeItemFromLoanArray(address _for, uint256 _index) private {
        borrowers[_for][_index] = borrowers[_for][borrowers[_for].length - 1];
        borrowers[_for].pop();
    }

    receive() external payable {}
}
