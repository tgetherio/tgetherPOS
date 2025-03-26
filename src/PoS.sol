// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

contract PoS {
    // --- Storage Structures ---
    struct Payee {
        address payable recipient;
        uint256 amount;
        uint256 chainID; // for cross-chain functionality
        bool isPaid;
    }

    struct Order {
        string orderID;
        Payee[] payees;
        uint256 totalAmount;
        uint256 currentAmount;
        bool processed;
    }

    struct Vendor {
        string vendorID;
        mapping(string => Order) orders;  // orderID => Order
        bool exists;
    }

    // --- Main Storage Variables ---
    mapping(string => Vendor) private vendors; // vendorID => Vendor
    mapping(address => bool) public approvedAddresses;

    // --- Modifiers ---
    modifier onlyApproved() {
        require(approvedAddresses[msg.sender], "Not an approved address");
        _;
    }

    modifier vendorExists(string memory vendorID) {
        require(vendors[vendorID].exists, "Vendor does not exist");
        _;
    }

    // --- Constructor ---
    constructor() {
        // Initialize the contract deployer as an approved address
        approvedAddresses[msg.sender] = true;
    }

    // --- Vendor Management ---
    function createVendor(string calldata vendorID) external onlyApproved {
        Vendor storage vendor = vendors[vendorID];
        require(!vendor.exists, "Vendor already exists");

        vendor.vendorID = vendorID;
        vendor.exists = true;
    }

    function deleteVendor(string calldata vendorID) external onlyApproved vendorExists(vendorID) {
        delete vendors[vendorID];
    }

    // --- Order Management ---
    function createOrder(
        string calldata vendorID,
        string calldata orderID,
        Payee[] calldata payees
    ) external onlyApproved vendorExists(vendorID) {
        Vendor storage vendor = vendors[vendorID];
        Order storage order = vendor.orders[orderID];
        require(order.payees.length == 0, "Order already exists");

        uint256 totalAmt = 0;

        for (uint i = 0; i < payees.length; i++) {
            order.payees.push(Payee({
                recipient: payees[i].recipient,
                amount: payees[i].amount,
                chainID: payees[i].chainID,
                isPaid: false
            }));

            totalAmt += payees[i].amount;
        }

        order.orderID = orderID;
        order.totalAmount = totalAmt;
        order.currentAmount = 0;
        order.processed = false;
    }

    // --- Payment Function (Including Cross-Chain Hooks) ---
    function pay(
        string calldata vendorID,
        string calldata orderID,
        address payAs,
        uint256 payAsChain
    ) external payable onlyApproved vendorExists(vendorID) {
        Vendor storage vendor = vendors[vendorID];
        Order storage order = vendor.orders[orderID];

        require(!order.processed, "Order already processed");
        require(msg.value + order.currentAmount <= order.totalAmount, "Exceeds total amount");

        order.currentAmount += msg.value;

        if (order.currentAmount == order.totalAmount) {
            order.processed = true;

            // Cross-chain integration hook (e.g., emit event for off-chain relayers)
            emit PaymentProcessed(vendorID, orderID, payAs, payAsChain, order.totalAmount);
        }
    }

    // --- Admin Functions ---
    function approveAddress(address addr) external onlyApproved {
        approvedAddresses[addr] = true;
    }

    function removeApprovedAddress(address addr) external onlyApproved {
        approvedAddresses[addr] = false;
    }

    // --- Events ---
    event PaymentProcessed(
        string vendorID,
        string orderID,
        address indexed payAs,
        uint256 indexed payAsChain,
        uint256 totalAmount
    );
}