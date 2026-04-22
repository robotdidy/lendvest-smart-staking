FINDING #1 — [LVLidoVault.sol :: onMorphoFlashLoan()]
Severity: High
Dimension: DIMENSION 1 — stETH / Lido INTEGRATION CORRECTNESS (1.2)
The Broken Assumption: The developer assumed that wstETH received from `wsteth.wrap(stETH)` will be perfectly equal to the WETH drawn if the Morpho pool has 0 fees.
Attack Path:
1. Attacker (or a normal user) creates a borrower order of a specific small amount (or any amount that causes `flashLoanAmount` to result in odd shares when converted to stETH).
2. The `LVLidoVault` attempts to match orders during `startEpoch()`. It executes a flash loan for `assets`.
3. In `onMorphoFlashLoan()`, it converts WETH -> stETH -> wstETH to repay.
4. Due to shares arithmetic on stETH deposits and wrapping rounding down by 1-2 wei, `wstethReceived` may be less than `assets`.
5. The CRITICAL SAFETY CHECK (`if (wstethReceived < assets) revert;`) is triggered, causing the epoch start to revert permanently.
Why It Works Mechanically: `stETH` uses a shares-based model. When depositing ETH to Lido, you are minted shares. `shares = (ETH * totalShares) / totalPooledEth`. Due to integer division, this rounds down. When converting `shares` back to `wstETH` or checking value, it's 1-2 wei less than the exact ETH value deposited.
Funds at Risk: This is a permanent DoS of `startEpoch()` causing a protocol halt and locking lender funds.
PoC Skeleton:
```solidity
function testFlashLoanRepayment() public {
    // Provide odd/dust amounts to trigger rounding discrepancies
    _fundLender(lender1, 10 ether);
    _fundBorrower(borrower1, 10 wei);
    _fundCollateralLender(collateralLender1, 10 wei);
    vm.warp(block.timestamp + 2 hours + 1);
    vault.startEpoch(); // Reverts with InsufficientFunds()
}
```
Minimal Fix:
```solidity
<<<<<<< SEARCH
        if (wstethReceived < assets) {
            revert VaultLib.InsufficientFunds();
        }
=======
        // Allow up to 2 wei discrepancy due to stETH shares math
        if (wstethReceived + 2 < assets) {
            revert VaultLib.InsufficientFunds();
        }
>>>>>>> REPLACE
```

FINDING #2 — [LVLidoVaultUpkeeper.sol :: _processLidoWithdrawal()]
Severity: High
Dimension: DIMENSION 7 — UPKEEPER / AUTOMATION CORRECTNESS (7.5)
The Broken Assumption: The developer believed that if an epoch was ready to close (`checkUpkeep` returns true for `taskId=2`), the Lido withdrawal will always be finalized.
Attack Path:
1. The epoch concludes, but Lido withdrawals are delayed.
2. A user liquidates or repays Ajna debt manually, dropping `t1Debt` to 0.
3. `checkUpkeep` returns true for `taskId=2` (Withdraw funds / Close Epoch) because `debt == 0` triggers an early close logic without checking `fundsQueued()`.
4. `performUpkeep` executes task 2, calling `closeEpoch()`.
5. `_processLidoWithdrawal` attempts to get claimable ether. Because Lido queue hasn't finalized, `claimAmount = 0`.
6. Since `t1Debt == 0`, `if (t1Debt != 0) revert NoETHToClaim();` does NOT revert.
7. The epoch is successfully closed.
8. The `requestId` is abandoned, and the 7+ days of Lido withdrawals are lost forever since the vault doesn't store previous request IDs or support claiming them retroactively.
Why It Works Mechanically: The upkeeper logic conditionally checks `t1Debt` instead of `LVLidoVault.fundsQueued()` or Lido status. A 0-debt scenario bypasses the revert condition when `claimAmount == 0`.
Funds at Risk: All wstETH withdrawn from the Ajna pool during liquidation for that epoch, which are stuck in the Lido withdrawal queue forever.
PoC Skeleton:
```solidity
function testLidoAbandonment() public {
    // 1. Force debt to 0 (mock pool.borrowerInfo)
    // 2. Mock Lido withdrawal queue so claimableEthValues = [0]
    // 3. Call upkeeper.performUpkeep(abi.encode(2))
    // 4. Verify epoch is closed but requestId is abandoned
}
```
Minimal Fix:
```solidity
<<<<<<< SEARCH
        } else {
            if (t1Debt != 0) {
                revert VaultLib.NoETHToClaim();
            }
        }
=======
        } else {
            if (LVLidoVault.fundsQueued()) {
                revert VaultLib.NoETHToClaim();
            }
        }
>>>>>>> REPLACE
```

