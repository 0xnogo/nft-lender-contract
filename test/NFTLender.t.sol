// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

import { Cheats } from "forge-std/Cheats.sol";
import { console } from "forge-std/console.sol";
import { PRBTest } from "@prb/test/PRBTest.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "../src/NFTLender.sol";
import "../src/OracleNftFloor.sol";

import "./DummyNFT.sol";

contract ContractTest is PRBTest, Cheats {
    uint256 public constant FIRST_TOKEN_ID = 0;
    uint256 public constant SECOND_TOKEN_ID = 2;

    NFTLender public nftLender;
    DummyNFT public nftToken;
    OracleNftFloor public oracle;

    address public depositor = vm.addr(1);
    address public liquidator = vm.addr(2);

    event Deposit(address indexed lender, address collection, uint256 tokenId);
    event Withdraw(address indexed lender, address collection, uint256 tokenId);
    event Borrow(address indexed from, uint256 amount);
    event Reimburse(address indexed from, uint256 amount, uint256 loanId);
    event Liquidate(address indexed liquidator, address collection, uint256 tokenId);

    function setUp() public {
        oracle = new OracleNftFloor();
        nftLender = new NFTLender(address(oracle));
        nftToken = new DummyNFT();
        // Mint tokenId 0 to depositor address
        nftToken.safeMint(depositor);
        nftToken.safeMint(vm.addr(42));
        oracle.setFloorPrice(100 ether);
    }

    function testSetUp(address _anyAddress) public {
        assertEq(nftToken.balanceOf(depositor), 1);
        assertEq(oracle.getFloorPrice(_anyAddress), 100 ether);
    }

    function testGetFloorPrice() public {
        uint256 floorPrice = nftLender.getFloorPrice(address(nftToken));
        assertEq(floorPrice, 100 * 1e18);
    }

    function testDeposit() public {
        vm.expectEmit(true, false, false, true);
        emit Deposit(depositor, address(nftToken), FIRST_TOKEN_ID);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        vm.stopPrank();

        (address collectionAddress, uint256 tokenId, uint256 startTime) = nftLender.lenders(depositor, 0);
        assertEq(collectionAddress, address(nftToken));
        assertEq(tokenId, FIRST_TOKEN_ID);
        assertEq(startTime, block.timestamp);

        assertEq(nftLender.getDepositFor(depositor).length, 1);
        assertEq(nftLender.getLoanFor(depositor).length, 0);

        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);
    }

    function testCannotDepositAsNotOwner() public {
        vm.expectRevert("Not owner nor approved");
        vm.startPrank(depositor);
        nftLender.deposit(address(nftToken), 1);
        vm.stopPrank();

        assertEq(nftToken.balanceOf(address(nftLender)), 0);
    }

    function testCannotBorrowForTooSmallCollateral() public {
        uint256 amount = 101 ether;

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        vm.expectRevert("Asked amount bigger than amount allowed");
        _borrow(amount);
        vm.stopPrank();
    }

    function testCannotBorrowIfAmountLeftExceeded() public {
        uint256 firstAmount = 50 ether;
        uint256 secondAmount = 20 ether;
        uint256 thirdAmount = 11 ether;
        vm.deal(address(nftLender), 200 ether);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);

        // First borrow: ok
        _borrow(firstAmount);
        assertGte(depositor.balance, firstAmount);

        // Second borrow: ok
        _borrow(secondAmount);
        assertGte(depositor.balance, firstAmount + secondAmount);

        // Third borrow: ko
        vm.expectRevert("Asked amount bigger than amount allowed");
        _borrow(thirdAmount);

        assertEq(nftLender.getDepositFor(depositor).length, 1);
        assertEq(nftLender.getLoanFor(depositor).length, 2);
    }

    function testBorrowMultipleTimesAsLongAsNotExceeding() public {
        uint256 firstAmount = 50 ether;
        uint256 secondAmount = 24 ether;
        uint256 thirdAmount = 1 ether;
        vm.deal(address(nftLender), 200 ether);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _borrow(firstAmount);
        assertGte(depositor.balance, firstAmount);

        _borrow(secondAmount);
        assertGte(depositor.balance, firstAmount + secondAmount);

        _borrow(thirdAmount);
        assertGte(depositor.balance, firstAmount + secondAmount + thirdAmount);

        assertEq(nftLender.getDepositFor(depositor).length, 1);
        assertEq(nftLender.getLoanFor(depositor).length, 3);

        assertLte(firstAmount + secondAmount + thirdAmount, nftLender.maxAmountLoan(depositor));
    }

    function testBorrowWithOneNft() public {
        uint256 amount = 50 ether;

        vm.deal(address(nftLender), 100 ether);
        vm.expectEmit(true, false, false, true);
        emit Borrow(depositor, amount);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _borrow(amount);
        vm.stopPrank();
        assertGte(depositor.balance, amount);

        assertEq(nftLender.getDepositFor(depositor).length, 1);
        assertEq(nftLender.getLoanFor(depositor).length, 1);
    }

    function testBorrowWithMultipleNftAndMaxAmount() public {
        uint256 maxAmountToBorrow = (2 * nftLender.getFloorPrice(address(nftToken)) * 75) / 100;

        nftToken.safeMint(depositor);

        vm.deal(address(nftLender), maxAmountToBorrow);
        vm.expectEmit(true, false, false, true);
        emit Borrow(depositor, maxAmountToBorrow);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _deposit(SECOND_TOKEN_ID);
        _borrow(maxAmountToBorrow);
        vm.stopPrank();
        assertGte(depositor.balance, maxAmountToBorrow);

        assertEq(nftLender.getDepositFor(depositor).length, 2);
        assertEq(nftLender.getLoanFor(depositor).length, 1);
    }

    function testCannotWithdrawAllAsNoCollateral() public {
        vm.startPrank(depositor);
        vm.expectRevert("Asked amount bigger than amount allowed");
        _borrow(10);
        vm.stopPrank();
        assertEq(depositor.balance, 0);

        assertEq(nftLender.getDepositFor(depositor).length, 0);
        assertEq(nftLender.getLoanFor(depositor).length, 0);
    }

    function testCannotWithdrawAllAsNoLoan() public {
        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        vm.expectRevert("No loan made");
        _withdrawAll(0);
        vm.stopPrank();
        assertEq(depositor.balance, 0);

        assertEq(nftLender.getDepositFor(depositor).length, 1);
        assertEq(nftLender.getLoanFor(depositor).length, 0);
    }

    function testWithdrawAllAfterBorrow() public {
        vm.deal(address(nftLender), 100 ether);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _borrow(10 ether);
        assertEq(depositor.balance, 10 ether);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);

        _withdrawAll(10 ether);
        vm.stopPrank();
        assertEq(nftLender.getFullDebt(), 0);
        assertEq(nftToken.balanceOf(depositor), 1);
        assertEq(nftToken.balanceOf(address(nftLender)), 0);

        assertEq(nftLender.getDepositFor(depositor).length, 0);
        assertEq(nftLender.getLoanFor(depositor).length, 0);
    }

    function testCannotWithdrawAllAsNoValueSent() public {
        vm.deal(address(nftLender), 100 ether);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _borrow(10 ether);
        assertEq(depositor.balance, 10 ether);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);

        skip(60 * 60); // 1 hour
        vm.expectRevert("value sent not covering debt");
        _withdrawAll(0);
        vm.stopPrank();

        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);

        assertEq(nftLender.getDepositFor(depositor).length, 1);
        assertEq(nftLender.getLoanFor(depositor).length, 1);
    }

    function testWithdrawAllWithSomeWaitingAndExactFeePayment() public {
        vm.deal(address(nftLender), 100 ether);
        vm.deal(depositor, 100 ether);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _borrow(10 ether);
        assertGte(depositor.balance, 110 ether);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);

        skip(60 * 60); // 1 hour
        uint256 fee = 60 * 60 * (10 ether / 1e15) * nftLender.INTEREST_RATE();
        _withdrawAll(10 ether + fee);
        vm.stopPrank();

        //we should not pay more that 1 eth of fee
        assertEq(depositor.balance, 100 ether - fee);

        assertEq(nftLender.getFullDebt(), 0);
        assertEq(nftToken.balanceOf(depositor), 1);
        assertEq(nftToken.balanceOf(address(nftLender)), 0);

        assertEq(nftLender.getDepositFor(depositor).length, 0);
        assertEq(nftLender.getLoanFor(depositor).length, 0);
    }

    function testWithdrawAllWithSomeWaitingAndReturnEth() public {
        vm.deal(address(nftLender), 100 ether);
        vm.deal(depositor, 100 ether);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _borrow(10 ether);
        assertGte(depositor.balance, 110 ether);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);

        skip(60 * 60); // 1 hour
        _withdrawAll(100 ether);
        vm.stopPrank();

        assertEq(nftLender.getDepositFor(depositor).length, 0);

        //we should not pay more that 1 eth of fee
        uint256 fee = 60 * 60 * (10 ether / 1e15) * nftLender.INTEREST_RATE();
        assertEq(depositor.balance, 100 ether - fee);

        assertEq(nftLender.getFullDebt(), 0);
        assertEq(nftToken.balanceOf(depositor), 1);
        assertEq(nftToken.balanceOf(address(nftLender)), 0);

        assertEq(nftLender.getDepositFor(depositor).length, 0);
        assertEq(nftLender.getLoanFor(depositor).length, 0);
    }

    function testCannotWithdrawOneNftIfHealthFactorBelowOne() public {
        vm.deal(address(nftLender), 200 ether);
        vm.deal(depositor, 100 ether);
        nftToken.safeMint(depositor);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _deposit(SECOND_TOKEN_ID);
        _borrow(150 ether);
        assertGte(depositor.balance, 100 ether + 150 ether);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 2);

        skip(60 * 60); // 1 hour
        vm.expectRevert("Colleral left not sufficient");
        _withdrawOne(address(nftToken), FIRST_TOKEN_ID);
        vm.stopPrank();

        //we should not pay more that 1 eth of fee
        assertGte(depositor.balance, 100 ether + 10 ether);

        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 2);

        assertEq(nftLender.getDepositFor(depositor).length, 2);
        assertEq(nftLender.getLoanFor(depositor).length, 1);
    }

    function testCannotWithdrawOneNftNotDeposited() public {
        vm.deal(address(nftLender), 200 ether);
        vm.deal(depositor, 100 ether);
        nftToken.safeMint(depositor);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _deposit(SECOND_TOKEN_ID);
        _borrow(150 ether);
        assertGte(depositor.balance, 100 ether + 150 ether);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 2);

        skip(60 * 60); // 1 hour
        vm.expectRevert("Nft not found");
        _withdrawOne(address(nftToken), 3);
        vm.stopPrank();

        //we should not pay more that 1 eth of fee
        assertGte(depositor.balance, 100 ether + 10 ether);

        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 2);

        assertEq(nftLender.getDepositFor(depositor).length, 2);
        assertEq(nftLender.getLoanFor(depositor).length, 1);
    }

    function testWithdrawOneNft() public {
        vm.deal(address(nftLender), 100 ether);
        vm.deal(depositor, 100 ether);
        nftToken.safeMint(depositor);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _deposit(SECOND_TOKEN_ID);
        _borrow(10 ether);
        assertGte(depositor.balance, 110 ether);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 2);

        skip(60 * 60); // 1 hour
        _withdrawOne(address(nftToken), FIRST_TOKEN_ID);
        vm.stopPrank();

        assertEq(nftLender.getDepositFor(depositor).length, 1);

        //we should not pay more that 1 eth of fee
        assertGte(depositor.balance, 100 ether + 10 ether);

        assertEq(nftToken.balanceOf(depositor), 1);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);

        assertEq(nftLender.getDepositFor(depositor).length, 1);
        assertEq(nftLender.getLoanFor(depositor).length, 1);
    }

    function testReimburseLoanWithExactPayment() public {
        vm.deal(address(nftLender), 100 ether);
        vm.deal(depositor, 100 ether);
        nftToken.safeMint(depositor);
        uint256 fee = 60 * 60 * (50 ether / 1e15) * nftLender.INTEREST_RATE();

        vm.expectEmit(true, false, false, true);
        emit Reimburse(depositor, 50 ether + fee, 1);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _deposit(SECOND_TOKEN_ID);
        _borrow(10 ether);
        _borrow(50 ether);
        assertGte(depositor.balance, 100 ether + 50 ether + 10 ether);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 2);

        skip(60 * 60); // 1 hour

        _reimburseLoan(50 ether + fee, 1);
        vm.stopPrank();

        assertEq(depositor.balance, 100 ether + 10 ether - fee);

        assertEq(nftLender.getDepositFor(depositor).length, 2);
        assertEq(nftLender.getLoanFor(depositor).length, 1);
    }

    function testReimburseLoanWithExceedingPaymentExpectingReturn() public {
        vm.deal(address(nftLender), 100 ether);
        vm.deal(depositor, 100 ether);
        nftToken.safeMint(depositor);
        uint256 fee = 60 * 60 * (50 ether / 1e15) * nftLender.INTEREST_RATE();

        vm.expectEmit(true, false, false, true);
        emit Reimburse(depositor, 50 ether + fee, 1);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _deposit(SECOND_TOKEN_ID);
        _borrow(10 ether);
        _borrow(50 ether);
        assertGte(depositor.balance, 100 ether + 50 ether + 10 ether);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 2);

        skip(60 * 60); // 1 hour
        _reimburseLoan(60 ether, 1);
        vm.stopPrank();

        //we should not pay more that 1 eth of fee
        assertAlmostEq(depositor.balance, 100 ether + 10 ether, 0.1 ether);

        assertEq(nftLender.getDepositFor(depositor).length, 2);
        assertEq(nftLender.getLoanFor(depositor).length, 1);
    }

    function testCannotLiquidateAllWithCollateralStillCovering() public {
        uint256 borrowedAmount = 75 ether;
        vm.deal(address(nftLender), 100 ether);
        vm.deal(depositor, 100 ether);
        vm.deal(liquidator, 100 ether);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _borrow(borrowedAmount);
        vm.stopPrank();

        vm.prank(liquidator);
        vm.expectRevert("Position not undercollateralized");
        _liquidateAll(borrowedAmount, depositor);

        assertEq(nftLender.getDepositFor(depositor).length, 1);
        assertEq(nftLender.getLoanFor(depositor).length, 1);

        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);
        assertEq(nftToken.balanceOf(liquidator), 0);
    }

    function testLiquidateAll() public {
        uint256 borrowedAmount = 75 ether;
        vm.deal(address(nftLender), 100 ether);
        vm.deal(depositor, 100 ether);
        vm.deal(liquidator, 100 ether);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _borrow(borrowedAmount);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);
        vm.stopPrank();

        // Mock floor price call and drop it to allow liquidation
        bytes memory data = abi.encodeWithSignature("getFloorPrice(address)", address(nftToken));
        vm.mockCall(address(nftLender), 0, data, abi.encode(50));
        vm.prank(liquidator);
        _liquidateAll(borrowedAmount, depositor);
        vm.clearMockedCalls();

        assertEq(nftLender.getDepositFor(depositor).length, 0);
        assertEq(nftLender.getLoanFor(depositor).length, 0);

        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 0);
        assertEq(nftToken.balanceOf(liquidator), 1);
    }

    function testLiquidateAllWithDebtGrowing() public {
        uint256 borrowedAmount = 75 ether;
        vm.deal(address(nftLender), 100 ether);
        vm.deal(depositor, 100 ether);
        vm.deal(liquidator, 250 ether);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _borrow(borrowedAmount);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);
        vm.stopPrank();

        skip(2 * 60 * 60 * 24 * 30); // 2 months

        uint256 approxPositionAmountWithFee = 250 ether;
        vm.prank(liquidator);
        _liquidateAll(approxPositionAmountWithFee, depositor);

        assertEq(nftLender.getDepositFor(depositor).length, 0);
        assertEq(nftLender.getLoanFor(depositor).length, 0);

        assertGte(liquidator.balance, 50 ether);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 0);
        assertEq(nftToken.balanceOf(liquidator), 1);
    }

    function testLiquidateAllWithMultipleLoans() public {
        uint256 borrowedAmount = 25 ether;
        vm.deal(address(nftLender), 100 ether);
        vm.deal(depositor, 100 ether);
        vm.deal(liquidator, 250 ether);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _borrow(borrowedAmount);
        _borrow(borrowedAmount);
        _borrow(borrowedAmount);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);
        vm.stopPrank();

        skip(10 * 24 * 60 * 60); // 10 days

        vm.prank(depositor);
        nftLender.getFullDebt();

        uint256 approxPositionAmountWithFee = 96 ether;
        vm.prank(liquidator);
        _liquidateAll(approxPositionAmountWithFee, depositor);

        assertEq(nftLender.getDepositFor(depositor).length, 0);
        assertEq(nftLender.getLoanFor(depositor).length, 0);

        assertGte(liquidator.balance, 250 ether - 96 ether);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 0);
        assertEq(nftToken.balanceOf(liquidator), 1);
    }

    function testCannotLiquidateAllWithMultipleLoansDueToInsufficientPayment() public {
        uint256 borrowedAmount = 25 ether;
        vm.deal(address(nftLender), 100 ether);
        vm.deal(depositor, 100 ether);
        vm.deal(liquidator, 250 ether);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _borrow(borrowedAmount);
        _borrow(borrowedAmount);
        _borrow(borrowedAmount);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);
        vm.stopPrank();

        skip(10 * 24 * 60 * 60); // 10 days

        vm.prank(depositor);
        nftLender.getFullDebt();

        uint256 approxPositionAmountWithFee = 95 ether;
        vm.prank(liquidator);
        vm.expectRevert("value sent not covering debt");
        _liquidateAll(approxPositionAmountWithFee, depositor);

        assertEq(nftLender.getDepositFor(depositor).length, 1);
        assertEq(nftLender.getLoanFor(depositor).length, 3);

        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);
        assertEq(nftToken.balanceOf(liquidator), 0);
    }

    function _deposit(uint256 _tokenId) private {
        nftToken.approve(address(nftLender), _tokenId);
        nftLender.deposit(address(nftToken), _tokenId);
    }

    function _borrow(uint256 _amount) private {
        nftLender.borrow(_amount);
    }

    function _withdrawOne(address _collection, uint256 _id) private returns (bool success) {
        bytes memory data = abi.encodeWithSignature("withdraw(address,uint256)", _collection, _id);
        (success, ) = address(nftLender).call(data);
        assertTrue(success, "Call failed");
    }

    function _withdrawAll(uint256 _value) private returns (bool success) {
        bytes memory data = abi.encodeWithSignature("withdrawAndReimburseAll()");
        (success, ) = address(nftLender).call{ value: _value }(data);
        assertTrue(success, "Call failed");
    }

    function _liquidateAll(uint256 _value, address _userToLiquidate) private returns (bool success) {
        bytes memory data = abi.encodeWithSignature("liquidateAll(address)", _userToLiquidate);
        (success, ) = address(nftLender).call{ value: _value }(data);
        assertTrue(success, "Call failed");
    }

    function _reimburseLoan(uint256 _value, uint256 _loanId) private returns (bool success) {
        bytes memory data = abi.encodeWithSignature("reimburseLoan(uint256)", _loanId);
        (success, ) = address(nftLender).call{ value: _value }(data);
        assertTrue(success, "Call failed");
    }
}
