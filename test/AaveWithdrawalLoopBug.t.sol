// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./stable-v1.0.1/BaseStableTest.sol";

contract AaveWithdrawalLoopBug is BaseStableTest {
    function testWithdrawLenderOrderLoop() public {
        _fundLender(lender1, 10 ether);
        _fundBorrower(borrower1, 10 wei);
        _fundCollateralLender(collateralLender1, 10 wei);

        vm.warp(block.timestamp + 2 hours + 1);
        vault.startEpoch();

        // Wait some time
        vm.warp(block.timestamp + 1 days);

        // Create a SECOND order for the same lender
        vm.startPrank(lender1);
        deal(WETH_ADDRESS, lender1, 20 ether);
        IERC20(WETH_ADDRESS).approve(address(vault), 20 ether);
        vault.createLenderOrder(20 ether);
        vm.stopPrank();

        // Now withdraw
        vm.startPrank(lender1);
        vault.withdrawLenderOrder();
        vm.stopPrank();

        // Let's assert whether totalLenderQTUnutilized is perfectly zero.
        assertEq(vault.totalLenderQTUnutilized(), 0);
        // Is Aave tracking broken?
        assertEq(vault.userAaveLenderDeposits(lender1, vault.epoch()), 0);
    }
}
