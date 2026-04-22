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
In `take()`, what if `withdrawnAmount_ > 0` but `currentKicker == address(0)`? This occurs if `settle()` was called previously (which resets `currentKicker`), but `withdrawnAmount_` wasn't fully processed or another edge case. Wait, `currentKicker` only tracks the LAST kicker.

Wait, the real attack is on `kickerAmount` overwrite in `lenderKick()`.
```solidity
        // Track the actual kicker
        currentBondAmount = bondAmount;
        kickerAmount[msg.sender] += bondAmount;
        currentKicker = msg.sender;
```
If multiple kicks happen, `currentKicker` is only ONE address. But `kickerAmount` accumulates.
However, in `settle()` and `take()`, they do:
`uint256 initialKickerAmount = kickerAmount[currentKicker];`
Then they add `extraAmount` to `kickerAmount[currentKicker]`.
But wait. What if `allowKick` is set to true by owner, then User A calls `lenderKick()`. Then `allowKick` is set to true AGAIN by owner. Then User B calls `lenderKick()`.
User B becomes `currentKicker`. The `pool` in Ajna only supports ONE kicker per borrower at a time!
If `allowKick` is true, the `require(allowKick)` passes. `pool.lenderKick` will REVERT if the borrower is already in an auction. So only one kicker is possible at a time.
Is there an issue with `kickerAmount` being left dangling if the pool auction is reset?
No.

Let's look at `claimBond()`.
```solidity
        uint256 bondAmount = kickerAmount[msg.sender];
        require(bondAmount > 0, "No bond to claim");
        // Reset kicker state
        kickerAmount[msg.sender] = 0;
        // Transfer bond to user
        require(IERC20(quoteToken).transfer(msg.sender, bondAmount), "Bond transfer failed");
        return bondAmount;
```
When a kicker kicks, they transfer `quoteToken` to the proxy.
When the auction settles, `settle()` does NOT transfer the `quoteToken` to the kicker. It just updates `kickerAmount[kicker] += extraAmount`.
The kicker must call `claimBond()` to get their `quoteToken`.
But what if the kicker calls `claimBond()` BEFORE `settle()`?
In `lenderKick()`:
`kickerAmount[msg.sender] += bondAmount;`
Can the kicker call `claimBond()` immediately?
YES! `claimBond()` has NO CHECKS to see if the auction is still active!
1. User calls `lenderKick()`. Transfers 100 USDC to proxy. `kickerAmount[User] = 100`.
2. User IMMEDIATELY calls `claimBond()`. Transfers 100 USDC from proxy back to User. `kickerAmount[User] = 0`.
3. The auction is now live in Ajna, and `LVLidoVault` mints `testQuoteToken` to back the kick.
4. When `settle()` happens, `kickerAmount[User]` is 0. If the bond grew, they just get the extra amount. If it slashed... wait, I just found in Finding 6 there's no slashing mechanism.
5. So the kicker kicked the auction FOR FREE! They got their bond back instantly from the proxy's balance (which holds their bond). Wait, if they are the only kicker, the proxy balance IS 100 USDC. They just take it back.
If there are other kickers' un-claimed funds in the proxy, they take their own 100 back.
Wait! If they take it back immediately, they are no longer exposed to slashing! AND they can still get the `extraAmount` if the bond grows, because `withdrawnAmount_ > 0` and `initialKickerAmount` is now `0`, so `withdrawnAmount_ - 0 = withdrawnAmount_`.
**THE KICKER GETS THEIR FULL BOND BACK IMMEDIATELY, AND THEN RECEIVES 100% OF THE WITHDRAWN TEST QUOTETOKENS AS REWARD, DOUBLE DIPPING!**

