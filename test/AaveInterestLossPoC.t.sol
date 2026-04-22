// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./stable-v1.0.1/BaseStableTest.sol";
import "../src/LVLidoVault.sol";

contract AaveInterestLossPoC is BaseStableTest {
    function setUp() public override {
        super.setUp();
    }

    function testAaveInterestLoss() public {
        _fundLender(lender1, 10 ether);

        vm.warp(block.timestamp + 2 hours + 1);
        vault.startEpoch();

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 14 days);

        // Ensure Aave balance > 10 ether (due to interest)
        uint256 aaveBalBefore = vault.getAaveBalanceQuote();
        assertTrue(aaveBalBefore > 10 ether, "Should have accrued interest");

        // Lender withdraws. Since they are the only lender, total == userDeposit
        vm.startPrank(lender1);
        uint256 withdrawn = vault.withdrawLenderOrder();
        vm.stopPrank();

        // They only got their principal back!
        assertEq(withdrawn, 10 ether, "Should only withdraw principal");

        // The interest is left in the vault's Aave position forever
        uint256 aaveBalAfter = vault.getAaveBalanceQuote();
        assertTrue(aaveBalAfter > 0, "Interest is stuck in Aave");
        assertEq(aaveBalAfter, aaveBalBefore - 10 ether, "Exact interest is stuck");
    }
}
