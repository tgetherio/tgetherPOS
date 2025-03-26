// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol"; // For step-by-step logging
import "../src/PoS.sol";

contract PoSTest is Test {
    PoS pos;                        // Instance of the PoS contract
    address vendor = address(0x1);  // Vendor's address (Airbnb)
    address payer1 = address(0x2);  // First payer
    address payer2 = address(0x3);  // Second payer
    address payer3 = address(0x4);  // Third payer
    address admin = address(this);  // Test contract as admin

    function setUp() public {
        // Deploy the PoS contract
        pos = new PoS();
        // Approve the vendor address (assuming the contract requires this)
        pos.approveAddress(vendor);
        // Fund the payers with enough ether for testing
        vm.deal(payer1, 10 ether);
        vm.deal(payer2, 10 ether);
        vm.deal(payer3, 10 ether);
        console.log("Setup complete: PoS contract deployed, vendor approved, payers funded with 10 ether each");
    }

    function testFullFlow() public {
        // Step 1: Vendor creates their profile
        vm.prank(vendor);
        pos.createVendor("Airbnb");
        console.log("Step 1: Vendor 'Airbnb' created");

        // Step 2: Vendor creates an order for 3 payers, total 3 ether
        uint256 totalAmount = 3 ether;
        uint256 numPayers = 3;
        vm.prank(vendor);
        pos.createOrder("Airbnb", "Order1", totalAmount, numPayers);
        console.log("Step 2: Order created: total=%s, numPayers=%s", totalAmount, numPayers);

        // Step 3: Each payer sends their payment (1 ether each)
        uint256 expectedAmount = totalAmount / numPayers; // 1 ether
        console.log("Vendor balance before payments: %s", vendor.balance);

        // Payer1 pays
        vm.prank(payer1);
        pos.pay{value: expectedAmount}("Airbnb", "Order1", payer1, 1);
        (uint256 t1, uint256 c1, bool p1, ) = pos.getOrderDetails("Airbnb", "Order1");
        console.log("Step 3a: After Payer1: total=%s, current=%s, processed=%s", t1, c1, p1);

        // Payer2 pays
        vm.prank(payer2);
        pos.pay{value: expectedAmount}("Airbnb", "Order1", payer2, 1);
        (uint256 t2, uint256 c2, bool p2, ) = pos.getOrderDetails("Airbnb", "Order1");
        console.log("Step 3b: After Payer2: total=%s, current=%s, processed=%s", t2, c2, p2);

        // Payer3 pays with debugging
        vm.prank(payer3);
        try pos.pay{value: expectedAmount}("Airbnb", "Order1", payer3, 1) {
            console.log("Step 3c: Payer3 payment succeeded");
        } catch Error(string memory reason) {
            console.log("Step 3c: Payer3 payment reverted with reason: %s", reason);
            assertTrue(false, "Payer3 payment should not revert");
        } catch {
            console.log("Step 3c: Payer3 payment reverted without reason");
            assertTrue(false, "Payer3 payment should not revert");
        }

        // Step 4: Verify the final state
        (uint256 orderTotal, uint256 currentAmount, bool processed, ) = pos.getOrderDetails("Airbnb", "Order1");
        console.log("Step 4: Final state: total=%s, current=%s, processed=%s", orderTotal, currentAmount, processed);
        assertEq(orderTotal, 0, "Total amount should be reset after processing");
        assertEq(currentAmount, 3 ether, "Current amount should be 3 ether");
        assertTrue(processed, "Order should be marked as processed");

        // Step 5: Verify vendor received payment
        console.log("Vendor balance after processing: %s", vendor.balance);
        assertEq(vendor.balance, 3 ether, "Vendor should have received 3 ether");

        // Step 6: Verify contributions are tracked correctly
        PoS.Contribution[] memory contributions = pos.getContributions("Airbnb", "Order1");
        assertEq(contributions.length, 3, "There should be 3 contributions");
        assertEq(contributions[0].payer, payer1, "Payer1 should be recorded");
        assertEq(contributions[0].amount, 1 ether, "Payer1 paid 1 ether");
        assertEq(contributions[1].payer, payer2, "Payer2 should be recorded");
        assertEq(contributions[1].amount, 1 ether, "Payer2 paid 1 ether");
        assertEq(contributions[2].payer, payer3, "Payer3 should be recorded");
        assertEq(contributions[2].amount, 1 ether, "Payer3 paid 1 ether");
        console.log("Step 6: Contributions verified for all 3 payers");
    }

    // Additional Test: Incorrect payment amount
    function testIncorrectPaymentAmount() public {
        vm.prank(vendor);
        pos.createVendor("Airbnb");
        vm.prank(vendor);
        pos.createOrder("Airbnb", "Order1", 3 ether, 3);

        vm.prank(payer1);
        vm.expectRevert("Incorrect payment amount");
        pos.pay{value: 0.5 ether}("Airbnb", "Order1", payer1, 1);
        console.log("Test: Payment of 0.5 ether (less than expected) reverted");

        vm.prank(payer1);
        vm.expectRevert("Incorrect payment amount");
        pos.pay{value: 1.5 ether}("Airbnb", "Order1", payer1, 1);
        console.log("Test: Payment of 1.5 ether (more than expected) reverted");
    }

    // Additional Test: Double payment from the same address
    function testDoublePayment() public {
        vm.prank(vendor);
        pos.createVendor("Airbnb");
        vm.prank(vendor);
        pos.createOrder("Airbnb", "Order1", 3 ether, 3);

        vm.prank(payer1);
        pos.pay{value: 1 ether}("Airbnb", "Order1", payer1, 1);

        vm.prank(payer1);
        vm.expectRevert("Already paid");
        pos.pay{value: 1 ether}("Airbnb", "Order1", payer1, 1);
        console.log("Test: Second payment from Payer1 reverted");
    }

    // Additional Test: Payment after order is processed
    function testPaymentAfterProcessed() public {
        vm.prank(vendor);
        pos.createVendor("Airbnb");
        vm.prank(vendor);
        pos.createOrder("Airbnb", "Order1", 3 ether, 3);

        vm.prank(payer1);
        pos.pay{value: 1 ether}("Airbnb", "Order1", payer1, 1);
        vm.prank(payer2);
        pos.pay{value: 1 ether}("Airbnb", "Order1", payer2, 1);
        vm.prank(payer3);
        pos.pay{value: 1 ether}("Airbnb", "Order1", payer3, 1);

        vm.prank(payer1);
        vm.expectRevert("Order already processed");
        pos.pay{value: 1 ether}("Airbnb", "Order1", payer1, 1);
        console.log("Test: Payment after order processed reverted");
    }

    // Additional Test: Unauthorized vendor creation
    function testUnauthorizedVendorCreation() public {
        address unauthorized = address(0x5);
        vm.prank(unauthorized);
        vm.expectRevert("Not an approved address");
        pos.createVendor("UnauthorizedVendor");
        console.log("Test: Unauthorized vendor creation reverted");
    }
}