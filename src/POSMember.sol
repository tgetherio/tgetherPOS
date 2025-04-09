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

contract POSMember is CCIPReceiver, OwnerIsCreator, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Custom errors for gas-efficient error handling
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error DestinationChainNotAllowlisted(uint64 destinationChainSelector);
    error InvalidReceiverAddress();

    // Event emitted when a payment is sent cross-chain
    event PaymentSent(
        bytes32 indexed messageId,
        address indexed payAs,
        uint256 payAsChain,
        address token,
        uint256 amount,
        uint256 orderID,
        uint256 fees
    );

    // Event emitted when a refund is received and processed
    event RefundReceived(
        address indexed payer,
        uint256 amount,
        uint256 indexed orderID
    );

    // Immutable USDC token address
    IERC20 public immutable usdcToken;

    // Chainlink CCIP variables
    uint64 public baseChainSelector; // Selector for the base chain
    address public baseReceiverContract; // Contract address on the base chain
    IRouterClient router;

    // Track payments associated with orderIDs and payers
    mapping(uint256 => mapping(address => uint256)) public orderIDToAmount;

    /**
     * @dev Initializes the contract with router, USDC token, base chain selector, and base receiver contract.
     * @param _router The Chainlink CCIP router address.
     * @param _usdc The USDC token contract address.
     * @param _baseChainSelector The chain selector for the base chain.
     * @param _baseReciever The contract address on the base chain that will receive the payments.
     */
    constructor(address _router, address _usdc, uint64 _baseChainSelector, address _baseReciever) CCIPReceiver(_router) {
        usdcToken = IERC20(_usdc);
        baseChainSelector = _baseChainSelector;
        baseReceiverContract = _baseReciever;
        router = IRouterClient(getRouter()); // Note: Typo 'rotuer' should be 'router'
    }

    /**
     * @notice Sends a cross-chain payment using Chainlink CCIP.
     * @dev This function transfers USDC to the contract, encodes the payment data, and sends the payment to the base chain.
     * @param orderID The unique identifier for the order.
     * @param amount The amount of USDC to be sent.
     * @return messageId The unique identifier of the sent CCIP message.
     */
    function sendPayment(
        uint256 orderID,
        uint256 amount
    ) external nonReentrant returns (bytes32 messageId) {
        Client.EVMTokenAmount ;

        // Transfer USDC from sender to contract
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);

        SafeERC20.safeTransferFrom(usdcToken, msg.sender, address(this), amount);

        tokenAmounts[0] = Client.EVMTokenAmount({token: address(usdcToken), amount: amount});

        // Track the payment for potential refunds
        orderIDToAmount[orderID][msg.sender] += amount;

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(baseReceiverContract), // ABI-encoded receiver address
            data: abi.encode(msg.sender, block.chainid, orderID, amount), // ABI-encoded string message
            tokenAmounts: tokenAmounts, // Tokens amounts
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({
                    gasLimit: 200_000
                })
            ),
            feeToken: address(0) // Setting feeToken to zero address, indicating native asset will be used for fees
        });

        // Get the fee for the transaction
        uint256 fees = router.getFee(baseChainSelector, message);
        if (fees > address(this).balance) revert NotEnoughBalance(address(this).balance, fees);

        // Approve router to spend USDC for the message
        usdcToken.approve(address(router), amount);

        // Send the message using CCIP
        messageId = router.ccipSend{value: fees}(baseChainSelector, message);
        emit PaymentSent(messageId, msg.sender, block.chainid, address(usdcToken), amount, orderID, fees);
        return messageId;
    }

    /**
     * @notice Handles the receipt of cross-chain refund messages.
     * @dev Ensures the refund matches the original payment and processes it by transferring USDC to the payer.
     * @param message The received CCIP message containing refund data.
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override nonReentrant {
        (address payer, uint256 orderID) = abi.decode(
            message.data,
            (address, uint256)
        );

        require(message.destTokenAmounts.length == 1, "Invalid token amount");
        require(message.destTokenAmounts[0].token == address(usdcToken), "Only USDC allowed");
        uint256 amount = message.destTokenAmounts[0].amount;
        
        require(orderIDToAmount[orderID][msg.sender] >= amount, "Payment was never processed through this contract");

        // Deduct the refunded amount from tracking
        orderIDToAmount[orderID][msg.sender] -= amount;

        // Transfer the refund to the payer
        usdcToken.transfer(payer, amount);

        emit RefundReceived(payer, amount, orderID);
    }

    /**
     * @notice Allows the owner to withdraw ETH from the contract.
     * @param beneficiary The address to receive the withdrawn ETH.
     */
    function withdrawETH(address beneficiary) external onlyOwner {
        (bool success, ) = beneficiary.call{value: address(this).balance}("");
        require(success, "ETH Withdraw failed");
    }

    /**
     * @notice Allows the owner to withdraw USDC from the contract.
     * @param beneficiary The address to receive the withdrawn USDC.
     */
    function withdrawUSDC(address beneficiary) external onlyOwner {
        uint256 balance = usdcToken.balanceOf(address(this));
        require(balance > 0, "No USDC to withdraw");
        usdcToken.safeTransfer(beneficiary, balance);
    }
}