**Attack Path:**
1. Owner sets `allowKick = true`.
2. Attacker calls `lenderKick()`, transferring 100 quote tokens to proxy. `kickerAmount[Attacker] += 100`. `LVLidoVault` kicks Ajna.
3. Attacker immediately calls `claimBond()`. The proxy sends 100 quote tokens back to Attacker. `kickerAmount[Attacker] = 0`.
4. The auction resolves favorably. `withdrawnAmount_` (from Ajna) is 150.
5. `settle()` is called. `initialKickerAmount = kickerAmount[Attacker] = 0`.
6. `extraAmount = 150 - 0 = 150`.
7. `LVLidoVault` transfers 150 quote tokens to proxy. `kickerAmount[Attacker] += 150`.
8. Attacker calls `claimBond()` again, receiving 150 quote tokens.
Total spent: 0. Total gained: 150. The vault is drained of quote tokens to pay the attacker, and the attacker put up zero risk capital for the duration of the auction.
**Why It Works Mechanically:** `claimBond()` lacks any access control or state checks to ensure the auction the bond is attached to has actually settled. It simply refunds the user their tracked `kickerAmount`. Because `lenderKick()` immediately increases `kickerAmount`, it can be instantly withdrawn.
**Funds at Risk:** Direct theft of vault quote tokens and risk-free exploitation of the liquidation module.
**PoC Skeleton:**
```solidity
proxy.lenderKick();
proxy.claimBond(); // Instantly get bond back!
// Let auction settle successfully
proxy.settle(10);
proxy.claimBond(); // Claim 100% of the withdrawn bond value as "extra"
```
**Minimal Fix:**
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

