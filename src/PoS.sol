// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
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

    struct OrderAuth {
    uint256 vendorId;
    string vendorOrderId;
    uint256 totalAmount;
    uint256 validUntil;
    string nonce;
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
        bool processed; // Flag to indicate if the order has been processed
        uint256 timestamp;
    }

    struct Vendor {
        string name;
        address vendorAddress;  // Admin Address
        bool isActive;
        uint256[] orderIDs; // List of order IDs associated with this vendor
        address optionalPaymentReciever; // Optional address for payment receiver - if not recived will default to vendorAddress
        uint256 withholdingAllotment; // Amount of withholding the vendor is allowed to have
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

    mapping(uint256 => mapping (address => bool)) private  vendorApprovedAddresses; // Access control for vendor approved addresses



    bytes32 private constant ORDER_TYPEHASH = keccak256(
    "OrderAuth(uint256 vendorId,string vendorOrderId,uint256 totalAmount,uint256 validUntil,string nonce)"
    );

    bytes32 private DOMAIN_SEPARATOR;


    bool approvalsNecessary = false;

    IERC20 USDCcontract;   //Address to estimate withholdings in USDC
    address public posBase; // address of CCIP POSBase


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
    constructor(address _USDCcontract) Ownable(msg.sender){
        // Initialize the contract deployer as an approved address
        approvedAddresses[msg.sender] = true;
        USDCcontract = IERC20(_USDCcontract);

        uint256 chainId;
        assembly {
            chainId := chainid()
        }

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("TgetherPOS")),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );

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
    ) external {
       require(msg.sender == vendors[vendorID].vendorAddress, "Only the vendor can approve addresses");
        vendors[vendorID].optionalPaymentReciever = addr;
    }
    // --- Order Management ---
    function createOrder(uint256 _vendorId, uint256 _amount, string memory _vendorOrderId) external activeVendor(_vendorId) approvedOrderCreators(_vendorId) requireApprovedVendor(_vendorId) returns (uint256 orderId) {
        // Create a new order
        Order storage order = orders[orderCounter];

        vendors[_vendorId].orderIDs.push(orderCounter);

        OrderVendor[orderCounter] = _vendorId; // Map the order ID to the vendor ID
        order.totalAmount = _amount; // Set the total amount for the order
        order.timestamp = block.timestamp;

        if (bytes(_vendorOrderId).length > 0) {
            vendorOrderIDtoTgether[_vendorId][_vendorOrderId] = orderCounter;
            order.vendorOrderId = _vendorOrderId; // Set the vendor-specific order ID
        }
        orderCounter++;

        // Emit an event for the order creation
        emit OrderCreated(orderCounter - 1, _vendorOrderId, _vendorId, _amount);
        return orderCounter - 1; // Return the order ID

    }


            // --- Payment Function (Including Cross-Chain Hooks) ---
    function pay(
        uint256 _orderID,
        address _payer,
        uint256 _payerChain,
        uint256 _amount,
        bytes calldata signature,
        OrderAuth calldata auth
    ) external nonReentrant{

        if (_orderID == 0) {
            require(block.timestamp <= auth.validUntil, "Signature expired");
            require(this.verifyOrderSignature(auth, signature), "Invalid vendor signature");

            uint256 existing = vendorOrderIDtoTgether[auth.vendorId][auth.vendorOrderId];

            if (existing == 0) {
                Order storage _order = orders[orderCounter];
                _order.vendorOrderId = auth.vendorOrderId;
                _order.totalAmount = auth.totalAmount;
                vendors[auth.vendorId].orderIDs.push(orderCounter);
                OrderVendor[orderCounter] = auth.vendorId;
                vendorOrderIDtoTgether[auth.vendorId][auth.vendorOrderId] = orderCounter;
                _orderID = orderCounter;
                _order.timestamp = block.timestamp;

                orderCounter++;

                emit OrderCreated(_orderID, auth.vendorOrderId, auth.vendorId, auth.totalAmount);
            } else {
                _orderID = existing;
            }
        }

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

        // Transfers
        require(USDCcontract.transferFrom(msg.sender, address(this), _amount), "USDC transfer to this contract failed");
        require(USDCcontract.transfer(recipient, _amount), "USDC transfer to vendor failed");

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

    function verifyOrderSignature(OrderAuth memory order, bytes memory signature) external view returns (bool) {
        bytes32 structHash = keccak256(abi.encode(
            ORDER_TYPEHASH,
            order.vendorId,
            keccak256(bytes(order.vendorOrderId)),
            order.totalAmount,
            order.validUntil,
            keccak256(bytes(order.nonce))
        ));

        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            DOMAIN_SEPARATOR,
            structHash
        ));
        address signer = recover(digest, signature);

        return (vendorApprovedAddresses[order.vendorId][signer] || approvedAddresses[signer]);
    }

    function recover(bytes32 digest, bytes memory signature) internal pure returns (address) {
        require(signature.length == 65, "Invalid signature length");

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }

        return ecrecover(digest, v, r, s);
    }


    // --- Admin Functions ---
    function approveAddress(address addr) external onlyOwner {
        approvedAddresses[addr] = true;
    }

    function removeApprovedAddress(address addr) external onlyOwner {
        approvedAddresses[addr] = false;
    }

    function setPOSBase(address _posBase) external onlyOwner {
        posBase = _posBase;
    }

    function setApprovalsNecessary () external onlyOwner {
        approvalsNecessary = !approvalsNecessary;
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
    event OrderCreated(uint256 indexed orderId, string indexed vendorOrderId,  uint256 indexed vendorId, uint256 amount);

    event ContributionReceived(uint256 orderID, address payer, uint256 chainID, uint256 amount, uint256 vendor);

    event RefundProcessed(uint256 vendorID, uint256 orderID, uint256 totalRefunded);
    event ContributionRefunded(uint256 orderId, address payer, uint256 chainID, uint256 amount);

    event OrderProcessed(uint256 orderID, uint256 totalAmount, uint256 currentAmount);
    event WithholdingPaid(uint256 vendorID, uint256 amount, uint256 remainingDebt);

}