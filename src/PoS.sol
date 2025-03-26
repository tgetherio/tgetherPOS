// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

contract PoS {


    // --- Storage Structures ---
    struct Contribution {
        address payer;    // Address of the payer
        uint256 amount;   // Amount they paid
        uint256 chainID;  // Chain ID for cross-chain tracking
    }

    struct Vendor {
        string vendorID;                // Unique vendor identifier
        address payable vendorAddress;  // Address to receive funds
        mapping(string => Order) orders;
        bool exists;
    }

    struct Order {
        string orderID;           // Unique order identifier
        uint256 totalAmount;      // Total amount to collect
        uint256 currentAmount;    // Amount collected so far
        uint256 numPayers;        // Expected number of payers (for even division)
        mapping(address => uint256) contributions; // Tracks individual contributions
        Contribution[] contributionList; // List of all contributions
        bool processed;           // Whether the order is fully paid and processed
    }


    // --- Main Storage Variables ---
    string[] public vendorList;               // Array to track all vendor IDs
    mapping(string => uint256) private vendorIndex; // Maps vendorID to its index in vendorList
    mapping(string => Vendor) private vendors;      // Maps vendorID to Vendor
    mapping(address => bool) public approvedAddresses; // Access control for approved addresses

    // --- Modifiers ---
    // restricts function access to approved addresses
    modifier onlyApproved() {
        require(approvedAddresses[msg.sender], "Not an approved address");
        _;
    }

    // ensures vendor exists before proceeding
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
        vendor.vendorAddress = payable(msg.sender); // Vendor’s payout address
        vendor.exists = true;
        vendorList.push(vendorID);
        vendorIndex[vendorID] = vendorList.length - 1;
    }

    function deleteVendor(string calldata vendorID) external onlyApproved vendorExists(vendorID) {
        uint256 index = vendorIndex[vendorID];
        string memory lastVendorID = vendorList[vendorList.length - 1];
        vendorList[index] = lastVendorID;
        vendorIndex[lastVendorID] = index;
        vendorList.pop();
        delete vendorIndex[vendorID];
        delete vendors[vendorID];
    }


    // --- Order Management ---
    function createOrder(
        string calldata vendorID,
        string calldata orderID,
        uint256 totalAmount,
        uint256 numPayers
    ) external onlyApproved vendorExists(vendorID) {
        Vendor storage vendor = vendors[vendorID];
        Order storage order = vendor.orders[orderID];
        require(bytes(order.orderID).length == 0, "Order already exists");
        order.orderID = orderID;
        order.totalAmount = totalAmount;
        order.currentAmount = 0;
        order.numPayers = numPayers; // For even division
        order.processed = false;
    }


    // --- Payment Function (Including Cross-Chain Hooks) ---
    function pay(
        string calldata vendorID,
        string calldata orderID,
        address payAs,
        uint256 payAsChain
    ) external payable vendorExists(vendorID) {
        require(msg.sender == payAs, "Must pay as yourself");
        Vendor storage vendor = vendors[vendorID];
        Order storage order = vendor.orders[orderID];
        require(!order.processed, "Order already processed");

        // Calculate expected payment per payer
        uint256 expectedAmount = order.totalAmount / order.numPayers;
        require(msg.value == expectedAmount, "Incorrect payment amount");

        // Prevent double payment from the same address
        require(order.contributions[payAs] == 0, "Already paid");

        // Record contribution
        order.contributions[payAs] = msg.value;
        order.contributionList.push(Contribution(payAs, msg.value, payAsChain));
        order.currentAmount += msg.value;

        // Process payment if total is reached
        if (order.currentAmount == order.totalAmount) {
            order.processed = true;
            uint256 amount = order.totalAmount;
            order.totalAmount = 0; // Prevent reentrancy
            emit PaymentProcessed(vendorID, orderID, payAs, payAsChain, amount);
            vendor.vendorAddress.transfer(amount);
        }
    }


    // --- Admin Functions ---
    function approveAddress(address addr) external onlyApproved {
        approvedAddresses[addr] = true;
    }

    function removeApprovedAddress(address addr) external onlyApproved {
        approvedAddresses[addr] = false;
    }

    function refund(string calldata vendorID, string calldata orderID) 
        external onlyApproved vendorExists(vendorID) {
        Vendor storage vendor = vendors[vendorID];
        Order storage order = vendor.orders[orderID];
        require(!order.processed, "Order already processed");
        require(order.currentAmount > 0, "No funds to refund");
        uint256 amount = order.currentAmount;
        order.currentAmount = 0;
        payable(msg.sender).transfer(amount);
    }

    // --- Getter Functions ---
    function getOrderDetails(string calldata vendorID, string calldata orderID)
        external view vendorExists(vendorID)
        returns (uint256 totalAmount, uint256 currentAmount, bool processed, uint256 numPayers) {
        Order storage order = vendors[vendorID].orders[orderID];
        return (order.totalAmount, order.currentAmount, order.processed, order.numPayers);
    }

    function getContributions(string calldata vendorID, string calldata orderID)
        external view vendorExists(vendorID)
        returns (Contribution[] memory) {
        return vendors[vendorID].orders[orderID].contributionList;
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