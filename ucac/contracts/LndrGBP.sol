pragma solidity 0.4.15;

contract LndrGBP {
    uint constant decimals = 2;
    
    function allowTransaction(address creditor, address debtor, uint256 amount) public returns (bool) {
        return true;
    }
}