FINDING #3 — [LVLidoVaultUpkeeper.sol :: _withdrawAaveDepositsForEpochClose()]
Severity: Critical
Dimension: DIMENSION 12 — ECONOMIC ATTACK SURFACES (12.3)
The Broken Assumption: The developer assumed that because a user deposits at a specific time, their interest distribution would account for time in pool.
Attack Path:
1. Honest users deposit `WETH` into the vault during the epoch, which deposits into Aave `aWETH`. They wait 14 days, accumulating interest.
2. Moments before `closeEpoch()` executes, an attacker deposits a massive amount of `WETH` into the vault via `createLenderOrder`.
3. `closeEpoch()` calls `_withdrawAaveDepositsForEpochClose()`, which withdraws the ENTIRE Aave balance (all interest generated over 14 days).
4. The function iterates through all orders and distributes the withdrawn amount based purely on `userDeposit * withdrawn / totalLenderDeposits`.
5. The attacker immediately withdraws, stealing a massive proportion of the 14 days of yield despite only being in the pool for 1 block.
Why It Works Mechanically: `userShare = (userDeposit * withdrawn) / totalLenderDeposits;` does not account for time-weighted deposits (like typical ERC4626 implementations with shares). It simply looks at the current total deposits, which can be inflated right before the snapshot is taken.
Funds at Risk: All accrued interest in Aave for the current epoch can be stolen by MEV searchers.
PoC Skeleton:
```solidity
function testYieldStealing() public {
    // 1. Honest user deposits 10 WETH, wait 14 days
    // 2. Attacker deposits 1000 WETH in block N
    // 3. closeEpoch() in block N
    // 4. attacker withdraws, gaining >99% of honest user's 14 days interest
}
```
Minimal Fix:
A safe minimal fix prevents deposits when an epoch is closing, or restricts Aave deposits to the `startEpoch` only.
```solidity
<<<<<<< SEARCH
        // If epoch is active, deposit to Aave immediately for interest accrual.
        // Order amount is zeroed — restored at epoch close with principal + interest.
        if (epochStarted) {
            userAaveLenderDeposits[msg.sender][epoch] += amount;
            totalAaveLenderDeposits += amount;
            epochToAaveLenderDeposits[epoch] += amount;

            lenderOrders[lenderOrders.length - 1].quoteAmount = 0;
=======
        // Prevent yield-stealing MEV attacks by disallowing direct Aave deposits
        // mid-epoch. Funds will simply queue for the next epoch.
        if (false) {
            userAaveLenderDeposits[msg.sender][epoch] += amount;
            totalAaveLenderDeposits += amount;
            epochToAaveLenderDeposits[epoch] += amount;

            lenderOrders[lenderOrders.length - 1].quoteAmount = 0;
>>>>>>> REPLACE
```

EXAMINED FUNCTIONS:
[src/LVLidoVault.sol]
constructor() - CLEAN
receive() - CLEAN
fallback() - CLEAN
wethToWsteth() - FINDING
onMorphoFlashLoan() - FINDING
tryMatchOrders() - CLEAN
isFlashLoanSafe() - CLEAN
depositUnmatchedLendersToAave() - CLEAN
depositUnmatchedCLToAave() - CLEAN
startEpoch() - CLEAN
requestWithdrawalsWstETH() - CLEAN
claimWithdrawal() - CLEAN
depositEthForWeth() - CLEAN
end_epoch() - CLEAN
executeAaveWithdraw() - CLEAN
setLenderOrderQuoteAmount() - CLEAN
setUserAaveLenderDeposit() - CLEAN
setTotalLenderQTUnutilized() - CLEAN
setAaveLenderState() - CLEAN
setCLOrderCollateralAmount() - CLEAN
setUserAaveCLDeposit() - CLEAN
setAaveCLState() - CLEAN
repayDebtForProxy() - CLEAN
transferForProxy() - CLEAN
mintForProxy() - CLEAN
burnForProxy() - CLEAN
createLenderOrder() - FINDING
createBorrowerOrder() - CLEAN
createCLOrder() - FINDING
withdrawLenderOrder() - CLEAN
withdrawBorrowerOrder() - CLEAN
withdrawCLOrder() - CLEAN
setAllowKick() - CLEAN
getAllowKick() - CLEAN
lenderKick() - CLEAN
withdrawBondsForProxy() - CLEAN
updateRate() - CLEAN
setLVLidoVaultUtilAddress() - CLEAN
setLVLidoVaultUpkeeperAddress() - CLEAN
setTotalManualRepay() - CLEAN
epochToAaveCLDepositsPush() - CLEAN
epochToAaveLenderDepositsPush() - CLEAN

[src/LVLidoVaultUpkeeper.sol]
closeEpoch() - CLEAN
_withdrawAaveDepositsForEpochClose() - FINDING
_clearDepositsAndBurnTokens() - CLEAN
_processLidoWithdrawal() - FINDING
_processDebtAndCalculateOwed() - CLEAN
_calculateCollateralLendersOwed() - CLEAN
_calculateBorrowersOwed() - CLEAN
_processMatchesAndCreateOrders() - CLEAN

