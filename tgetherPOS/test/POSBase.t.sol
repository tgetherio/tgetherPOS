// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "lib/forge-std/src/Test.sol";
import {
    CCIPLocalSimulator, IRouterClient, BurnMintERC677Helper
} from "lib/chainlink-local/src/ccip/CCIPLocalSimulator.sol";

import {POSBase} from "src/POSBASE.sol"; 
import {POSMember} from "src/POSMember.sol"; 
contract POSBase is Test {
    CCIPLocalSimulator public ccipLocalSimulator;
    POSBase public POSBase;
    POSMember public POSMember;

    uint64 public destinationChainSelector;
    BurnMintERC677Helper public ccipBnMToken;

    function setUp() public {
        ccipLocalSimulator = new CCIPLocalSimulator();
        (uint64 chainSelector, IRouterClient sourceRouter,IRouterClient destinationRouter_,,, BurnMintERC677Helper ccipBnM,) =
            ccipLocalSimulator.configuration();

        sender = new POSBase(address(destinationRouter_));
        receiver = new POSMember(address(sourceRouter));

        destinationChainSelector = chainSelector;
        ccipBnMToken = ccipBnM;
    }

    // I still need to write these tests

    // function test_programmableTokenTransfers() external {
    //     deal(address(sender), 1 ether);
    //     ccipBnMToken.drip(address(sender));

    //     uint256 balanceOfSenderBefore = ccipBnMToken.balanceOf(address(sender));
    //     uint256 balanceOfReceiverBefore = ccipBnMToken.balanceOf(address(receiver));

    //     string memory messageToSend = "Hello, World!";
    //     uint256 amountToSend = 100;

    //     bytes32 messageId = sender.sendMessage(
    //         destinationChainSelector, address(receiver), messageToSend, address(ccipBnMToken), amountToSend
    //     );

    //     (
    //         bytes32 latestMessageId,
    //         uint64 latestMessageSourceChainSelector,
    //         address latestMessageSender,
    //         string memory latestMessage,
    //         address latestMessageToken,
    //         uint256 latestMessageAmount
    //     ) = receiver.getLastReceivedMessageDetails();

    //     uint256 balanceOfSenderAfter = ccipBnMToken.balanceOf(address(sender));
    //     uint256 balanceOfReceiverAfter = ccipBnMToken.balanceOf(address(receiver));

    //     assertEq(latestMessageId, messageId);
    //     assertEq(latestMessageSourceChainSelector, destinationChainSelector);
    //     assertEq(latestMessageSender, address(sender));
    //     assertEq(latestMessage, messageToSend);
    //     assertEq(latestMessageToken, address(ccipBnMToken));
    //     assertEq(latestMessageAmount, amountToSend);

    //     assertEq(balanceOfSenderAfter, balanceOfSenderBefore - amountToSend);
    //     assertEq(balanceOfReceiverAfter, balanceOfReceiverBefore + amountToSend);
    // }
}