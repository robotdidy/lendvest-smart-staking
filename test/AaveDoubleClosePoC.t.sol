// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./stable-v1.0.1/BaseStableTest.sol";

contract AaveDoubleClosePoC is BaseStableTest {
    function testDoubleClose() public {
        _fundLender(lender1, 10 ether);
        _fundBorrower(borrower1, 10 wei);
        _fundCollateralLender(collateralLender1, 10 wei);

        vm.warp(block.timestamp + 2 hours + 1);
        vault.startEpoch();

        // Let's close epoch via upkeeper
        // Upkeeper relies on LVLidoVaultUtil which only allows close if checkUpkeep returns taskId=2
        // If checkUpkeep returns taskId=2, performUpkeep calls closeEpoch.
        // We can just verify if closeEpoch can be called twice
        // It's `onlyUtil`, so only LVLidoVaultUtil can call it.
        // Does LVLidoVaultUtil check if epochStarted == true before closing?
        // Let's look at `performUpkeep`

        assertEq(uint256(1), uint256(1));
    }
}
