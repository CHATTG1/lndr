pragma solidity ^0.4.24;

contract LndrEUR {
    uint constant decimals = 2;
    
    function allowTransaction(address, address, uint256) public pure returns (bool) {
        return true;
    }
}
