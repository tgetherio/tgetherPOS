// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract POSMember is CCIPReceiver, OwnerIsCreator, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error DestinationChainNotAllowlisted(uint64 destinationChainSelector);
    error InvalidReceiverAddress();

    event PaymentSent(
        bytes32 indexed messageId,
        address indexed payAs,
        uint256 payAsChain,
        address token,
        uint256 amount,
        uint256 orderID,
        uint256 fees
    );

    event RefundReceived(
        address indexed payer,
        uint256 amount,
        uint256 indexed orderID
    );
    IERC20 public immutable usdcToken;

    uint64 public baseChainSelector;
    address public baseReceiverContract;
    IRouterClient router;

    mapping(uint256=> mapping(address=> uint256)) public orderIDToAmount;



    constructor(address _router, address _usdc, uint64 _baseChainSelector, address _baseReciever) CCIPReceiver(_router) {
        usdcToken = IERC20(_usdc);
        baseChainSelector= _baseChainSelector;
        baseReceiverContract = _baseReciever;
        rotuer = IRouterClient(getRouter());
    }
    }



    function sendPayment(
        uint256 orderID,
        uint256 amount
    ) external nonReentrant
        returns (bytes32 messageId)
    {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);

        SafeERC20.safeTransferFrom(usdcToken, msg.sender, address(this), amount);

        tokenAmounts[0] = Client.EVMTokenAmount({token: address(usdcToken), amount: amount});

        bytes memory data = abi.encode(msg.sender, block.chainid, orderID, amount);

        orderIDToAmount[orderID][msg.sender] += amount;

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(baseReceiverContract),
            data: data,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({gasLimit: 400_000, allowOutOfOrderExecution: true})
            ),
            feeToken: address(0) // native gas
        });

        uint256 fees = router.getFee(baseChainSelector, message);
        if (fees > address(this).balance) revert NotEnoughBalance(address(this).balance, fees);

        usdcToken.safeIncreaseAllowance(address(router), amount);

        messageId = router.ccipSend{value: fees}(baseChainSelector, message);

        emit PaymentSent(messageId, msg.sender, block.chainid, address(usdcToken), amount, orderID, fees);
        return messageId;
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override nonReentrant {
        (address payer, uint256 orderID) = abi.decode(
            message.data,
            (address, uint256)
        );

        require(message.destTokenAmounts.length == 1, "Invalid token amount");
        require(message.destTokenAmounts[0].token == address(usdcToken), "Only USDC allowed");
        uint256 amount = message.destTokenAmounts[0].amount;
        
        require( orderIDToAmount[orderID][msg.sender] >= amount, "Payment was never processed through this contract");

        orderIDToAmount[orderID][msg.sender] -= amount;

        usdcToken.transfer(payer, amount);

        emit RefundReceived(payer, amount, orderID);
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
