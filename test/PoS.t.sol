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
    MockOracle public mockOracle;

    function setUp() public {
        mockUSDC = new MockUSDC();
        mockOracle = new MockOracle();
        pos = new PoS(address(mockOracle), address(mockUSDC));
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
        vm.prank(user1); pos.pay(orderId, address(0), 0, 100e6);
        vm.prank(user2); pos.pay(orderId, address(0), 0, 100e6);
        vm.prank(user3); pos.pay(orderId, address(0), 0, 100e6);

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
        vm.prank(user1); pos.pay(orderId, address(0), 0, 100e6);
        vm.prank(user2); pos.pay(orderId, address(0), 0, 100e6);
        vm.prank(user3); pos.pay(orderId, address(0), 0, 100e6);

        // Perform refund via a separate contract
        mockUSDC.approve(address(pos), 300e6);
        pos.refundOrder(orderId);

        // // Validate refunds
        PoS.Contribution[] memory contribs = pos.getContributions(orderId);
        for (uint i = 0; i < contribs.length; i++) {
            assertEq(contribs[i].amount, contribs[i].amountRefunded);
        }
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

contract MockOracle is AggregatorV3Interface {
    function latestRoundData() external pure override returns (
        uint80, int256 answer, uint256, uint256, uint80
    ) {
        return (0, 2_000e8, 0, 0, 0); // 1 ETH = $2000
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function description() external pure override returns (string memory) {
        return "Mock Oracle";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external pure override returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        revert("not implemented");
    }
}
