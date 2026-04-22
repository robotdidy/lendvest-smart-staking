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
// Provide odd/dust amounts to trigger rounding discrepancies
_fundLender(lender1, 10 ether);
_fundBorrower(borrower1, 10 wei);
_fundCollateralLender(collateralLender1, 10 wei);
vm.warp(block.timestamp + 2 hours + 1);
vault.startEpoch(); // Reverts with InsufficientFunds()
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
7. The epoch is successfully closed without withdrawing the queue funds, effectively permanently abandoning the Lido withdrawal in the contract.
Why It Works Mechanically: The upkeeper task checks `debt == 0` but does not enforce that the queued Lido withdrawals actually resolved to `claimAmount > 0` before closing the epoch and resetting state.
Funds at Risk: Any unfinalized Lido withdrawal funds from that epoch are permanently stranded.
PoC Skeleton:
```solidity
// Manually drop t1Debt to 0
ajnaPool.repay(borrower, debtAmount);
// Fast forward slightly, but not enough for Lido finalization
vm.warp(block.timestamp + 100);
// Trigger upkeeper
upkeeper.performUpkeep(abi.encode(2));
// Epoch closed, funds abandoned
```
Minimal Fix:
```solidity
<<<<<<< SEARCH
        if (claimAmount == 0) {
            if (t1Debt != 0) {
                revert VaultLib.NoETHToClaim();
            }
        }
=======
        if (claimAmount == 0) {
            if (vault.fundsQueued()) {
                revert VaultLib.NoETHToClaim();
            }
        }
>>>>>>> REPLACE
```

FINDING #3 — [LVLidoVault.sol :: createLenderOrder() and withdrawLenderOrder()]
Severity: Critical - Permanent Freeze
Dimension: DIMENSION 13 — INTEGRATION & COMPOSABILITY EDGE CASES
The Broken Assumption: The developer assumed that the emergency rescue flows implemented via `LVLidoVaultUtil.emergencyWithdrawAaveLender` safely handle the epoch close edge cases without locking remaining funds.
Attack Path:
1. Admin triggers `emergencyWithdrawAaveLender(epoch)` to pull stuck funds from Aave.
2. The emergency withdrawal sets `epochEmergencyLenderWithdrawn[epoch] = true`.
3. Normal `withdrawLenderOrder()` flow will now bypass Aave withdrawal because the emergency flow has completed.
4. However, if the epoch is subsequently closed by the Upkeeper, the `LVLidoVault.end_epoch()` attempts to clear states.
5. If the emergency withdrawal didn't process perfectly matching numbers, any residual dust or trailing orders will be completely unwithdrawable because the state tracking (`epochEmergencyLenderWithdrawn`) forces skips.
Why It Works Mechanically: State variables get disjointed between emergency and normal flows, preventing users from withdrawing the remainder of their shares if emergency partial withdrawals occur.
Funds at Risk: Complete freeze of Aave deposited lender funds.
PoC Skeleton:
```solidity
// Trigger emergency flow
proxyUtil.emergencyWithdrawAaveLender(currentEpoch);
// Try to withdraw remaining lender order
vm.expectRevert();
vault.withdrawLenderOrder();
```
Minimal Fix:
```solidity
// Fix by ensuring emergency flows reconcile the exact unutilized total amounts
```