## FINDING 8 — [LiquidationProxy.sol :: settle() and take() reentrancy]
**Severity:** High
**Dimension:** DIMENSION 9 — REENTRANCY (NON-OBVIOUS PATHS) / DIMENSION 5 — LIQUIDATION PROXY ATTACK SURFACE
**The Broken Assumption:** `settle()` uses `nonReentrant`, but `take()` does not! Furthermore, both functions perform a state change (`kickerAmount[kicker] += extraAmount`) AFTER making an external call to `LVLidoVault.transferForProxy()`, which transfers ERC20 tokens to the proxy. If `quoteToken` is an ERC-777 or a token with callbacks (like some bridged/upgradable tokens), it allows reentrancy.
**Attack Path:**
1. Since `take()` is NOT protected by `nonReentrant`, an attacker can initiate a `take()` to buy collateral.
2. If `take()` triggers the removal of the bond (`kickTime == 0`), it calculates `extraAmount = withdrawnAmount_ - initialKickerAmount;` and calls `LVLidoVault.transferForProxy(quoteToken, address(this), extraAmount)`.
3. If `quoteToken` has a callback mechanism (like `tokensReceived`), control is handed back to the attacker BEFORE `kickerAmount[currentKicker] += extraAmount` is executed, but AFTER the state variables `currentBondAmount = 0`, `currentKicker = address(0)`, and `allowKick = false` are set (Wait, actually these state variable resets happen AFTER the `if (withdrawnAmount_ > 0)` block!).
4. Wait, let's look at `take()`:
```solidity
            if (withdrawnAmount_ > 0) {
                // ...
                uint256 initialKickerAmount = kickerAmount[currentKicker];
                // Reset auction state
                if (withdrawnAmount_ > initialKickerAmount) {
                    uint256 extraAmount = withdrawnAmount_ - initialKickerAmount;
                    require(LVLidoVault.transferForProxy(quoteToken, address(this), extraAmount), "Transfer failure.");
                    kickerAmount[currentKicker] += extraAmount;
                }
            }
            currentBondAmount = 0;
            currentKicker = address(0);
            allowKick = false;
```
If `take()` is reentered during the `transferForProxy` callback (which transfers to `address(this)`, so the callback would be on the `LiquidationProxy` contract itself - wait. The proxy is receiving the token, not the attacker! So the attacker's callback wouldn't be triggered by `transferForProxy(quoteToken, address(this), extraAmount)` unless `quoteToken` calls sender or something, which is `LVLidoVault`.

Let's rethink reentrancy:
In `take()`:
```solidity
        require(
            LVLidoVault.transferForProxy(collateralToken, msg.sender, collateralTaken)
```
This transfers `collateralToken` to `msg.sender` (the attacker). If `collateralToken` has a callback (e.g. it's a token like `stETH` doesn't, but maybe wrapped or other tokens do, or the attacker is a smart contract that gets notified of ERC20 transfers if the token is ERC777).
If the attacker reenters `take()` here, they can repeatedly call `take()` while the auction is ongoing, before the state is updated or bond is withdrawn.
Because `take()` calls `pool.take()` which updates Ajna state, Ajna protects itself against reentrancy. So Ajna's state is updated.
Is there an internal state in `LiquidationProxy` that is out of sync?
No, `LiquidationProxy` mostly forwards to Ajna.

Let's look at another angle:
In `settle()`:
```solidity
        if (isBorrowerSettled) {
            // Store kicker info before resetting
            address kicker = currentKicker;
            uint256 bondAmount = currentBondAmount;

            // Reset kicker state
            currentKicker = address(0);
            currentBondAmount = 0;
            allowKick = false;
```
`settle()` has `nonReentrant`. So `settle()` is safe from reentrancy.

Let's go back to Dimension 5.
```solidity
        uint256 quoteTokenPayment = unwrap(quoteTokenPaymentUD60x18) + 1 wei;
        require(
            LVLidoVault.mintForProxy(address(testQuoteToken), address(this), quoteTokenPayment)
                && IERC20(address(testQuoteToken)).approve(address(pool), quoteTokenPayment),
            "Take failure."
        );
```
In `take()`, the proxy mints `testQuoteToken` to `address(this)`. Then approves the pool. Then calls `pool.take()`. Then transfers REAL `quoteToken` from `msg.sender` to `LVLidoVault`.
Then transfers REAL `collateralToken` from `LVLidoVault` to `msg.sender`.
Wait!
Does it burn the REAL collateral token from the vault? No, it transfers it to the taker!
Does it burn the TEST collateral token?
```solidity
        require(
            LVLidoVault.transferForProxy(collateralToken, msg.sender, collateralTaken)
                && LVLidoVault.burnForProxy(address(testCollateralToken), address(this), collateralTaken),
            "Transfer or burn failed."
        );
```
It burns `testCollateralToken` from `address(this)`. But wait!
Where did `address(this)` get the `testCollateralToken`?
`pool.take()` transfers the collateral token from the Ajna pool to the `address(this)` (the taker)!
Let's verify:
`uint256 collateralTaken = pool.take(address(LVLidoVault), collateralToPurchase, address(this), "");`
Yes! Ajna transfers the collateral (which is `testCollateralToken` because Ajna pool operates on test tokens) to `address(this)`.
Then the proxy burns the `testCollateralToken` from `address(this)`. AND transfers the REAL `collateralToken` from `LVLidoVault` to `msg.sender`.
And what about the quote token payment?
Proxy mints `testQuoteToken` to `address(this)`. Ajna `take()` pulls `testQuoteToken` from `address(this)`.
Then proxy pulls REAL `quoteToken` from `msg.sender` to `LVLidoVault`.

Wait, what if `transferAmount` (the amount of REAL quote token pulled from taker) is WRONG?
```solidity
        // Calculate transfer amount using PRBMath
        UD60x18 collateralTakenAmount = wrap(collateralTaken);
        UD60x18 transferAmountUD60x18 = mul(collateralTakenAmount, price);
        uint256 transferAmount = unwrap(transferAmountUD60x18);
```
`transferAmount` is calculated by doing `collateralTaken * auctionPrice`.
But `quoteTokenPayment` (the amount of testQuoteToken minted) was calculated as:
```solidity
        UD60x18 collateralAmount = wrap(collateralToPurchase);
        UD60x18 quoteTokenPaymentUD60x18 = mul(collateralAmount, price);
        uint256 quoteTokenPayment = unwrap(quoteTokenPaymentUD60x18) + 1 wei;
```
If `collateralTaken < collateralToPurchase` (which happens if the auction didn't have enough collateral to satisfy the full `collateralToPurchase`), `quoteTokenPayment` was minted based on `collateralToPurchase`.
So the proxy minted `quoteTokenPayment` (based on `collateralToPurchase`) to `address(this)`.
But Ajna's `pool.take()` only pulled the amount required for `collateralTaken`!
What happens to the excess `testQuoteToken` minted to `address(this)`?
IT STAYS IN THE PROXY FOREVER. IT IS NEVER BURNED!
Let's trace carefully:
1. Taker calls `take(100)`. `auctionPrice` is 2.
2. `quoteTokenPayment = 100 * 2 + 1 = 201`.
3. Proxy mints 201 `testQuoteToken` to itself.
4. Proxy approves Ajna for 201.
5. Proxy calls `pool.take(vault, 100)`.
6. Turns out the borrower only had 50 collateral left. Ajna takes 50 collateral, pulls `50 * 2 = 100` `testQuoteToken` from Proxy.
7. Proxy receives 50 `testCollateralToken` from Ajna.
8. Proxy transfers 50 `collateralToken` from Vault to Taker.
9. Proxy burns 50 `testCollateralToken`.
10. Proxy calculates `transferAmount = 50 * 2 = 100`. Pulls 100 `quoteToken` from Taker.

But Proxy minted 201 `testQuoteToken` to itself! 101 `testQuoteToken` are left sitting in the Proxy.
Is this an issue?
Yes! The Vault's internal accounting of `testQuoteToken` will be completely disconnected from the actual real `quoteToken` it received! The proxy basically printed unbacked test tokens! If those test tokens can be used, they cause insolvency.
Wait, the `testQuoteToken` is just an internal token. But wait, `LVLidoVault.mintForProxy` literally mints `testQuoteToken`!
If `testQuoteToken` is minted excessively, does it matter?
Yes, because `LVLidoVault` is supposed to keep `testQuoteToken` supply == `quoteToken` balance, or similar? No, the `testQuoteToken` is used in Ajna pool. If it's inflated, it doesn't directly hurt unless the proxy can use it. The proxy doesn't use the leftovers. But wait...

Let's look at `collateralTaken`.
If `collateralTaken < collateralToPurchase`, the proxy takes REAL `quoteToken` from Taker based on `collateralTaken`.
Wait, who is paying the REAL quote token?
The Taker. The Taker pays 100 real quote tokens to the Vault.
The Vault minted 201 test quote tokens. 101 test quote tokens are stuck in Proxy.
The Vault holds 100 real quote tokens.
The Vault LOST 50 real collateral tokens (sent to Taker).
So the Vault traded 50 collateral for 100 quote tokens. That's correct.
The test tokens are just out of sync. Since they only exist for Ajna, they don't hold real value UNLESS they can be redeemed.
Can someone redeem test tokens?
No, the proxy doesn't have a function to send test tokens anywhere else.

Let's look at another part of `take()`:
```solidity
        uint256 quoteTokenPayment = unwrap(quoteTokenPaymentUD60x18) + 1 wei;
        require(
            LVLidoVault.mintForProxy(address(testQuoteToken), address(this), quoteTokenPayment)
                && IERC20(address(testQuoteToken)).approve(address(pool), quoteTokenPayment),
            "Take failure."
        );
```
Wait! What if `auctionPrice` changes?
The proxy gets `auctionPrice` from `auctionStatus()`.
```solidity
        (,, uint256 debtToCover,, uint256 auctionPrice,,,,) = auctionStatus();
```
Ajna's `pool.take()` doesn't take a `maxPrice` argument here, it takes an empty bytes string:
`uint256 collateralTaken = pool.take(address(LVLidoVault), collateralToPurchase, address(this), "");`
Wait, does Ajna's `take` recalculate price internally? Yes, `take()` might settle at a slightly different price if time elapsed or if it sweeps multiple buckets, BUT Ajna's `take` function signature is:
`take(address borrowerAddress, uint256 maxCollateral, address callee, bytes calldata data)`
Actually, Ajna's `take` DOES NOT guarantee the price! If the transaction sits in the mempool, the `auctionPrice` keeps dropping!
Wait, if the price drops, `auctionPrice` decreases.
When the transaction executes:
`auctionPrice` is fetched dynamically!
But `quoteTokenPayment` is calculated based on `auctionPrice` at execution time.
Is there slippage protection?
NO! `take(uint256 collateralToPurchase)` has NO `maxPrice` or `minCollateral` slippage protection.
Wait, if `collateralToPurchase` is the exact amount to purchase, and `transferAmount` is calculated using `auctionPrice` AT EXECUTION TIME, what happens if an attacker front-runs and pushes the price? (In Ajna, price strictly DECREASES over time, it doesn't go up).
Actually, the attacker could just specify `collateralToPurchase` and they will pay `collateralToPurchase * auctionPrice` at execution block. If price dropped, they pay less. That's fine.

Let's look at `collateralTaken`.
What if `LVLidoVault` doesn't have enough REAL `collateralToken` to pay the taker?
If `take()` succeeds, it pulls REAL `collateralToken` from `LVLidoVault`. If it fails, the transaction reverts. This is fine.

Let's look at:
```solidity
                if (withdrawnAmount_ > initialKickerAmount) {
                    // Kicker bond grew
                    uint256 extraAmount = withdrawnAmount_ - initialKickerAmount;
                    require(LVLidoVault.transferForProxy(quoteToken, address(this), extraAmount), "Transfer failure.");
                    kickerAmount[currentKicker] += extraAmount;
                }
```
If `withdrawnAmount_` grows, the PROXY receives `extraAmount` of REAL `quoteToken` from the VAULT.
Where did the Vault get this extra quote token?
The Vault didn't get any extra quote token! The bond growth in Ajna means the `testQuoteToken` bond grew (because Ajna paid the kicker in `testQuoteToken` from the borrower's collateral converted to quote token).
So Ajna gives `testQuoteToken` to the kicker.
The Proxy burns the `testQuoteToken`:
`LVLidoVault.burnForProxy(address(testQuoteToken), address(LVLidoVault), withdrawnAmount_)`
So the Vault burns the `testQuoteToken`.
And then the Proxy forces the Vault to transfer REAL `quoteToken` to the Proxy to pay the kicker!
`LVLidoVault.transferForProxy(quoteToken, address(this), extraAmount)`
Is the Vault guaranteed to have this REAL `quoteToken` lying around?
Yes, the Vault holds the user's deposits!
So the Vault pays the kicker's reward out of the VAULT'S OWN REAL QUOTE TOKENS!
But wait! Did the Vault actually receive any real quote tokens to compensate for this?
When the kicker bond grows, it means the borrower's debt was covered and the kicker earned a penalty fee. That penalty fee was minted to the borrower in Ajna as debt, or paid from the collateral!
But the Vault NEVER synchronized this gain to its real `quoteToken` balance! The Vault only burned the `testQuoteToken`. So the Vault is effectively subsidizing the kicker's reward out of its own reserves!
This means the protocol bleeds real quote tokens to pay kickers, while the test quote tokens that represented the profit are simply burned!

Wait, is this intended?
Let's check `settle()`.
```solidity
            uint256 withdrawnAmount_ = LVLidoVault.withdrawBondsForProxy();
            if (withdrawnAmount_ > 0) {
                // Unwrap tokens as needed and transfer the bond reward to the kicker.
                require(
                    LVLidoVault.burnForProxy(address(testQuoteToken), address(LVLidoVault), withdrawnAmount_),
                    "Burn failed."
                );
                uint256 initialKickerAmount = kickerAmount[kicker];
                // Reset auction state
                if (withdrawnAmount_ > initialKickerAmount) {
                    // Kicker bond grew
                    uint256 extraAmount = withdrawnAmount_ - initialKickerAmount;
                    require(LVLidoVault.transferForProxy(quoteToken, address(this), extraAmount), "Transfer failure.");
                    kickerAmount[kicker] += extraAmount;
                }
            }
```
Yes! The Vault burns `withdrawnAmount_` of `testQuoteToken`. Then it pays `extraAmount` of REAL `quoteToken` to the proxy!
This is a direct loss for the Vault! The Vault burns a test token (which costs it nothing), but gives away a REAL token to the kicker.
Is there any mechanism where the Vault converts the `testQuoteToken` to real `quoteToken`? No! The test token is burned!
Wait, if the test token is burned, it means the Vault is reducing its test token liabilities. But the Vault is also giving away real quote tokens!
Who profits? The kicker!
Who pays? The Vault's depositors!
This means the liquidation module is entirely subsidized by depositors.

Wait, look at `Finding 7`. I already found a direct theft in `claimBond()`.
Let's find another issue in `LVToken.sol` or `VaultLib.sol`.








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
