// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPaymentHandler {
    function pay(
        string calldata vendorID,
        string calldata orderID,
        address payAs,
        uint256 payAsChain
    ) external payable;
}

contract POSBase is CCIPReceiver, OwnerIsCreator {
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
        string vendorID,
        string orderID,
        address payAs,
        uint256 payAsChain,
        address token,
        uint256 amount
    );

    IERC20 public immutable usdcToken;
    mapping(uint64 => bool) public allowlistedDestinationChains;

    constructor(address _router, address _usdc) CCIPReceiver(_router) {
        usdcToken = IERC20(_usdc);
    }

    modifier onlyAllowlistedDestinationChain(uint64 _destinationChainSelector) {
        if (!allowlistedDestinationChains[_destinationChainSelector])
            revert DestinationChainNotAllowlisted(_destinationChainSelector);
        _;
    }

    function allowlistDestinationChain(uint64 _selector, bool allowed) external onlyOwner {
        allowlistedDestinationChains[_selector] = allowed;
    }

    function sendPayment(
        uint64 destinationChainSelector,
        address payAs,
        uint256 payAsChain,
        uint256 amount
    )
        external
        onlyOwner
        onlyAllowlistedDestinationChain(destinationChainSelector)
        returns (bytes32 messageId)
    {
        require(payAs != address(0), "Invalid payAs address");

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(usdcToken), amount: amount});

        bytes memory data = abi.encode(payAs, payAsChain);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(payAs),
            data: data,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({gasLimit: 400_000, allowOutOfOrderExecution: true})
            ),
            feeToken: address(0) // native gas
        });

        IRouterClient router = IRouterClient(getRouter());
        uint256 fees = router.getFee(destinationChainSelector, message);
        if (fees > address(this).balance) revert NotEnoughBalance(address(this).balance, fees);

        usdcToken.approve(address(router), amount);

        messageId = router.ccipSend{value: fees}(destinationChainSelector, message);

        emit PaymentSent(messageId, destinationChainSelector, payAs, payAsChain, address(usdcToken), amount, fees);
        return messageId;
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        (string memory vendorID, string memory orderID, address payAs, uint256 payAsChain) = abi.decode(
            message.data,
            (string, string, address, uint256)
        );

        require(message.destTokenAmounts.length == 1, "Invalid token amount");
        require(message.destTokenAmounts[0].token == address(usdcToken), "Only USDC allowed");

        uint256 amount = message.destTokenAmounts[0].amount;

        usdcToken.approve(address(this), amount);
        IPaymentHandler(address(this)).pay{value: 0}(vendorID, orderID, payAs, payAsChain);

        emit PaymentReceived(vendorID, orderID, payAs, payAsChain, address(usdcToken), amount);
    }

    receive() external payable {}

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