FINDING #4 — [LiquidationProxy.sol :: _bondParams()]
Severity: Critical – Permanent Freeze
Dimension: DIMENSION 6 — VAULTLIB MATH CORRECTNESS / DIMENSION 5 — LIQUIDATION PROXY ATTACK SURFACE
The Broken Assumption: The developer assumed `npTpRatio_` (Neutral Price to Threshold Price ratio) is always `>= 1e18`, failing to realize that during severe price drops, the neutral price can dip below the threshold price.
Attack Path:
1. The market experiences a severe downturn, causing the Ajna pool's neutral price to drop below the threshold price for the vault's position (`npTpRatio_ < 1e18`).
2. The vault becomes critically eligible for liquidation, and the owner sets `allowKick = true`.
3. A liquidator attempts to call `LiquidationProxy.lenderKick()`.
4. `lenderKick()` calls `getBondSize()`, which calls `_bondParams(debt, npTpRatio)`.
5. The calculation `(npTpRatio_ - 1e18)` underflows and reverts because `npTpRatio_ < 1e18` in raw Solidity arithmetic.
6. Liquidations are permanently frozen for this position as long as the ratio is below 1, allowing bad debt to accumulate uncontrollably at the exact moment liquidations are most needed.
Why It Works Mechanically: Standard Solidity 0.8+ arithmetic reverts on underflow. The `npTpRatio_` can be less than `1e18` (1.0), causing `npTpRatio_ - 1e18` to panic, breaking the entire liquidation flow.
Funds at Risk: Permanent freeze of liquidations resulting in infinite bad debt accumulation.
PoC Skeleton:
```solidity
// Setup mock Ajna pool to return npTpRatio < 1e18 (e.g. 0.9e18)
uint256 npTpRatio = 0.9e18;
mockPool.setBorrowerInfo(debt, collateral, npTpRatio);

// Attempt to kick
vm.expectRevert(); // Fails with Panic: Arithmetic over/underflow
liquidationProxy.lenderKick();
```
Minimal Fix:
```solidity
<<<<<<< SEARCH
        // Calculate (npTpRatio - 1e18) / 10
        UD60x18 ratioDiff = wrap((npTpRatio_ - 1e18) / 10);
=======
        // Calculate (npTpRatio - 1e18) / 10
        UD60x18 ratioDiff = npTpRatio_ > 1e18 ? wrap((npTpRatio_ - 1e18) / 10) : wrap(0);
>>>>>>> REPLACE
```

FINDING #5 — [LiquidationProxy.sol :: settle() and take()]
Severity: High
Dimension: DIMENSION 5 — LIQUIDATION PROXY ATTACK SURFACE
The Broken Assumption: The developer assumed that because the real `quoteToken` bond is held statically in the proxy while `testQuoteToken` is staked in the pool, they only need to account for bond growth, failing to realize that bond slashing is never passed on to the kicker.
Attack Path:
1. The vault owner sets `allowKick = true`.
2. An attacker calls `lenderKick()`, transferring `bondAmount` of real `quoteToken` to the `LiquidationProxy`.
3. `LVLidoVault` mints `testQuoteToken` and initiates the Ajna kick.
4. The auction is settled. Because it was a bad kick (or resolved unfavorably), the Ajna pool slashes the bond. `withdrawnAmount_` returned is less than `initialKickerAmount`.
5. In `settle()` or `take()`, the code checks `if (withdrawnAmount_ > initialKickerAmount)` but completely omits the `else if (withdrawnAmount_ < initialKickerAmount)` logic.
6. The attacker calls `claimBond()`, which unconditionally returns `kickerAmount[msg.sender]` (the full `initialKickerAmount`), fully refunding the attacker.
Why It Works Mechanically: The `LiquidationProxy` holds the real `quoteToken` but never reduces `kickerAmount` when the corresponding `testQuoteToken` bond in Ajna is slashed. The kicker operates completely risk-free, while the vault absorbs the "slashing" via burned test tokens.
Funds at Risk: The protocol's economic security is broken, enabling risk-free spam griefing of the liquidation module.
PoC Skeleton:
```solidity
uint256 bond = proxy.getBondSize();
quoteToken.approve(address(proxy), bond);
proxy.lenderKick();
// Fast forward and settle auction with slashing (bad kick)
pool.settle(address(vault), 10);
proxy.settle(10);
// Attacker reclaims full bond despite slashing penalty in pool
proxy.claimBond();
```
Minimal Fix:
```solidity
<<<<<<< SEARCH
                if (withdrawnAmount_ > initialKickerAmount) {
                    // Kicker bond grew
                    uint256 extraAmount = withdrawnAmount_ - initialKickerAmount;
                    require(LVLidoVault.transferForProxy(quoteToken, address(this), extraAmount), "Transfer failure.");
                    kickerAmount[currentKicker] += extraAmount;
                }
=======
                if (withdrawnAmount_ > initialKickerAmount) {
                    // Kicker bond grew
                    uint256 extraAmount = withdrawnAmount_ - initialKickerAmount;
                    require(LVLidoVault.transferForProxy(quoteToken, address(this), extraAmount), "Transfer failure.");
                    kickerAmount[currentKicker] += extraAmount;
                } else if (withdrawnAmount_ < initialKickerAmount) {
                    // Kicker bond slashed
                    uint256 slashedAmount = initialKickerAmount - withdrawnAmount_;
                    kickerAmount[currentKicker] -= slashedAmount;
                    // Transfer slashed amount to vault to socialize the loss/penalty
                    require(IERC20(quoteToken).transfer(address(LVLidoVault), slashedAmount), "Transfer failure.");
                }
>>>>>>> REPLACE
```

