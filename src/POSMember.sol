// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";

contract POSMember is CCIPReceiver, OwnerIsCreator {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdcToken;
    address public immutable baseReceiver;

    mapping(bytes32 => bool) public sentOrders;

    event OrderSent(
        bytes32 indexed messageId,
        string vendorID,
        string orderID,
        address indexed sender,
        uint256 chainId,
        uint256 amount
    );

    event RefundReceived(
        address indexed receiver,
        uint256 amount
    );

    error AlreadySent(string vendorID, string orderID);
    error NotEnoughBalance(uint256 current, uint256 required);

    constructor(address _router, address _usdc, address _baseReceiver) CCIPReceiver(_router) {
        usdcToken = IERC20(_usdc);
        baseReceiver = _baseReceiver;
    }

    function sendOrder(
        uint64 destinationChainSelector,
        string calldata vendorID,
        string calldata orderID,
        uint256 amount
    ) external returns (bytes32 messageId) {
        bytes32 orderHash = keccak256(abi.encodePacked(vendorID, orderID));
        if (sentOrders[orderHash]) revert AlreadySent(vendorID, orderID);
        sentOrders[orderHash] = true;

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(usdcToken), amount: amount});

        bytes memory data = abi.encode(vendorID, orderID, msg.sender, block.chainid);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(baseReceiver),
            data: data,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({gasLimit: 400_000, allowOutOfOrderExecution: true})
            ),
            feeToken: address(0)
        });

        IRouterClient router = IRouterClient(getRouter());
        uint256 fees = router.getFee(destinationChainSelector, message);
        if (fees > address(this).balance) revert NotEnoughBalance(address(this).balance, fees);

        usdcToken.approve(address(router), amount);

        messageId = router.ccipSend{value: fees}(destinationChainSelector, message);

        emit OrderSent(messageId, vendorID, orderID, msg.sender, block.chainid, amount);
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        (address refundTo) = abi.decode(message.data, (address));
        require(message.destTokenAmounts.length == 1, "Invalid token count");
        require(message.destTokenAmounts[0].token == address(usdcToken), "Invalid token");

        uint256 amount = message.destTokenAmounts[0].amount;
        usdcToken.safeTransfer(refundTo, amount);

        emit RefundReceived(refundTo, amount);
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
