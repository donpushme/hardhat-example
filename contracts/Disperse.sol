// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Disperse is Ownable {
    address private treasury;
    uint256 public fee;

    constructor() Ownable(msg.sender) {
        treasury = msg.sender;
    }

    function setTreasury(address _newTreasury) external onlyOwner {
        treasury = _newTreasury;
    }

    function setFee(uint256 _fee) external onlyOwner {
        fee = _fee;
    }

    function disperseToken(
        uint256[] memory amounts,
        address token,
        address[] memory users
    ) public payable {
        require(msg.value >= fee, "Insufficient for fee balance");

        payable(treasury).transfer(msg.value);

        require(amounts.length == users.length, "Arrays length mismatch");

        uint256 len = users.length;
        uint256 total_amount = 0;

        for (uint256 i = 0; i < len; i++) {
            total_amount += amounts[i];
        }

        require(
            IERC20(token).transferFrom(msg.sender, address(this), total_amount),
            "Transfer to contract failed"
        );

        for (uint256 i = 0; i < len; i++) {
            IERC20(token).approve(users[i], amounts[i]);
            require(
                IERC20(token).transfer(users[i], amounts[i]),
                "Transfer to recipient failed"
            );
        }
    }

    function disperse(
        uint256[] memory amounts,
        address[] memory users
    ) public payable {
        require(msg.value >= fee, "Insufficient for fee balance");

        payable(treasury).transfer(msg.value);

        require(amounts.length == users.length, "Arrays length mismatch");

        uint256 len = users.length;
        uint256 total_amount = 0;

        for (uint256 i = 0; i < len; i++) {
            total_amount += amounts[i];
        }

        require(
            total_amount + fee <= msg.value,
            "Insufficient Gas Coin deposited"
        );

        for (uint256 i = 0; i < len; i++) {
            payable(users[i]).transfer(amounts[i]);
        }
    }
}
