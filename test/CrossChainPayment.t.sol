// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {
    CCIPLocalSimulator, IRouterClient, BurnMintERC677Helper
} from "lib/chainlink-local/src/ccip/CCIPLocalSimulator.sol";
import {POSBase} from "src/POSBase.sol"; 
import {POSMember} from "src/POSMember.sol"; 
import "../src/PoS.sol"; // Adjust path if needed
import {WETH9} from "lib/chainlink-local/src/shared/WETH9.sol";
import {LinkToken} from "lib/chainlink-local/src/shared/LinkToken.sol";
import {console} from "lib/forge-std/src/Test.sol";
// Test suite for POSBase and POSMember using Chainlink's CCIP Local Simulator
contract CrossChainPayment is Test {
    CCIPLocalSimulator public ccipLocalSimulator;
    POSBase public base;
    POSMember public member;

    PoS public pos;

    uint64 public destinationChainSelector;
    BurnMintERC677Helper public ccipUSDCToken;

    bytes emptySig = "";
    POSMember.OrderAuth  emptyAuth = POSMember.OrderAuth(0, "", 0, 0, "");
    address recieveAddress = address(0x1);

    /**
     * @notice Sets up the test environment by initializing the CCIP simulator and deploying contracts.
     */
    function setUp() public {
        ccipLocalSimulator = new CCIPLocalSimulator();

        // Retrieve configuration from the simulator
        (uint64 chainSelector, IRouterClient sourceRouter, IRouterClient destinationRouter_, , ,
            BurnMintERC677Helper ccipUSDC,) = ccipLocalSimulator.configuration();

        pos = new PoS(address(ccipUSDC));
        
        pos.approveAddress(address(this)); 
        pos.createVendor("TestVendor");
        pos.setVendorPaymentReciever(1, recieveAddress);
        pos.approveVendorAddress(1, recieveAddress);
        uint256 orderId = pos.createOrder(1, 300e6, "ORDER_X");

        destinationChainSelector = chainSelector;

        ccipUSDCToken= ccipUSDC;

        // Deploy base and member contracts
        base = new POSBase(address(destinationRouter_), address(ccipUSDCToken), address(pos));
        member = new POSMember(address(sourceRouter), address(ccipUSDCToken), chainSelector, address(base));

        base.setApprovedChain(block.chainid, address(member), destinationChainSelector);
        pos.setPOSBase(address(base));
    }

    /**
     * @notice Mints USDC for testing and funds the member contract with native tokens.
     * Provides sufficient USDC for cross-chain payments.
     */
    function mintAndFund() public {
        // Mint USDC for testing purposes
        ccipUSDCToken.drip(address(this));
        
        // ccipUSDCTokenM.drip(address(member));

        // Provide native gas tokens for fee payment
        vm.deal(address(member), 10 ether);
    }

    /**
     * @notice Tests the cross-chain payment from POSMember to POSBase.
     */
    function testSendPayment() public {
        mintAndFund();

        // Approve USDC transfer to member contract
        ccipUSDCToken.approve(address(member), 1);

        // Perform cross-chain payment
        uint256 orderID = 1;
        uint256 amount = 1;
        member.sendPayment(orderID, amount, emptySig, emptyAuth);

        // Expect payment to be received by POSBase
        uint256 recieveAddressBalance = ccipUSDCToken.balanceOf(recieveAddress);
        assertEq(recieveAddressBalance, amount, "Recieve Address should have received 1 USDC");

    }

    /**
     * @notice Tests receiving a cross-chain refund.
     */
    function testReceiveRefund() public {
        uint256 orderID = 1;
        uint256 amount = 1;

        testSendPayment();

        // Perform refund
        vm.prank(recieveAddress);
        ccipUSDCToken.approve(address(pos), amount);
        vm.prank(recieveAddress);
        pos.refundOrder(orderID);

        uint256 thisBal = ccipUSDCToken.balanceOf(address(this));
        uint256 recieveAddressBalance = ccipUSDCToken.balanceOf(recieveAddress);
        assertEq(thisBal, 1e18, "This Contract should have received 1 USDC");
        assertEq(recieveAddressBalance, 0, "Recieve Address should have received 1 USDC");


        // Expect refund to be issued to the payer
        emit POSMember.RefundReceived(address(this), amount, orderID);
    }


    function testSendPaymentWithOrderAuth() public {
        mintAndFund();

        // Approve USDC transfer to member contract
        uint256 vendorId = pos.createVendor("SignedVendor");

        uint256 validUntil = block.timestamp + 1 days;

        POSMember.OrderAuth memory auth = POSMember.OrderAuth({
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
        pos.setVendorPaymentReciever(2, recieveAddress);

        pos.approveVendorAddress(2, vm.addr(privateKey));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);


        ccipUSDCToken.approve(address(member), 150000000);

        // Perform cross-chain payment
        uint256 orderID = 0;
        uint256 amount = 150000000;
        member.sendPayment(orderID, amount, signature, auth);

        // Expect payment to be received by POSBase
        uint256 recieveAddressBalance = ccipUSDCToken.balanceOf(recieveAddress);
        assertEq(recieveAddressBalance, 150e6, "Recieve Address should have received 1 USDC");

    }




}
