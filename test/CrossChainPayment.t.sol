// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {
    CCIPLocalSimulator, IRouterClient, BurnMintERC677Helper
} from "lib/chainlink-local/src/ccip/CCIPLocalSimulator.sol";
import {POSBase} from "src/POSBase.sol"; 
import {POSMember} from "src/POSMember.sol"; 
import {MOCKERC20POS} from "src/MOCKERC20POS.sol";
import {WETH9} from "lib/chainlink-local/src/shared/WETH9.sol";
import {LinkToken} from "lib/chainlink-local/src/shared/LinkToken.sol";
import {console} from "lib/forge-std/src/Test.sol";
// Test suite for POSBase and POSMember using Chainlink's CCIP Local Simulator
contract CrossChainPayment is Test {
    CCIPLocalSimulator public ccipLocalSimulator;
    POSBase public base;
    POSMember public member;
    MOCKERC20POS public mockPay;

    uint64 public destinationChainSelector;
    BurnMintERC677Helper public ccipUSDCToken;

    /**
     * @notice Sets up the test environment by initializing the CCIP simulator and deploying contracts.
     */
    function setUp() public {
        ccipLocalSimulator = new CCIPLocalSimulator();

        // Retrieve configuration from the simulator
        (uint64 chainSelector, IRouterClient sourceRouter, IRouterClient destinationRouter_, , ,
            BurnMintERC677Helper ccipUSDC,) = ccipLocalSimulator.configuration();

        destinationChainSelector = chainSelector;

        ccipUSDCToken= ccipUSDC;

        // Deploy mock payment token
        mockPay = new MOCKERC20POS(address(ccipUSDCToken), chainSelector);

        // Deploy base and member contracts
        base = new POSBase(address(destinationRouter_), address(ccipUSDCToken), address(mockPay));
        member = new POSMember(address(sourceRouter), address(ccipUSDCToken), chainSelector, address(base));

        base.setApprovedChain(block.chainid, address(member), destinationChainSelector);
        mockPay.setCrossChainSender(address(base));
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
        bytes32 messageId = member.sendPayment(orderID, amount);

        // Expect payment to be received by POSBase
        uint256 mockContractBalance = ccipUSDCToken.balanceOf(address(mockPay));
        assertEq(mockContractBalance, amount, "Mock contract should have received 1 USDC");

    }

    /**
     * @notice Tests receiving a cross-chain refund.
     */
    function testReceiveRefund() public {
        mintAndFund();
        uint256 orderID = 1;
        uint256 amount = 1;

        testSendPayment();

        // Perform refund
        mockPay.refund(orderID, false);

        // Expect refund to be issued to the payer
        emit POSMember.RefundReceived(address(this), amount, orderID);
    }
}