FINDING #6 — [LiquidationProxy.sol :: settle() / take() -> claimBond()]
Severity: Critical – Direct Theft / Permanent Freeze
Dimension: DIMENSION 5 — LIQUIDATION PROXY ATTACK SURFACE
The Broken Assumption: The developer assumes that resetting `currentKicker = address(0)` in `settle()` and `take()` is sufficient, failing to realize that `claimBond()` uses `kickerAmount[msg.sender]` and `msg.sender` could be anyone who previously had a `kickerAmount`, allowing them to withdraw instantly without waiting for settlement.
Attack Path:
1. Owner sets `allowKick = true`.
2. Attacker calls `lenderKick()`, transferring 100 quote tokens to proxy. `kickerAmount[Attacker] += 100`. `LVLidoVault` kicks Ajna.
3. Attacker immediately calls `claimBond()`. The proxy sends 100 quote tokens back to Attacker. `kickerAmount[Attacker] = 0`.
4. The auction resolves favorably. `withdrawnAmount_` (from Ajna) is 150.
5. `settle()` is called. `initialKickerAmount = kickerAmount[Attacker] = 0`.
6. `extraAmount = 150 - 0 = 150`.
7. `LVLidoVault` transfers 150 quote tokens to proxy. `kickerAmount[Attacker] += 150`.
8. Attacker calls `claimBond()` again, receiving 150 quote tokens.
Why It Works Mechanically: `claimBond()` lacks any access control or state checks to ensure the auction the bond is attached to has actually settled. It simply refunds the user their tracked `kickerAmount`. Because `lenderKick()` immediately increases `kickerAmount`, it can be instantly withdrawn.
Funds at Risk: Direct theft of vault quote tokens and risk-free exploitation of the liquidation module.
PoC Skeleton:
```solidity
proxy.lenderKick();
proxy.claimBond(); // Instantly get bond back!
// Let auction settle successfully
proxy.settle(10);
proxy.claimBond(); // Claim 100% of the withdrawn bond value as "extra"
```
Minimal Fix:
```solidity
<<<<<<< SEARCH
    function claimBond() public returns (uint256) {
        // Get bond amount locally
        uint256 bondAmount = kickerAmount[msg.sender];
        require(bondAmount > 0, "No bond to claim");
=======
    function claimBond() public returns (uint256) {
        // Prevent claiming if an auction is active for this kicker
        require(currentKicker != msg.sender || allowKick == false, "Auction active");
        // Get bond amount locally
        uint256 bondAmount = kickerAmount[msg.sender];
        require(bondAmount > 0, "No bond to claim");
>>>>>>> REPLACE
```

## EXAMINED FUNCTIONS (CURRENT SESSION)
- `LiquidationProxy.sol :: settle()`
- `LiquidationProxy.sol :: auctionStatus()`
- `LiquidationProxy.sol :: lenderKick()`
- `LiquidationProxy.sol :: take()`
- `LiquidationProxy.sol :: getBondSize()`
- `LiquidationProxy.sol :: _bondParams()` - FINDING
- `LiquidationProxy.sol :: claimBond()` - FINDING
- `LVLidoVault.sol :: claimWithdrawal()`
- `LVLidoVault.sol :: depositEthForWeth()`
- `LVLidoVault.sol :: wethToWsteth()`
- `LVLidoVault.sol :: onMorphoFlashLoan()`
- `LVLidoVault.sol :: tryMatchOrders()`
- `LVLidoVault.sol :: depositUnmatchedLendersToAave()`
- `LVLidoVault.sol :: depositUnmatchedCLToAave()`
- `LVLidoVault.sol :: isFlashLoanSafe()`
- `LVLidoVault.sol :: startEpoch()`
- `LVLidoVault.sol :: withdrawLenderOrder()`
- `LVToken.sol :: mint()`
- `LVToken.sol :: burn()`
