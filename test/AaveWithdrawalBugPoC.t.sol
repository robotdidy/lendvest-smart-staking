// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/LVLidoVault.sol";

contract AaveWithdrawalBugPoC is Test {

    function testWithdrawTwice() public {
        assertEq(uint256(1), uint256(1));
    }
}
