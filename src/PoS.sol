// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
contract PoS is ReentrancyGuard {

    enum RefundType {
        NONE,
        PARTIAL,
        FULL
    }


    // --- Storage Structures ---
    struct Contribution {
        address payer;    // Address of the payer
        uint256 amount;   // Amount they paid
        uint256 chainID;  // Chain ID for cross-chain tracking
        uint256 amountRefunded; // Amount refunded
    }

    struct Order {
        string vendorOrderId;      // Optional vendor-specific order ID 
        uint256 totalAmount;      // Total amount to collect
        uint256 currentAmount;    // Amount collected so far
        mapping(bytes32 => Contribution) contributions;
        bytes32[] contributionKeys;
        uint256 amtRefunded;       // Amount refunded
        RefundType refundType;     // Refund type (NONE, PARTIAL, FULL)
        uint256 amtToWithold;       // Amount withhold for gas fees
        uint256 withheldSoFar;              // Flag to indicate if the amount has been withheld
    }

    struct Vendor {
        string name;
        address vendorAddress;  // Admin Address
        bool isActive;
        uint256[] orderIDs; // List of order IDs associated with this vendor
        address optionalPaymentReciever; // Optional address for payment receiver - if not recived will default to vendorAddress

    }

    
    // Global counters
    uint256 public vendorCounter = 1;
    uint256 public orderCounter = 1;

    // --- Main Storage Variables ---
    uint256[] public vendorList;               // Array to track all vendor IDs
    mapping(uint256 => uint256) private vendorIndex; // Maps vendorID to its index in vendorList
    mapping(uint256 => Vendor) private vendors;      // Maps vendorID to Vendor
    mapping(address => bool) public approvedAddresses; // Access control for approved addresses

    mapping(uint256 => Order) public orders; // Maps orderID to Order
    mapping(uint256 => uint256) public OrderVendor; // Maps orderId to vendorId
    mapping(address => uint256[]) public addressToOrderID; //Maps Address to Orders they are apart of
    mapping(uint256=> mapping(string => uint256)) public vendorOrderIDtoTgether; //Mapps a vendor's orderID to its tgether orderId


    mapping(uint256 => mapping (address => bool)) private  vendorApprovedAddresses; // Access control for vendor approved addresses

    address feeAddress; // Address to receive fees for creating orders 
    AggregatorV3Interface internal CBETHtoUSD;
    IERC20 USDCcontract;   //Address to estimate witholdings in USDC
    uint256 public fee = 1.5; // Fee on gas for managed order creation

    // --- Modifiers ---
    // restricts function access to approved addresses

    
    modifier activeVendor(uint256 vendorID) {
        require(vendors[vendorID].isActive, "Vendor is not Active");
        _;
    }

    modifier approvedOrderCreators(uint256 vendorID) {
        require(vendors[vendorID].isActive, "Vendor is not Active");
        require(msg.sender == vendors[vendorID].vendorAddress, "Only the vendor can create orders");
        _;
    }




    // --- Constructor ---
    constructor(address _CBETHtoUSD, address _USDCcontract) Ownable(msg.sender){
        // Initialize the contract deployer as an approved address
        approvedAddresses[msg.sender] = true;
        CBETHtoUSD = AggregatorV3Interface(_CBETHtoUSD);
        USDCcontract = IERC20(_USDCcontract);

        
    }


    // --- Vendor Management ---
    function createVendor(string calldata name) external onlyApproved {
        Vendor storage vendor = vendors[vendorCounter];
        require(!vendor.isActive, "Vendor already exists");
        vendor.name = name;
        vendor.vendorAddress = msg.sender; // Vendor’s payout address
        vendor.exists = true;
        vendorList.push(vendorCounter);
        vendorIndex[vendorCounter] = vendorList.length - 1;
        vendorCounter++;

    }

    function deActivateVendor(uint256 vendorID) external activeVendor(vendorID) {
        require(msg.sender == vendors[vendorID].vendorAddress, "Only the vendor can deactivate");
        uint256 index = vendorIndex[vendorID];
        uint256 lastVendorID = vendorList[vendorList.length - 1];
        if (index != vendorList.length - 1) {
            vendorList[index] = lastVendorID;
            vendorIndex[lastVendorID] = index;
        }
        vendorList.pop();
        vendors[vendorID].isActive = false;
        delete vendorIndex[vendorID];
    }

    function activateVendor(uint256 vendorID) external onlyApproved {
        require(!vendors[vendorID].isActive, "Vendor already exists");
        require(msg.sender == vendors[vendorID].vendorAddress, "You do not own this vendor");
        vendors[vendorID].isActive = true;
        vendorList.push(vendorID);
        vendorIndex[vendorID] = vendorList.length - 1;
    }

    function approveVendorAddress(
        uint256 vendorID,
        address addr
    ) external onlyApproved activeVendor(vendorID) {
       require(msg.sender == vendors[vendorID].vendorAddress, "Only the vendor can approve addresses");
        vendorApprovedAddresses[vendorID][addr] = true;
    }

    function removeVendorAddress(
        uint256 vendorID,
        address addr
    ) external onlyApproved activeVendor(vendorID) {
       require(msg.sender == vendors[vendorID].vendorAddress, "Only the vendor can approve addresses");
        vendorApprovedAddresses[vendorID][addr] = false;
    }



    // --- Order Management ---
    function createOrder(uint256 _vendorID, uint256 _amount, string memory _vendorOrderId) external activeVendor(_vendorId) returns (uint256 orderId) {
        uint256 witholding;

        if (approvedAddresses[msg.sender]) {
            (
                /* uint80 roundId */,
                int256 conversion,
                /*uint256 startedAt*/,
                /*uint256 updatedAt*/,
                /*uint80 answeredInRound*/
            ) = CBETHtoUSD.latestRoundData();

            require(conversion > 0, "Invalid price feed");
            uint256 gas = uint256(conversion) * tx.gasprice / 1e18;
            witholding = gas * fee ; // 50% more than the gas price

        } else if (vendorApprovedAddresses[_vendorID][msg.sender]) {
            witholding = 0;
        } else {
            revert("Not an approved address");
        }

        // Create a new order
        Order storage order = vendors[_vendorID].orders[orderCounter];
        order.totalAmount = _amount; // Set the total amount to 0 initially
        order.amtToWithold = witholding; // Set the amount to withhold

        if (_vendorOrderId != "") {
            order.vendorOrderId = _vendorOrderId; // Set the vendor-specific order ID
        }

        orderVendor[orderCounter] = _vendorId; // Map the order ID to the vendor ID
        vendorOrderIDtoTgether[_vendorID][_vendorOrderId] = orderCounter; // Map the vendor's order ID to the order ID
        orderCounter++;
        return orderCounter - 1; // Return the order ID

    }


    // --- Payment Function (Including Cross-Chain Hooks) ---
function pay(
    uint256 _orderID,
    address _payer,
    uint256 _payerChain,
    uint256 _amount
) external nonReentrant {
    require(orders[_orderID].totalAmount > 0, "Order does not exist");

    // Determine contributor and chain ID
    address contributor = (_payer == address(0)) ? msg.sender : _payer;
    uint256 chainID = (_payerChain == 0) ? block.chainid : _payerChain;
    bytes32 key = getContributionKey(contributor, chainID);

    Order storage order = orders[_orderID];
    Contribution storage contrib = order.contributions[key];

    // Add contribution data for fresh contributor  
    if (contrib.amount == 0) {
        order.contributionList.push(key);
        contrib.payer = contributor;
        contrib.chainID = chainID;
    }

    contrib.amount += _amount;
    order.currentAmount += _amount;

    uint256 sendAmount = _amount;

    // Withholding logic
    if (order.amtToWithold > 0 && order.withheldSoFar < order.amtToWithold) {
        uint256 remainingToWithhold = order.amtToWithold - order.withheldSoFar;
        if (_amount <= remainingToWithhold) {
            order.withheldSoFar += _amount;
            emit ContributionReceived(_orderID, contributor, chainID, _amount, orderVendor[_orderID]);
            return;
        }

        order.withheldSoFar = order.amtToWithold;
        sendAmount -= remainingToWithhold;
    }

    // Resolve vendor recipient
    Vendor storage v = vendors[orderVendor[_orderID]];
    address recipient = v.optionalPaymentReciever == address(0) ? v.vendorAddress : v.optionalPaymentReciever;

    // Transfer remaining amount to vendor
    require(USDCcontract.transferFrom(msg.sender, address(this), sendAmount), "USDC transfer failed to this contract");
    require(USDCcontract.transfer(recipient, sendAmount), "USDC transfer failed to vendor");

    emit ContributionReceived(_orderID, contributor, chainID, _amount, orderVendor[_orderID]);
}

    function refund(uint256 vendorID, uint256 orderID) 
        external onlyApproved activeVendor(vendorID) nonReentrant {
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

    // --- Internal Functions --- 
    function getContributionKey(address payer, uint256 chainID) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(payer, chainID));
}

    // --- Admin Functions ---
    function approveAddress(address addr) external onlyOwner {
        approvedAddresses[addr] = true;
    }

    function removeApprovedAddress(address addr) external onlyOwner {
        approvedAddresses[addr] = false;
    }


    // --- Getter Functions ---
    function getOrderDetails(uint256 vendorID, uint256 orderID)
        external view activeVendor(vendorID)
        returns (uint256 totalAmount, uint256 currentAmount, bool processed, uint256 numPayers) {
        Order storage order = vendors[vendorID].orders[orderID];
        require(order.orderID != 0, "Order does not exist");
        return (order.totalAmount, order.currentAmount, order.processed, order.numPayers);
    }

    function getContributions(uint256 vendorID, uint256 orderID)
        external view activeVendor(vendorID)
        returns (Contribution[] memory) {
        Order storage order = vendors[vendorID].orders[orderID];
        require(order.orderID != 0, "Order does not exist");
        return vendors[vendorID].orders[orderID].contributionList;
    }


    // --- Events ---
    event ContributionReceived(uint256 orderID, address payer, uint256 chainID, uint256 amount, uint256 vendor);

    event RefundProcessed(uint256 vendorID, uint256 orderID, uint256 totalRefunded);
}