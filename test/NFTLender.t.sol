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
    event Borrow(address indexed borrower, uint256 amount);
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
        vm.expectRevert("Asked amount bigger than collateral");
        _borrow(amount);
        vm.stopPrank();
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
    }

    function testCannotWithdrawAsNoCollateral() public {
        vm.startPrank(depositor);
        vm.expectRevert("Asked amount bigger than collateral");
        _borrow(10);
        vm.stopPrank();
        assertEq(depositor.balance, 0);
    }

    function testCannotWithdrawAsNoLoan() public {
        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        vm.expectRevert("No loan made");
        _withdraw(0);
        vm.stopPrank();
        assertEq(depositor.balance, 0);
    }

    function testWithdrawAfterBorrow() public {
        vm.deal(address(nftLender), 100 ether);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _borrow(10 ether);
        assertEq(depositor.balance, 10 ether);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);

        _withdraw(0);
        vm.stopPrank();

        assertEq(nftToken.balanceOf(depositor), 1);
        assertEq(nftToken.balanceOf(address(nftLender)), 0);
    }

    function testCannotWithdrawAsNoValueSent() public {
        vm.deal(address(nftLender), 100 ether);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _borrow(10 ether);
        assertEq(depositor.balance, 10 ether);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);

        skip(60 * 60); // 1 hour
        vm.expectRevert("value sent not covering debt");
        _withdraw(0);
        vm.stopPrank();

        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);
    }

    function testWithdrawWithSomeWaitingAndExactFeePayment() public {
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
        _withdraw(10 ether + fee);
        vm.stopPrank();

        //we should not pay more that 1 eth of fee
        assertEq(depositor.balance, 100 ether - fee);

        assertEq(nftToken.balanceOf(depositor), 1);
        assertEq(nftToken.balanceOf(address(nftLender)), 0);
    }

    function testWithdrawWithSomeWaitingAndReturnEth() public {
        vm.deal(address(nftLender), 100 ether);
        vm.deal(depositor, 100 ether);

        vm.startPrank(depositor);
        _deposit(FIRST_TOKEN_ID);
        _borrow(10 ether);
        assertGte(depositor.balance, 110 ether);
        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);

        skip(60 * 60); // 1 hour
        _withdraw(100 ether);
        vm.stopPrank();

        //we should not pay more that 1 eth of fee
        uint256 fee = 60 * 60 * (10 ether / 1e15) * nftLender.INTEREST_RATE();
        assertEq(depositor.balance, 100 ether - fee);

        assertEq(nftToken.balanceOf(depositor), 1);
        assertEq(nftToken.balanceOf(address(nftLender)), 0);
    }

    function testCannotLiquidateWithCollateralStillCovering() public {
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
        _liquidate(borrowedAmount, depositor);

        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 1);
        assertEq(nftToken.balanceOf(liquidator), 0);
    }

    function testLiquidate() public {
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
        _liquidate(borrowedAmount, depositor);
        vm.clearMockedCalls();

        assertEq(nftToken.balanceOf(depositor), 0);
        assertEq(nftToken.balanceOf(address(nftLender)), 0);
        assertEq(nftToken.balanceOf(liquidator), 1);
    }

    function _deposit(uint256 _tokenId) private {
        nftToken.approve(address(nftLender), _tokenId);
        nftLender.deposit(address(nftToken), _tokenId);
    }

    function _borrow(uint256 _amount) private {
        nftLender.borrow(_amount);
    }

    function _withdraw(uint256 _value) private returns (bool success) {
        bytes memory data = abi.encodeWithSignature("withdraw()");
        (success, ) = address(nftLender).call{ value: _value }(data);
    }

    function _liquidate(uint256 _value, address _userToLiquidate) private returns (bool success) {
        bytes memory data = abi.encodeWithSignature("liquidate(address)", _userToLiquidate);
        (success, ) = address(nftLender).call{ value: _value }(data);
    }
}
