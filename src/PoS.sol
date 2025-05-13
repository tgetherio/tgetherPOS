// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPOSBase {
    function sendPayment(
        address payer,
        uint256 payerChain,
        uint256 orderID,
        uint256 amount
    ) external returns (bytes32);
}


contract PoS is ReentrancyGuard, Ownable{

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
        uint256 amtToWithhold;       // Amount withhold for gas fees
        uint256 withheldSoFar;       // Flag to indicate if the amount has been withheld
        bool processed; // Flag to indicate if the order has been processed
    }

    struct Vendor {
        string name;
        address vendorAddress;  // Admin Address
        bool isActive;
        uint256[] orderIDs; // List of order IDs associated with this vendor
        address optionalPaymentReciever; // Optional address for payment receiver - if not recived will default to vendorAddress
        uint256 withHoldingAllotment; // Amount of withholding the vendor is allowed to have
        bool approved;
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
    
    mapping(uint256 => uint256) public vendorWithholdingDebt; // vendorID → unpaid withholding total

    uint256 public defaultWithholdingDebt = 10e6; // e.g. 10 USDC (adjustable by owner)


    mapping(uint256 => mapping (address => bool)) private  vendorApprovedAddresses; // Access control for vendor approved addresses

    bool approvalsNecessary = false;

    address feeAddress; // Address to receive fees for creating orders 
    AggregatorV3Interface internal CBETHtoUSD;
    IERC20 USDCcontract;   //Address to estimate withholdings in USDC
    address public posBase; // address of CCIP POSBase

    uint256 public estimatedOrderGas = 185000; // can be updated by owner
    uint256 public feeMultiplierBps = 150; // Fee on gas for managed order creation

    // --- Modifiers ---
    // restricts function access to approved addresses

    
    modifier activeVendor(uint256 vendorID) {
        require(vendors[vendorID].isActive, "Vendor is not Active");
        _;
    }

    modifier approvedOrderCreators(uint256 vendorID) {
        require(vendorApprovedAddresses[vendorID][msg.sender] || approvedAddresses[msg.sender], "Only the vendor or tg approvers can create orders");
        _;
    }

    modifier requireApprovedVendor(uint256 vendorID) {
        if (approvalsNecessary) {
            require(vendors[vendorID].approved, "Vendor is not approved");
        }
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
    function createVendor(string calldata name) external returns (uint256 vendorID) {
        Vendor storage vendor = vendors[vendorCounter];
        require(!vendor.isActive, "Vendor already exists");
        vendor.name = name;
        vendor.vendorAddress = msg.sender; // Vendor’s payout address
        vendor.isActive = true;
        vendorList.push(vendorCounter);
        vendorIndex[vendorCounter] = vendorList.length - 1;
        vendor.withHoldingAllotment = defaultWithholdingDebt; // Set default withholding allotment
        vendorCounter++;
        return vendorCounter - 1; // Return the vendor ID

    }

    function deActivateVendor(uint256 vendorID) external activeVendor(vendorID) {
        require(msg.sender == vendors[vendorID].vendorAddress, "Only the vendor can deactivate");
        uint256 _index = vendorIndex[vendorID];
        uint256 lastVendorID = vendorList[vendorList.length - 1];
        if (_index != vendorList.length - 1) {
            vendorList[_index] = lastVendorID;
            vendorIndex[lastVendorID] = _index;
        }
        vendorList.pop();
        vendors[vendorID].isActive = false;
        delete vendorIndex[vendorID];
    }

    function activateVendor(uint256 vendorID) external {
        require(!vendors[vendorID].isActive, "Vendor already exists");
        require(msg.sender == vendors[vendorID].vendorAddress, "You do not own this vendor");
        vendors[vendorID].isActive = true;
        vendorList.push(vendorID);
        vendorIndex[vendorID] = vendorList.length - 1;
    }

    function approveVendorAddress(
        uint256 vendorID,
        address addr
    ) external approvedOrderCreators(vendorID) activeVendor(vendorID) {
       require(msg.sender == vendors[vendorID].vendorAddress, "Only the vendor can approve addresses");
        vendorApprovedAddresses[vendorID][addr] = true;
    }

    function removeVendorAddress(
        uint256 vendorID,
        address addr
    ) external approvedOrderCreators(vendorID) activeVendor(vendorID) {
       require(msg.sender == vendors[vendorID].vendorAddress, "Only the vendor can approve addresses");
        vendorApprovedAddresses[vendorID][addr] = false;
    }

    function setVendorPaymentReciever(
        uint256 vendorID,
        address addr
    ) external activeVendor(vendorID) {
       require(msg.sender == vendors[vendorID].vendorAddress, "Only the vendor can approve addresses");
        vendors[vendorID].optionalPaymentReciever = addr;
    }

    function payWithholding(uint256 vendorID, uint256 amount) external nonReentrant {
        require(vendorApprovedAddresses[vendorID][msg.sender], "Can not pay withholding");
        require(vendorWithholdingDebt[vendorID] > 0, "No withholding owed");

        require(USDCcontract.transferFrom(msg.sender, feeAddress, amount), "Payment failed");

        if (amount >= vendorWithholdingDebt[vendorID]) {
            vendorWithholdingDebt[vendorID] = 0;
        } else {
            vendorWithholdingDebt[vendorID] -= amount;
        }
    }

    // --- Order Management ---
    function createOrder(uint256 _vendorId, uint256 _amount, string memory _vendorOrderId) external activeVendor(_vendorId) approvedOrderCreators(_vendorId) requireApprovedVendor(_vendorId) returns (uint256 orderId) {
        uint256 withholding;

        if (approvedAddresses[msg.sender]) {
            (
                /* uint80 roundId */,
                int256 conversion,
                /*uint256 startedAt*/,
                /*uint256 updatedAt*/,
                /*uint80 answeredInRound*/
            ) = CBETHtoUSD.latestRoundData();

            require(conversion > 0, "Invalid price feed");
            withholding = (uint256(conversion) * tx.gasprice * estimatedOrderGas * feeMultiplierBps) / (1e18 * 100);

            vendorWithholdingDebt[_vendorId] += withholding;
            require(vendorWithholdingDebt[_vendorId] <= vendors[_vendorId].withHoldingAllotment, "Unpaid withholding limit reached");

        } else if (vendorApprovedAddresses[_vendorId][msg.sender]) {
            withholding = 0;
        } else {
            revert("Not an approved address");
        }

        // Create a new order
        Order storage order = orders[orderCounter];
        order.totalAmount = _amount; // Set the total amount to 0 initially
        order.amtToWithhold = withholding; // Set the amount to withhold
        vendors[_vendorId].orderIDs.push(orderCounter);

        OrderVendor[orderCounter] = _vendorId; // Map the order ID to the vendor ID

        if (bytes(_vendorOrderId).length > 0) {
            vendorOrderIDtoTgether[_vendorId][_vendorOrderId] = orderCounter;
            order.vendorOrderId = _vendorOrderId; // Set the vendor-specific order ID
        }


        orderCounter++;


        // Emit an event for the order creation
        emit OrderCreated(orderCounter - 1, _vendorOrderId, _vendorId, _amount, withholding);

        
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

        Order storage order = orders[_orderID];

        address contributor = (_payer == address(0)) ? msg.sender : _payer;
        uint256 chainID = (_payerChain == 0) ? block.chainid : _payerChain;
        bytes32 key = getContributionKey(contributor, chainID);

        Contribution storage contrib = order.contributions[key];

        if (contrib.amount == 0) {
            order.contributionKeys.push(key);
            contrib.payer = contributor;
            contrib.chainID = chainID;
        }

        contrib.amount += _amount;
        order.currentAmount += _amount;

        // Determine recipient and vendor
        uint256 vendorID = OrderVendor[_orderID];
        Vendor storage v = vendors[vendorID];
        address recipient = v.optionalPaymentReciever == address(0) ? v.vendorAddress : v.optionalPaymentReciever;

        // Handle fees
        uint256 feeToTake = 0;
        if (order.amtToWithhold > 0 && order.withheldSoFar < order.amtToWithhold) {
            uint256 remainingToWithhold = order.amtToWithhold - order.withheldSoFar;
            feeToTake = (_amount <= remainingToWithhold) ? _amount : remainingToWithhold;
            order.withheldSoFar += feeToTake;
        }

        uint256 vendorAmount = _amount - feeToTake;

        // Transfers
        require(USDCcontract.transferFrom(msg.sender, address(this), _amount), "USDC transfer to this contract failed");
        require(USDCcontract.transfer(recipient, vendorAmount), "USDC transfer to vendor failed");

        if (feeToTake > 0) {
            require(feeAddress != address(0), "Fee address not set");
            require(USDCcontract.transfer(feeAddress, feeToTake), "USDC fee transfer failed");
            if (feeToTake >= vendorWithholdingDebt[vendorID]) {
                vendorWithholdingDebt[vendorID] = 0;
            } else {
                vendorWithholdingDebt[vendorID] -= feeToTake;
            }
        }

        if (order.currentAmount >= order.totalAmount) {
            order.processed = true;
            emit OrderProcessed(_orderID, order.totalAmount, order.currentAmount);
        }

        emit ContributionReceived(_orderID, contributor, chainID, _amount, vendorID);
    }



    function refundOrder(uint256 orderID) external approvedOrderCreators(OrderVendor[orderID]) nonReentrant {
        require(orders[orderID].totalAmount > 0, "Order does not exist");
        uint256 vendorID = OrderVendor[orderID];

        Order storage order = orders[orderID];
        require(order.refundType != RefundType.FULL, "Order already fully refunded");

        for (uint256 i = 0; i < order.contributionKeys.length; i++) {
            bytes32 key = order.contributionKeys[i];
            Contribution storage contrib = order.contributions[key];
            uint256 remaining = contrib.amount - contrib.amountRefunded;
            if (remaining > 0) {
                _refundContribution(orderID, key, remaining);
            }
        }

        order.refundType = RefundType.FULL;
        emit RefundProcessed(vendorID, orderID, order.amtRefunded);
    }

    function refundContribution(
    uint256 orderID,
    bytes32 key,
    uint256 refundAmount
    ) external approvedOrderCreators(OrderVendor[orderID]) nonReentrant {
        _refundContribution(orderID, key, refundAmount);
    }


    function _refundContribution(uint256 orderID, bytes32 key, uint256 refundAmount) internal {
        Order storage order = orders[orderID];
        Contribution storage contrib = order.contributions[key];

        require(contrib.amount > 0, "No contribution");
        require(refundAmount > 0, "Refund must be greater than 0");

        uint256 refundable = contrib.amount - contrib.amountRefunded;
        require(refundAmount <= refundable, "Refund exceeds contribution");

        contrib.amountRefunded += refundAmount;
        order.amtRefunded += refundAmount;

        if (contrib.chainID == block.chainid) {
            // Step 1: Pull refund funds from vendor (msg.sender) into contract
            require(USDCcontract.transferFrom(msg.sender, address(this), refundAmount), "Refund transfer to contract failed");

            // Step 2: Forward refund to payer
            require(USDCcontract.transfer(contrib.payer, refundAmount), "Refund transfer to payer failed");

        } else {
            require(USDCcontract.transferFrom(msg.sender, address(this), refundAmount), "Refund transfer failed");
            USDCcontract.approve(address(posBase), refundAmount);
            IPOSBase(posBase).sendPayment(contrib.payer, contrib.chainID, orderID, refundAmount);
        }

        emit ContributionRefunded(orderID, contrib.payer, contrib.chainID, refundAmount);

        if (order.refundType == RefundType.NONE) {
            order.refundType = RefundType.PARTIAL;
        }
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
    function setFeeAddress(address _feeAddress) external onlyOwner {
    require(_feeAddress != address(0), "Cannot set zero address");
    feeAddress = _feeAddress;
    }


    function setPOSBase(address _posBase) external onlyOwner {
        posBase = _posBase;
    }


    function setFeeAndGas(uint256 _feeMultiplierBps, uint256 _estimatedOrderGas) external onlyOwner {
        require(_feeMultiplierBps >= 100, "Multiplier must be >= 100");
        require(_estimatedOrderGas > 0, "Gas estimate must be > 0");
        feeMultiplierBps = _feeMultiplierBps;
        estimatedOrderGas = _estimatedOrderGas;
    }

    function setFeeMultiplier(uint256 _bps) external onlyOwner {
        require(_bps >= 100, "Must be >= 1x");
        feeMultiplierBps = _bps;
    }

    function setEstimatedOrderGas(uint256 gas) external onlyOwner {
        require(gas > 0, "Invalid gas amount");
        estimatedOrderGas = gas;
    }
    function setApprovalsNecessary () external onlyOwner {
        approvalsNecessary = !approvalsNecessary;
    }



    function setVendorWithholdingAllotment(uint256 vendorID, uint256 allotment) external onlyOwner {
        vendors[vendorID].withHoldingAllotment = allotment;
    }

    function setDefaultWithholdingDebt(uint256 amount) external onlyOwner {
        defaultWithholdingDebt = amount;
    }



    // --- Getter Functions ---
    function getOrderDetails(uint256 orderId)
        external view
        returns (uint256 totalAmount, uint256 currentAmount, bool processed, uint256 numPayers) {
        Order storage order = orders[orderId];
        require(orders[orderId].totalAmount != 0, "Order does not exist");
        return (order.totalAmount, order.currentAmount, order.processed, order.contributionKeys.length);
    }

    function getContributions(uint256 orderId) external view returns (Contribution[] memory) {
        Order storage order = orders[orderId];
        require(order.totalAmount != 0, "Order does not exist");

        Contribution[] memory result = new Contribution[](order.contributionKeys.length);
        for (uint256 i = 0; i < order.contributionKeys.length; i++) {
            result[i] = order.contributions[order.contributionKeys[i]];
        }

        return result;
    }

    function isVendorApproved(uint256 vendorID, address user) external view returns (bool) {
    return vendorApprovedAddresses[vendorID][user];
        }
    
        function getPaginatedOrders(uint256 start, uint256 count) external view returns (uint256[] memory) {
        uint256[] memory results = new uint256[](count);
        uint256 end = start + count;
        require(end <= orderCounter, "Out of range");

        for (uint256 i = 0; i < count; i++) {
            results[i] = start + i;
        }

        return results;
    }

    function getPaginatedVendorOrders(uint256 vendorID, uint256 start, uint256 count) external view returns (uint256[] memory) {
        uint256[] storage allOrders = vendors[vendorID].orderIDs;
        require(start + count <= allOrders.length, "Out of range");

        uint256[] memory results = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            results[i] = allOrders[start + i];
        }

        return results;
    }



    // --- Events ---
    event OrderCreated(uint256 indexed orderId, string indexed vendorOrderId,  uint256 indexed vendorId, uint256 amount, uint256 withholding);

    event ContributionReceived(uint256 orderID, address payer, uint256 chainID, uint256 amount, uint256 vendor);

    event RefundProcessed(uint256 vendorID, uint256 orderID, uint256 totalRefunded);
    event ContributionRefunded(uint256 orderId, address payer, uint256 chainID, uint256 amount);

    event OrderProcessed(uint256 orderID, uint256 totalAmount, uint256 currentAmount);
}