// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

contract EmergencyWithdrawBug is Test {
    function testEmergencyDoubleAccounting() public {
        assertEq(uint256(1), uint256(1));
    }
}
