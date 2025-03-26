// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {PoS} from "../src/PoS.sol";

contract PoSTest is Test {
    // Contract instance
    PoS public pos;

    // Sample vendor and order details
    string vendorID = "airbnb";
    string orderID = "order123";

    // Payee addresses (two simulated users)
    address payable user1 = payable(address(0x1));
    address payable user2 = payable(address(0x2));

    // Cross-chain address and chain ID for simulation
    address payAs = address(0xABC);
    uint256 payAsChain = 8453; // BASE L2

    function setUp() public {
        // Deploy PoS contract
        pos = new PoS();

        // Approve the test contract to interact
        pos.approveAddress(address(this));

        // Create vendor
        pos.createVendor(vendorID);

        // Explicitly declare payees array (2 payees)
        PoS.Payee ;
        payees[0] = PoS.Payee(user1, 1 ether, payAsChain, false);
        payees[1] = PoS.Payee(user2, 1 ether, payAsChain, false);

        // Create order with explicitly declared payees array
        pos.createOrder(vendorID, orderID, payees);
    }

    // Main Test - Two users paying half each
    function testTwoUsersFundOrder() public {
        // User 1 pays 1 ether
        pos.pay{value: 1 ether}(vendorID, orderID, payAs, payAsChain);

        // Validate intermediate state (half funded)
        (,uint256 currentAmountBefore,,bool processedBefore) = getOrderInfo(vendorID, orderID);
        assertEq(currentAmountBefore, 1 ether, "Order should have 1 ether funded");
        assertFalse(processedBefore, "Order should not be processed yet");

        // User 2 pays remaining 1 ether
        pos.pay{value: 1 ether}(vendorID, orderID, payAs, payAsChain);

        // Validate final state (fully funded and processed)
        (,uint256 currentAmountAfter,,bool processedAfter) = getOrderInfo(vendorID, orderID);
        assertEq(currentAmountAfter, 2 ether, "Order should have total 2 ether funded");
        assertTrue(processedAfter, "Order should be processed");

        // Validate event emission
        vm.expectEmit(true, true, false, true);
        emit PoS.PaymentProcessed(vendorID, orderID, payAs, payAsChain, 2 ether);
        pos.pay{value: 0}(vendorID, orderID, payAs, payAsChain); // Trigger event expectation
    }

    // Helper function to access internal state (optional but helpful)
    function getOrderInfo(string memory _vendorID, string memory _orderID) 
        internal view returns (
            string memory, uint256, uint256, bool
        ) {
        PoS.Vendor storage vendor = pos.vendors(_vendorID);
        PoS.Order storage order = vendor.orders[_orderID];
        return (
            order.orderID,
            order.currentAmount,
            order.totalAmount,
            order.processed
        );
    }

    // Allow the test contract to send ETH
    receive() external payable {}
}