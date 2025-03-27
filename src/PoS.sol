// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PoS is ReentrancyGuard, Ownable{


    // --- Storage Structures ---
    struct Contribution {
        address payer;    // Address of the payer
        uint256 amount;   // Amount they paid
        uint256 chainID;  // Chain ID for cross-chain tracking
    }

    struct Vendor {
        uint256 vendorID;                // Unique vendor identifier
        string name;
        address payable vendorAddress;  // Address to receive funds
        mapping(uint256 => Order) orders;
        bool exists;
    }

    struct Order {
        uint256 orderID;           // Unique order identifier
        uint256 totalAmount;      // Total amount to collect
        uint256 currentAmount;    // Amount collected so far
        uint256 numPayers;        // Expected number of payers (for even division)
        mapping(address => uint256) contributions; // Tracks individual contributions
        Contribution[] contributionList; // List of all contributions
        bool processed;           // Whether the order is fully paid and processed
        bool refunded;            // Whether the order was refunded
    }

    // Global counters
    uint256 public nextVendorID = 1;
    uint256 public nextOrderID = 1;

    // --- Main Storage Variables ---
    uint256[] public vendorList;               // Array to track all vendor IDs
    mapping(uint256 => uint256) private vendorIndex; // Maps vendorID to its index in vendorList
    mapping(uint256 => Vendor) private vendors;      // Maps vendorID to Vendor
    mapping(address => bool) public approvedAddresses; // Access control for approved addresses

    mapping(uint256 => mapping(address => bool)) public vendorApprovedAddresses; // Access control for approved addresses
    // --- Modifiers ---
    // restricts function access to approved addresses
    modifier onlyApproved(uint256 vendorID) {
        require(approvedAddresses[msg.sender] || vendorApprovedAddresses[vendorID][msg.sender], "Not an approved address");
        _;
    }

    // ensures vendor exists before proceeding
    modifier vendorExists(uint256 vendorID) {
        require(vendors[vendorID].exists, "Vendor does not exist");
        _;
    }


    // --- Constructor ---
    constructor() Ownable(msg.sender) {
        // Initialize the contract deployer as an approved address
        approvedAddresses[msg.sender] = true;
    }


    // --- Vendor Management ---
    function createVendor(string calldata name) external {
        uint256 vendorID = nextVendorID++;
        Vendor storage vendor = vendors[vendorID];
        require(!vendor.exists, "Vendor already exists");
        vendor.vendorID = vendorID;
        vendor.name = name;
        vendor.vendorAddress = payable(msg.sender); // Vendor’s payout address
        vendor.exists = true;
        vendorList.push(vendorID);
        vendorIndex[vendorID] = vendorList.length - 1;
        vendorApprovedAddresses[vendorID][msg.sender] = true;
    }

    function deleteVendor(uint256 vendorID) external onlyApproved(vendorID) vendorExists(vendorID)  {
        uint256 index = vendorIndex[vendorID];
        uint256 lastVendorID = vendorList[vendorList.length - 1];
        vendorList[index] = lastVendorID;
        vendorIndex[lastVendorID] = index;
        vendorList.pop();
        delete vendorIndex[vendorID];
        delete vendors[vendorID];
    }


    // --- Order Management ---
    function createOrder(
        uint256 vendorID,
        uint256 totalAmount,
        uint256 numPayers
    ) external onlyApproved(vendorID) vendorExists(vendorID) {
        Vendor storage vendor = vendors[vendorID];
        uint256 orderID = nextOrderID++;
        Order storage order = vendor.orders[orderID];
        require(order.orderID == 0, "Order already exists");
        order.orderID = orderID;
        order.totalAmount = totalAmount;
        order.currentAmount = 0;
        order.numPayers = numPayers; // For even division
        order.processed = false;
    }


    // --- Payment Function (Including Cross-Chain Hooks) ---
    function pay(
        uint256 vendorID,
        uint256 orderID,
        address payAs,
        uint256 payAsChain
    ) external payable vendorExists(vendorID) {
        // Enforce direct payments only
        require(payAs == address(0) || payAs == msg.sender, "Proxy payments not allowed");

        // Determine contributor and chain ID
        address contributor = (payAs == address(0)) ? msg.sender : payAs;
        uint256 chainID = (payAs == address(0)) ? block.chainid : payAsChain;

        Vendor storage vendor = vendors[vendorID];
        Order storage order = vendor.orders[orderID];
        require(!order.processed, "Order already processed");

        // Calculate expected payment per payer
        uint256 expectedAmount = order.totalAmount / order.numPayers;
        require(msg.value == expectedAmount, "Incorrect payment amount");

        // Prevent double payment from the same address
        require(order.contributions[payAs] == 0, "Already paid");

        // Record contribution
        order.contributions[contributor] = msg.value;
        order.contributionList.push(Contribution(contributor, msg.value, chainID));
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

    function approveVendorAddress(uint256 vendorID, address _approvedAddress ) external onlyApproved(vendorID) {
        vendorApprovedAddresses[vendorID][_approvedAddress] = true;
    }

    function removeVendorApprovedAddress(uint256 vendorID, address _unapprovedAddress) external onlyApproved(vendorID) {
         vendorApprovedAddresses[vendorID][_unapprovedAddress] = false;
    }

    // --- Admin Functions ---
    function approveAddress(address addr) external onlyOwner {
        approvedAddresses[addr] = true;
    }

    function removeApprovedAddress(address addr) external onlyOwner {
        approvedAddresses[addr] = false;
    }

    function refund(uint256 vendorID, uint256 orderID) 
        external onlyApproved vendorExists(vendorID) nonReentrant {
        Vendor storage vendor = vendors[vendorID];
        require(msg.sender == vendor.vendorAddress, "Only the vendor can initiate refunds");
        Order storage order = vendor.orders[orderID];
        require(!order.processed, "Order already processed");
        require(order.currentAmount > 0, "No funds to refund");

        // Refund each contributor
        for (uint256 i = 0; i < order.contributionList.length; i++) {
            Contribution memory contribution = order.contributionList[i];
            payable(contribution.payer).transfer(contribution.amount);
        }

        // Reset the order’s current amount
        order.currentAmount = 0;
        // Optional: Mark the order as refunded (requires adding a `refunded` bool to the Order struct)
        order.refunded = true;
    }

    // --- Getter Functions ---
    function getOrderDetails(uint256 vendorID, uint256 orderID)
        external view vendorExists(vendorID)
        returns (uint256 totalAmount, uint256 currentAmount, bool processed, uint256 numPayers) {
        Order storage order = vendors[vendorID].orders[orderID];
        require(order.orderID != 0, "Order does not exist");
        return (order.totalAmount, order.currentAmount, order.processed, order.numPayers);
    }

    function getContributions(uint256 vendorID, uint256 orderID)
        external view vendorExists(vendorID)
        returns (Contribution[] memory) {
        Order storage order = vendors[vendorID].orders[orderID];
        require(order.orderID != 0, "Order does not exist");
        return vendors[vendorID].orders[orderID].contributionList;
    }


    // --- Events ---
    event PaymentProcessed(
        uint256 vendorID,
        uint256 orderID,
        address indexed payAs,
        uint256 indexed payAsChain,
        uint256 totalAmount
    );

    event RefundProcessed(uint256 vendorID, uint256 orderID, uint256 totalRefunded);
}