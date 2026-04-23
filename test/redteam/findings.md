# Red Team Vulnerability Report: LeverageVault

During a rigorous security review, 6 critical and high-severity vulnerabilities were discovered. We have attached Integration test Proof of Concepts (PoCs) in `test/redteam/RedTeam.t.sol` to reliably trigger and demonstrate these bugs.

## 1. Flash Loan Repayment Revert (Permanent DoS)
**Severity:** Critical
**Description:** A missing variable typecast round-down when calculating `lenderWethNeeded` logic against `flashLoanAmount` during epoch startup in `LVLidoVault.sol` leads to the flashloan callback not having sufficient output tokens to repay the flashloan amount.
**Impact:** Epochs can be permanently prevented from starting if standard slippage values are used since the flashloan will revert, completely DoS'ing the vault protocol.

## 2. Rescue Flow Loss of Aave Funds
**Severity:** High
**Description:** The rescue flow relies on an arbitrary `LVLidoVaultUtilRescue.sol` contract performing state resets on `LVLidoVault.sol`. However, it only rescues underlying tokens and forgets to withdraw tokens supplied to the Aave V3 Pool beforehand.
**Impact:** All lender quotes placed into Aave are permanently lost (stranded in the Aave vault) upon a rescue flow being triggered.

## 3. Total Collateral Lender CT Loses Principal
**Severity:** High
**Description:** The `totalCollateralLenderCT` global state variable is not decremented during the `depositUnmatchedCLToAave` functionality when `collateralAmount` is modified in the active lender array.
**Impact:** Upon conclusion of an epoch, the active sum of collateral amounts will be severely out of sync with `totalCollateralLenderCT`. This means lenders can withdraw more than they rightfully should, potentially draining the vault and causing insolvency for remaining collateral lenders.

## 4. LiquidationProxy Insolvency Leak
**Severity:** Critical
**Description:** The `take` function of `LiquidationProxy.sol` burns vault internal tokens (`LVToken`) and instructs the vault to transfer out real `wstETH` but neglects to correspondingly decrement the internal ledger's `totalBorrowerCT` variable.
**Impact:** This mismatch permanently breaks internal accounting. Because `totalBorrowerCT` remains erroneously high, lenders/borrowers will have claim to more `wstETH` than actually exists in the vault after liquidation events, causing eventual vault insolvency where the last users to withdraw receive nothing.

## 5. Yield Stealing MEV Attack
**Severity:** High
**Description:** Attackers can sandwich the epoch closure upkeeps. Because the protocol tracks yields simply by looking at internal `balanceOf` metrics vs previously saved metrics when allocating yield, an attacker can create a massive lender deposit exactly right before `closeEpoch` is triggered.
**Impact:** Because the snapshot uses a shared pool model to payout, a last-minute flash deposit will artificially dilute all legitimate stakers and steal the vast majority of the yield generated over the entire multi-week epoch duration.

## 6. Lido Withdrawal Abandonment
**Severity:** High
**Description:** If `repayAjnaDebt` completes successfully but Lido withdrawals fail or revert for an internal reason inside `closeEpoch`, the `fundsQueued` boolean flag can remain stuck in a permanently `true` state.
**Impact:** If `fundsQueued` is stuck at `true`, the vault becomes permanently soft-bricked, as many key functions rely on this boolean accurately representing the state of the Lido queue.
