// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
interface IPaymentHandler {
    function pay(
        uint256 orderID,
        address payAs,
        uint256 payAsChain,
        uint256 amount
    ) external;
}

contract POSBase is CCIPReceiver, OwnerIsCreator,ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error DestinationChainNotAllowlisted(uint64 destinationChainSelector);
    error InvalidReceiverAddress();

    event PaymentSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address indexed payAs,
        uint256 payAsChain,
        address token,
        uint256 amount,
        uint256 fees
    );

    event PaymentReceived(
        uint256 orderID,
        address payAs,
        uint256 payAsChain,
        address token,
        uint256 amount
    );

    IERC20 public immutable usdcToken;
    mapping(uint256 => address) public approvedChainRecievers;
    mapping(uint256 => uint64) public approvedChainSelectors;

    IPaymentHandler public paymentHandler;
    IRouterClient router;

    constructor(address _router, address _usdc, address _posContract) CCIPReceiver(_router) {
        usdcToken = IERC20(_usdc);
        paymentHandler = IPaymentHandler(_posContract);
        rotuer = IRouterClient(getRouter());
    }

    modifier OnlyPoS() {
        require(msg.sender == address(paymentHandler), "Only PoS contract can call this function");
        _;
    }


    function sendPayment(
        address payer,
        uint256 payerChain,
        uint256 orderID,
        uint256 amount
    ) external OnlyPoS nonReentrant
        returns (bytes32 messageId)
    {
        require(approvedChainRecievers[payerChain] != address(0), "Chain Not Supported");

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);

        SafeERC20.safeTransferFrom(usdcToken, msg.sender, address(this), amount);

        tokenAmounts[0] = Client.EVMTokenAmount({token: address(usdcToken), amount: amount});

        bytes memory data = abi.encode(payer, orderID);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(approvedChainRecievers[payerChain]),
            data: data,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({gasLimit: 400_000, allowOutOfOrderExecution: true})
            ),
            feeToken: address(0) // native gas
        });

        
        uint256 fees = router.getFee(approvedChainSelectors[payerChain], message);
        if (fees > address(this).balance) revert NotEnoughBalance(address(this).balance, fees);

        usdcToken.safeIncreaseAllowance(address(router), amount);

        messageId = router.ccipSend{value: fees}(approvedChainSelectors[payerChain], message);

        emit PaymentSent(messageId, approvedChainSelectors[payerChain], payer, payerChain, address(usdcToken), amount, fees);
        return messageId;
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override nonReentrant {
        (  address payAs, uint256 payAsChain, uint256 orderID, uint256 amount) = abi.decode(
            message.data,
            (uint256, address, uint256, uint256)
        );
        require(message.destTokenAmounts.length == 1, "Invalid token amount");
        require(message.destTokenAmounts[0].token == address(usdcToken), "Only USDC allowed");

        uint256 amount = message.destTokenAmounts[0].amount;

        usdcToken.safeIncreaseAllowance(address(paymentHandler), amount);
        paymentHandler.pay( orderID, payAs, payAsChain, amount);

        emit PaymentReceived( orderID, payAs, payAsChain,address(usdcToken), amount);
    }

    function setApprovedChain(uint256 chainID, address receiver, uint64 chainSelector) external onlyOwner {
        approvedChainRecievers[chainID] = receiver;
        approvedChainSelectors[chainID] = chainSelector;
    }


    function withdrawETH(address beneficiary) external onlyOwner {
        (bool success, ) = beneficiary.call{value: address(this).balance}("");
        require(success, "ETH Withdraw failed");
    }

    function withdrawUSDC(address beneficiary) external onlyOwner {
        uint256 balance = usdcToken.balanceOf(address(this));
        require(balance > 0, "No USDC to withdraw");
        usdcToken.safeTransfer(beneficiary, balance);
    }
}
