// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/PoS.sol"; // Adjust path if needed

contract RefundCaller {
    function callRefund(PoS pos, uint256 orderId) external {
        pos.refundOrder(orderId);
    }
}


contract PoSTest is Test {
    PoS public pos;

    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public user3 = address(0x3);

    MockUSDC public mockUSDC;
    bytes  emptySig = "";
    PoS.OrderAuth  emptyAuth = PoS.OrderAuth(0, "", 0, 0, "");

    function setUp() public {
        mockUSDC = new MockUSDC();
        pos = new PoS(address(mockUSDC));
    }

    function testCreateAndPayOrder() public {
        // Mint and approve tokens for users
        mockUSDC.mint(user1, 1_000e6);
        mockUSDC.mint(user2, 1_000e6);
        mockUSDC.mint(user3, 1_000e6);

        vm.prank(user1);
        mockUSDC.approve(address(pos), type(uint256).max);
        vm.prank(user2);
        mockUSDC.approve(address(pos), type(uint256).max);
        vm.prank(user3);
        mockUSDC.approve(address(pos), type(uint256).max);

        // Create vendor and order
        pos.approveAddress(address(this));
        pos.createVendor("TestVendor");
        uint256 orderId = pos.createOrder(1, 300e6, "ORDER_X");

        // Pay order
        vm.prank(user1); pos.pay(orderId, address(0), 0, 100e6, emptySig, emptyAuth);
        vm.prank(user2); pos.pay(orderId, address(0), 0, 100e6,  emptySig, emptyAuth);
        vm.prank(user3); pos.pay(orderId, address(0), 0, 100e6,  emptySig, emptyAuth);

        // Assert final state
        (uint256 total, uint256 collected, bool processed, uint256 numPayers) = pos.getOrderDetails(orderId);
        assertEq(total, 300e6);
        assertEq(collected, 300e6);
        assertTrue(processed);
        assertEq(numPayers, 3);
    }

    function testRefundOnly() public {
        // Mint and approve tokens for users
        mockUSDC.mint(user1, 1_000e6);
        mockUSDC.mint(user2, 1_000e6);
        mockUSDC.mint(user3, 1_000e6);

        vm.prank(user1);
        mockUSDC.approve(address(pos), type(uint256).max);
        vm.prank(user2);
        mockUSDC.approve(address(pos), type(uint256).max);
        vm.prank(user3);
        mockUSDC.approve(address(pos), type(uint256).max);

        // Set up PoS
        pos.createVendor("TestVendor");
        // Create and pay an order
        uint256 orderId = pos.createOrder(1, 300e6, "ORDER_X");
        vm.prank(user1); pos.pay(orderId, address(0), 0, 100e6,  emptySig, emptyAuth );
        vm.prank(user2); pos.pay(orderId, address(0), 0, 100e6,  emptySig, emptyAuth);
        vm.prank(user3); pos.pay(orderId, address(0), 0, 100e6,  emptySig, emptyAuth );

        // Perform refund via a separate contract
        mockUSDC.approve(address(pos), 300e6);
        pos.refundOrder(orderId);

        // // Validate refunds
        PoS.Contribution[] memory contribs = pos.getContributions(orderId);
        for (uint i = 0; i < contribs.length; i++) {
            assertEq(contribs[i].amount, contribs[i].amountRefunded);
        }
    }

    function testPayWithSignatureCreatesOrder() public {
        pos.approveAddress(address(this));
        uint256 vendorId = pos.createVendor("SignedVendor");

        uint256 validUntil = block.timestamp + 1 days;

        PoS.OrderAuth memory auth = PoS.OrderAuth({
            vendorId: vendorId,
            vendorOrderId: "SIGNED_ORDER",
            totalAmount: 150e6,
            validUntil: validUntil,
            nonce: "unique-nonce"
        });

        bytes32 domainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("TgetherPOS")),
            keccak256(bytes("1")),
            block.chainid,
            address(pos)
        ));

        bytes32 structHash = keccak256(abi.encode(
            keccak256("OrderAuth(uint256 vendorId,string vendorOrderId,uint256 totalAmount,uint256 validUntil,string nonce)"),
            vendorId,
            keccak256(bytes("SIGNED_ORDER")),
            150e6,
            validUntil,
            keccak256(bytes("unique-nonce"))
        ));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        uint256 privateKey = 0xA11CE;

        pos.approveVendorAddress(vendorId, vm.addr(privateKey));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        mockUSDC.mint(user1, 1_000e6);
        vm.prank(user1);
        mockUSDC.approve(address(pos), type(uint256).max);

        vm.prank(user1);
        pos.pay(0, address(0), 0, 150e6, signature, auth);

        uint256 newOrderId = pos.vendorOrderIDtoTgether(vendorId, "SIGNED_ORDER");
        (uint256 total, uint256 collected, bool processed, uint256 numPayers) = pos.getOrderDetails(newOrderId);

        assertEq(total, 150e6);
        assertEq(collected, 150e6);
        assertTrue(processed);
        assertEq(numPayers, 1);
    }
}

// --- Mock Contracts ---

contract MockUSDC is IERC20 {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    function mint(address to, uint256 amount) public {
        balances[to] += amount;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(balances[from] >= amount, "Insufficient balance");
        require(allowances[from][msg.sender] >= amount, "Insufficient allowance");
        allowances[from][msg.sender] -= amount;
        balances[from] -= amount;
        balances[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return balances[account];
    }

    function totalSupply() external pure override returns (uint256) {
        return 0;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return allowances[owner][spender];
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }
}