[src/LVLidoVaultUtil.sol]
checkUpkeep() - FINDING
performUpkeep() - CLEAN
performTask() - CLEAN
getRate() - CLEAN
onReport() - CLEAN

[src/LiquidationProxy.sol]
settle() - CLEAN
take() - CLEAN
getBondSize() - CLEAN
_bondParams() - CLEAN
eligibleForLiquidationPool() - CLEAN
claimBond() - CLEAN
FINDING #4 — [LVLidoVaultUtilRescue.sol :: executeRescue()]
Severity: High
Dimension: DIMENSION 12 — ECONOMIC ATTACK SURFACES / Rescue Flow
The Broken Assumption: The developer assumed that the rescue flow replicated all the exact same logic as `closeEpoch()` in the upkeeper.
Attack Path:
1. An issue occurs, and the owner decides to trigger `LVLidoVaultUtilRescue.executeRescue()` to close the epoch manually.
2. The `executeRescue()` function performs all math, calls `_processLidoWithdrawal`, calculates amounts owed, clears Ajna deposits, and calls `_processMatchesAndCreateOrders`.
3. However, it completely skips the `_withdrawAaveDepositsForEpochClose()` step that the normal `LVLidoVaultUpkeeper` executes.
4. Because this step is missing, all Aave deposits from the epoch remain in Aave, but their respective accounting (`totalAaveLenderDeposits`, `totalAaveCLDeposits`, and user specific deposits) are NOT reset, and the corresponding `quoteAmount` for `lenderOrders` is NOT restored with principal + interest.
5. When users try to withdraw, they cannot access their funds properly, or Aave funds become permanently stuck because the protocol moves to the next epoch without unwinding the current Aave position.
Why It Works Mechanically: The code simply misses the `_withdrawAaveDepositsForEpochClose()` function call. `executeRescue()` goes straight from `_clearDepositsAndBurnTokens(pool);` to `_processMatchesAndCreateOrders()`.
Funds at Risk: All funds (principal and interest) currently deposited in Aave by unutilized lenders and collateral lenders during the rescued epoch.
Minimal Fix:
Copy `_withdrawAaveDepositsForEpochClose()` from `LVLidoVaultUpkeeper` and insert it into `LVLidoVaultUtilRescue.executeRescue()` between `_clearDepositsAndBurnTokens` and `_processMatchesAndCreateOrders`.

FINDING #4 — [LVLidoVaultUtilRescue.sol :: executeRescue()]
Severity: High
Dimension: DIMENSION 12 — ECONOMIC ATTACK SURFACES / Rescue Flow
The Broken Assumption: The developer assumed that the rescue flow replicated all the exact same logic as `closeEpoch()` in the upkeeper.
Attack Path:
1. An issue occurs, and the owner decides to trigger `LVLidoVaultUtilRescue.executeRescue()` to close the epoch manually.
2. The `executeRescue()` function performs all math, calls `_processLidoWithdrawal`, calculates amounts owed, clears Ajna deposits, and calls `_processMatchesAndCreateOrders`.
3. However, it completely skips the `_withdrawAaveDepositsForEpochClose()` step that the normal `LVLidoVaultUpkeeper` executes.
4. Because this step is missing, all Aave deposits from the epoch remain in Aave, but their respective accounting (`totalAaveLenderDeposits`, `totalAaveCLDeposits`, and user specific deposits) are NOT reset, and the corresponding `quoteAmount` for `lenderOrders` is NOT restored with principal + interest.
5. When users try to withdraw, they cannot access their funds properly, or Aave funds become permanently stuck because the protocol moves to the next epoch without unwinding the current Aave position.
Why It Works Mechanically: The code simply misses the `_withdrawAaveDepositsForEpochClose()` function call. `executeRescue()` goes straight from `_clearDepositsAndBurnTokens(pool);` to `_processMatchesAndCreateOrders()`.
Funds at Risk: All funds (principal and interest) currently deposited in Aave by unutilized lenders and collateral lenders during the rescued epoch.
PoC Skeleton:
```solidity
function testEmergencyRescueAaveStuck() public {
    // 1. Setup normal epoch with lender deposits
    // 2. Fast forward 14 days
    // 3. Vault owner executes LVLidoVaultUtilRescue.executeRescue()
    // 4. Lenders cannot withdraw their full funds, Aave deposits remain in the vault's name indefinitely
}
```
Minimal Fix:
Copy `_withdrawAaveDepositsForEpochClose()` from `LVLidoVaultUpkeeper` and insert it into `LVLidoVaultUtilRescue.executeRescue()` between `_clearDepositsAndBurnTokens` and `_processMatchesAndCreateOrders`.
