
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import {console} from "lib/forge-std/src/Test.sol";
interface CrossChainSender {
    function sendPayment(
        address payer,
        uint256 payerChain,
        uint256 orderID,
        uint256 amount
        
    ) external
        returns (bytes32 messageId);
}
contract MOCKERC20POS {

    using SafeERC20 for IERC20;
    IERC20 MockUSDCContract;
    CrossChainSender crossChainSender;

    uint256 mockChainID;

    struct mockOrder{
        address payer;
        uint256 payerchain;
        uint256 amount;
    }

    mapping(uint256 => mockOrder) public orders;

    constructor(address _MockUSDCContract, uint256 _mockChainID) {
        MockUSDCContract = IERC20(_MockUSDCContract);
        mockChainID = _mockChainID;
    }

    function pay(
        uint256 orderID,
        address payAs,
        uint256 payAsChain,
        uint256 amount
    ) external {
        // Avoiding lint issues

        orders[orderID] = mockOrder(payAs, payAsChain, amount);
        SafeERC20.safeTransferFrom(MockUSDCContract, msg.sender, address(this), amount);

    }

    function refund(uint256 orderID, bool isPaid) external {
        if (isPaid) {
            // If payment was made, transfer funds back to this contract before sending the refund
            MockUSDCContract.safeTransferFrom(msg.sender, address(this), orders[orderID].amount);
        }

        // Proceed to send the refund via cross-chain payment
        MockUSDCContract.approve(address(this), orders[orderID].amount);
        crossChainSender.sendPayment(orders[orderID].payer, orders[orderID].payerchain, orderID, orders[orderID].amount);
    }
    
    function setCrossChainSender(address _crossChainSender) external {
        crossChainSender = CrossChainSender(_crossChainSender);
    }
}

    
