// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/PoS.sol"; // adjust the path as necessary

contract PoSTest is Test {
    PoS public pos;
    
    // Test addresses (using Foundry’s cheatcodes)
    address public user1;
    address public user2;
    address public nonApproved;
    address public approvedUser;
    address public user3; // used in refund tests

    function setUp() public {
        // Deploy the PoS contract; the deployer (this contract) is approved by default.
        pos = new PoS();

        // Set up test addresses using vm.addr(n)
        user1 = vm.addr(1);
        user2 = vm.addr(2);
        nonApproved = vm.addr(3);
        approvedUser = vm.addr(4);
        user3 = vm.addr(5);

        // Approve an extra address so we can test approved address management.
        pos.approveAddress(approvedUser);
    }

    /*//////////////////////////////////////////////////////////////
                              APPROVED ACCESS
    //////////////////////////////////////////////////////////////*/

    function testOnlyApprovedCanCallFunctions() public {
        // nonApproved address should not be allowed to create a vendor.
        vm.prank(nonApproved);
        vm.expectRevert("Not an approved address");
        pos.createVendor("NonApprovedVendor");
    }

    function testApprovedAddressManagement() public {
        // approvedUser was approved in setUp; let it create a vendor.
        vm.prank(approvedUser);
        pos.createVendor("ApprovedVendor");
        
        // Now remove approval and check that the address can no longer perform restricted actions.
        pos.removeApprovedAddress(approvedUser);
        vm.prank(approvedUser);
        vm.expectRevert("Not an approved address");
        pos.createVendor("ShouldFail");
    }

    /*//////////////////////////////////////////////////////////////
                           VENDOR MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function testCreateVendorAndDeleteVendor() public {
        // Create a vendor as an approved address (deployer)
        pos.createVendor("Vendor1");
        uint256 vendorID = 1; // first vendor should have ID 1

        // Create an order on the vendor to prove it exists.
        pos.createOrder(vendorID, 100 ether, 2);

        // Now delete the vendor.
        pos.deleteVendor(vendorID);

        // Subsequent operations using the vendor should revert.
        vm.expectRevert("Vendor does not exist");
        pos.createOrder(vendorID, 100 ether, 2);
    }

    /*//////////////////////////////////////////////////////////////
                           ORDER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function testCreateOrder() public {
        pos.createVendor("VendorOrder");
        uint256 vendorID = 1;
        pos.createOrder(vendorID, 100 ether, 2);

        (uint256 totalAmount, uint256 currentAmount, bool processed, uint256 numPayers) = pos.getOrderDetails(vendorID, 1);
        assertEq(totalAmount, 100 ether, "Total amount mismatch");
        assertEq(currentAmount, 0, "Current amount should be zero initially");
        assertTrue(!processed, "Order should not be processed yet");
        assertEq(numPayers, 2, "Number of payers mismatch");
    }

    function testCreateOrderFailsForNonExistentVendor() public {
        // Calling createOrder with a vendorID that does not exist should revert.
        vm.expectRevert("Vendor does not exist");
        pos.createOrder(999, 100 ether, 2);
    }

    function testGetOrderDetailsFailsForNonExistentOrder() public {
        pos.createVendor("VendorTest");
        uint256 vendorID = 1;
        vm.expectRevert("Order does not exist");
        pos.getOrderDetails(vendorID, 999);
    }

    function testGetContributionsFailsForNonExistentOrder() public {
        pos.createVendor("VendorTest");
        uint256 vendorID = 1;
        vm.expectRevert("Order does not exist");
        pos.getContributions(vendorID, 999);
    }

    /*//////////////////////////////////////////////////////////////
                               PAYMENT
    //////////////////////////////////////////////////////////////*/

    function testPayAndProcessOrder() public {
        pos.createVendor("VendorPay");
        uint256 vendorID = 1;
        uint256 orderTotal = 100 ether;
        uint256 numPayers = 2;
        pos.createOrder(vendorID, orderTotal, numPayers);
        uint256 expectedPayment = orderTotal / numPayers; // 50 ether each

        // Fund test users.
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);

        // Payment from user1.
        vm.prank(user1);
        pos.pay{value: expectedPayment}(vendorID, 1, address(0), 0);

        // Payment from user2 should complete the order.
        vm.prank(user2);
        // Expect the PaymentProcessed event to be emitted when order is fully paid.
        vm.expectEmit(true, true, false, true);
        emit PoS.PaymentProcessed(vendorID, 1, user2, block.chainid, orderTotal);
        pos.pay{value: expectedPayment}(vendorID, 1, address(0), 0);

        // Verify order is now processed and the currentAmount equals the total.
        ( , uint256 currentAmount, bool processed, ) = pos.getOrderDetails(vendorID, 1);
        assertTrue(processed);
        assertEq(currentAmount, orderTotal, "Current amount should equal total after processing");
    }

    function testPayWithCustomChainID() public {
        pos.createVendor("VendorCustomChain");
        uint256 vendorID = 1;
        pos.createOrder(vendorID, 100 ether, 2);
        uint256 expectedPayment = 50 ether;

        vm.deal(user1, 100 ether);
        uint256 customChainID = 999;

        // Payment with payAs explicitly equal to msg.sender uses the provided chainID.
        vm.prank(user1);
        pos.pay{value: expectedPayment}(vendorID, 1, user1, customChainID);

        PoS.Contribution[] memory contributions = pos.getContributions(vendorID, 1);
        assertEq(contributions[0].chainID, customChainID, "ChainID should match custom value");
    }

    function testDoublePaymentReverts() public {
        pos.createVendor("VendorDouble");
        uint256 vendorID = 1;
        pos.createOrder(vendorID, 100 ether, 2);
        uint256 expectedPayment = 50 ether;

        vm.deal(user1, 100 ether);

        // First payment succeeds.
        vm.prank(user1);
        pos.pay{value: expectedPayment}(vendorID, 1, address(0), 0);

        // A second payment from the same address should revert.
        vm.prank(user1);
        vm.expectRevert("Already paid");
        pos.pay{value: expectedPayment}(vendorID, 1, address(0), 0);
    }

    function testIncorrectPaymentAmountReverts() public {
        pos.createVendor("VendorIncorrectAmount");
        uint256 vendorID = 1;
        pos.createOrder(vendorID, 100 ether, 2);
        uint256 wrongPayment = 40 ether; // Expected is 50 ether

        vm.deal(user1, 100 ether);
        vm.prank(user1);
        vm.expectRevert("Incorrect payment amount");
        pos.pay{value: wrongPayment}(vendorID, 1, address(0), 0);
    }

    function testProxyPaymentReverts() public {
        pos.createVendor("VendorProxy");
        uint256 vendorID = 1;
        pos.createOrder(vendorID, 100 ether, 2);
        uint256 expectedPayment = 50 ether;

        vm.deal(user1, 100 ether);
        // Attempt a proxy payment: payAs is non-zero and not equal to msg.sender.
        vm.prank(user1);
        vm.expectRevert("Proxy payments not allowed");
        pos.pay{value: expectedPayment}(vendorID, 1, user2, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               REFUND
    //////////////////////////////////////////////////////////////*/

    function testRefundProcess() public {
        // Create a vendor where user1 becomes the vendor payout address.
        vm.prank(user1);
        pos.createVendor("VendorRefund");
        uint256 vendorID = 1;
        pos.createOrder(vendorID, 100 ether, 2);
        uint256 expectedPayment = 50 ether;

        // Fund contributors.
        vm.deal(user2, 100 ether);

        // Only one payment is made so far.
        vm.prank(user2);
        pos.pay{value: expectedPayment}(vendorID, 1, address(0), 0);

        // Record user2's balance before refund.
        uint256 balanceBeforeRefund = user2.balance;

        // Initiate refund from the vendor (user1).
        vm.prank(user1);
        pos.refund(vendorID, 1);

        // After refund, the order's current amount should be reset.
        ( , uint256 currentAmount, , ) = pos.getOrderDetails(vendorID, 1);
        assertEq(currentAmount, 0, "Order current amount should be zero after refund");

        // Verify that user2 was refunded the expected payment.
        uint256 balanceAfterRefund = user2.balance;
        assertEq(balanceAfterRefund - balanceBeforeRefund, expectedPayment, "Refund amount incorrect");
    }

    function testRefundRevertsIfProcessed() public {
        pos.createVendor("VendorRefundProcessed");
        uint256 vendorID = 1;
        pos.createOrder(vendorID, 100 ether, 2);
        uint256 expectedPayment = 50 ether;

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);

        // Complete the order by receiving both payments.
        vm.prank(user1);
        pos.pay{value: expectedPayment}(vendorID, 1, address(0), 0);
        vm.prank(user2);
        pos.pay{value: expectedPayment}(vendorID, 1, address(0), 0);

        // A refund should now revert because the order has been processed.
        vm.prank(user1);
        vm.expectRevert("Order already processed");
        pos.refund(vendorID, 1);
    }

    function testOnlyVendorCanRefund() public {
        // Create a vendor with user1 as the payout address.
        vm.prank(user1);
        pos.createVendor("VendorOnlyVendorRefund");
        uint256 vendorID = 1;
        pos.createOrder(vendorID, 100 ether, 2);
        uint256 expectedPayment = 50 ether;

        vm.deal(user2, 100 ether);
        vm.prank(user2);
        pos.pay{value: expectedPayment}(vendorID, 1, address(0), 0);

        // A refund initiated by a non-vendor (user2) should revert.
        vm.prank(user2);
        vm.expectRevert("Only the vendor can initiate refunds");
        pos.refund(vendorID, 1);
    }

    /*//////////////////////////////////////////////////////////////
                           GETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function testGetContributions() public {
        pos.createVendor("VendorContrib");
        uint256 vendorID = 1;
        pos.createOrder(vendorID, 100 ether, 2);
        uint256 expectedPayment = 50 ether;

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);

        vm.prank(user1);
        pos.pay{value: expectedPayment}(vendorID, 1, address(0), 0);
        vm.prank(user2);
        pos.pay{value: expectedPayment}(vendorID, 1, address(0), 0);

        PoS.Contribution[] memory contributions = pos.getContributions(vendorID, 1);
        assertEq(contributions.length, 2, "Should have two contributions");
        assertEq(contributions[0].amount, expectedPayment, "First contribution amount mismatch");
        assertEq(contributions[1].amount, expectedPayment, "Second contribution amount mismatch");
    }
    
    // Emit declaration so that vm.expectEmit can match the event.
    event PaymentProcessed(
        uint256 vendorID,
        uint256 orderID,
        address indexed payAs,
        uint256 indexed payAsChain,
        uint256 totalAmount
    );
}
