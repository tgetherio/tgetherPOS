// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Import necessary interfaces and libraries from Chainlink CCIP and OpenZeppelin
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Interface for the external payment handler contract that handles final payment processing.
interface IPaymentHandler {
    function pay(
        uint256 orderID,
        address payAs,
        uint256 payAsChain,
        uint256 amount
    ) external;
}

// Main Point of Sale (POS) contract for handling cross-chain payments via Chainlink CCIP.
contract POSBase is CCIPReceiver, OwnerIsCreator, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Custom errors for gas-efficient error handling
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error DestinationChainNotAllowlisted(uint64 destinationChainSelector);
    error InvalidReceiverAddress();

    // Event emitted when a payment is sent via CCIP
    event PaymentSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address indexed payAs,
        uint256 payAsChain,
        address token,
        uint256 amount,
        uint256 fees
    );

    // Event emitted when a payment is received from another chain
    event PaymentReceived(
        uint256 orderID,
        address payAs,
        uint256 payAsChain,
        address token,
        uint256 amount
    );

    // Immutable USDC token contract address
    IERC20 public immutable usdcToken;

    // Mapping for approved chain receivers and their chain selectors
    mapping(uint256 => address) public approvedChainRecievers;
    mapping(uint256 => uint64) public approvedChainSelectors;

    // Payment handler contract to finalize payments
    IPaymentHandler public paymentHandler;

    // Router client for CCIP interactions
    IRouterClient router;

    // Constructor initializes contract with router, USDC token, and payment handler contract
    constructor(address _router, address _usdc, address _posContract) CCIPReceiver(_router) {
        usdcToken = IERC20(_usdc);
        paymentHandler = IPaymentHandler(_posContract);
        rotuer = IRouterClient(getRouter()); // Note: Typo in 'router' -> 'rotuer'
    }

    // Modifier to ensure only the payment handler contract can call specific functions
    modifier OnlyPoS() {
        require(msg.sender == address(paymentHandler), "Only PoS contract can call this function");
        _;
    }

    /**
     * @notice Sends a cross-chain payment using Chainlink CCIP.
     * @dev Payment is processed using native gas fees. Data is encoded and sent via CCIP.
     * @param payer Address of the user making the payment.
     * @param payerChain Chain ID of the payer's originating chain.
     * @param orderID Unique order identifier for tracking purposes.
     * @param amount Amount of USDC to be sent.
     * @return messageId ID of the CCIP message sent.
     */
    function sendPayment(
        address payer,
        uint256 payerChain,
        uint256 orderID,
        uint256 amount
    ) external OnlyPoS nonReentrant returns (bytes32 messageId) {
        require(approvedChainRecievers[payerChain] != address(0), "Chain Not Supported");

        // Create token amounts for the CCIP message
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);

        // Transfer USDC from the sender to the contract
        SafeERC20.safeTransferFrom(usdcToken, msg.sender, address(this), amount);

        tokenAmounts[0] = Client.EVMTokenAmount({token: address(usdcToken), amount: amount});

        // Encode payment data including payer and order details
        bytes memory data = abi.encode(payer, orderID);

        // Build the CCIP message with encoded data and token information
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(approvedChainRecievers[payerChain]),
            data: data,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({gasLimit: 400_000, allowOutOfOrderExecution: true})
            ),
            feeToken: address(0) // Native gas fees
        });

        // Calculate the required fees for the CCIP message
        uint256 fees = router.getFee(approvedChainSelectors[payerChain], message);
        if (fees > address(this).balance) revert NotEnoughBalance(address(this).balance, fees);

        // Approve the router to spend the necessary USDC amount
        usdcToken.safeIncreaseAllowance(address(router), amount);

        // Send the CCIP message and store the messageId
        messageId = router.ccipSend{value: fees}(approvedChainSelectors[payerChain], message);

        emit PaymentSent(messageId, approvedChainSelectors[payerChain], payer, payerChain, address(usdcToken), amount, fees);
        return messageId;
    }

    /**
     * @notice Handles the receipt of cross-chain payments via CCIP.
     * @dev Payment data is decoded, and the appropriate payment handler function is called.
     * @param message The received CCIP message containing payment details.
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override nonReentrant {
        (address payAs, uint256 payAsChain, uint256 orderID, uint256 amount) = abi.decode(
            message.data,
            (uint256, address, uint256, uint256)
        );

        require(message.destTokenAmounts.length == 1, "Invalid token amount");
        require(message.destTokenAmounts[0].token == address(usdcToken), "Only USDC allowed");

        uint256 amount = message.destTokenAmounts[0].amount;

        // Approve the payment handler to spend the USDC
        usdcToken.safeIncreaseAllowance(address(paymentHandler), amount);
        paymentHandler.pay(orderID, payAs, payAsChain, amount);

        emit PaymentReceived(orderID, payAs, payAsChain, address(usdcToken), amount);
    }

    // Allows the contract owner to set approved chain receivers and chain selectors
    function setApprovedChain(uint256 chainID, address receiver, uint64 chainSelector) external onlyOwner {
        approvedChainRecievers[chainID] = receiver;
        approvedChainSelectors[chainID] = chainSelector;
    }

    // Allows the owner to withdraw ETH from the contract
    function withdrawETH(address beneficiary) external onlyOwner {
        (bool success, ) = beneficiary.call{value: address(this).balance}("");
        require(success, "ETH Withdraw failed");
    }

    // Allows the owner to withdraw USDC from the contract
    function withdrawUSDC(address beneficiary) external onlyOwner {
        uint256 balance = usdcToken.balanceOf(address(this));
        require(balance > 0, "No USDC to withdraw");
        usdcToken.safeTransfer(beneficiary, balance);
    }
}
