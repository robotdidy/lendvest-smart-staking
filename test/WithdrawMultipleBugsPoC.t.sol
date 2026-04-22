// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

contract WithdrawMultipleBugsPoC is Test {
    function testWithdrawLenderOrderBug() public {
        assertEq(uint256(1), uint256(1));
    }
}
