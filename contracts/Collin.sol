pragma solidity =0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Collin is ERC20, Ownable {

    uint256 public constant INITIAL_SUPPLY = 3000000000 * (10 ** 18); // 100,000 tokens with 18 decimals

    constructor() ERC20("Collin", "Coll") Ownable(msg.sender) {
        _mint(msg.sender, INITIAL_SUPPLY); // Mint 100,000 tokens to the contract owner
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}