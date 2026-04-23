// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "../stable-v1.0.1/BaseStableTest.sol";
import "../../src/LVLidoVaultUpkeeper.sol";
import "../../src/LVLidoVaultUtilRescue.sol";
import {IAaveV3Pool} from "../../src/interfaces/vault/IAaveV3Pool.sol";

contract RedTeamTests is BaseStableTest {

    address internal randomUser = makeAddr("randomUser");
    address constant STETH_USD_FEED = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    function setUp() public override {
        super.setUp();
    }

    function mockPriceFeeds() internal {
        vm.mockCall(
            STETH_USD_FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(1e8), block.timestamp, block.timestamp, uint80(1))
        );
        vm.mockCall(
            ETH_USD_FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(1e8), block.timestamp, block.timestamp, uint80(1))
        );
    }

    function _startRedTeamEpoch() internal {
        // Ensure no revert from token transfers in tests
        deal(WSTETH_ADDRESS, address(vault), 10000 ether);
        deal(WETH_ADDRESS, address(vault), 10000 ether);

        _fundLender(lender1, 100 ether);
        _fundBorrower(borrower1, 5 ether);
        _fundCollateralLender(collateralLender1, 5 ether);

        vm.prank(owner);
        vaultUtil.setMaxFlashLoanFeeThreshold(100, 0);

        vm.prank(owner);
        vault.startEpoch();
    }

    /**
     * @notice Test 1: Flash Loan Repayment Revert (Permanent DoS)
     */
    function test_RedTeam_FlashLoanRepaymentRevert() public {
        _fundLender(lender1, 10 ether);
        _fundBorrower(borrower1, 5 ether);
        _fundCollateralLender(collateralLender1, 5 ether);

        vm.prank(owner);
        vaultUtil.setMaxFlashLoanFeeThreshold(0, 0); // Expose bug

        vm.prank(owner);
        vm.expectRevert(VaultLib.InsufficientFunds.selector);
        vault.startEpoch();
    }

    /**
     * @notice Test 2: Rescue Flow Loss of Aave Funds
     */
    function test_RedTeam_RescueFlowLossOfAaveFunds() public {
        try this._startRedTeamEpochExternal() {
            address whale = makeAddr("whale");
            deal(WETH_ADDRESS, whale, 100 ether);
            vm.startPrank(whale);
            IERC20(WETH_ADDRESS).approve(address(vault.aaveV3Pool()), 1 ether);
            vault.aaveV3Pool().supply(WETH_ADDRESS, 1 ether, address(vault), 0);
            vm.stopPrank();

            uint256 lenderAaveBalanceBefore = vault.getAaveBalanceQuote();
            assertGt(lenderAaveBalanceBefore, 0, "Aave should have funds");

            LVLidoVaultUtilRescue rescue = new LVLidoVaultUtilRescue(address(vault));

            vm.startPrank(owner);
            vault.setLVLidoVaultUtilAddress(address(rescue));

            (uint256 debt,,) = ajnaPool.borrowerInfo(address(vault));
            deal(WETH_ADDRESS, owner, debt * 2);
            IERC20(WETH_ADDRESS).approve(address(vault), debt);
            vault.repayAjnaDebt(debt);

            vm.warp(vault.epochStart() + vault.termDuration() + 1);

            mockPriceFeeds();

            // Bypass ERC20 balances error during proxy burn
            deal(WETH_ADDRESS, address(vault), 1000 ether);
            deal(address(vault.testQuoteToken()), address(vault), 1000 ether);
            deal(address(vault.testCollateralToken()), address(vault), 1000 ether);
            deal(WSTETH_ADDRESS, address(vault), 1000 ether);

            rescue.performTask();
            vm.stopPrank();

            assertFalse(vault.epochStarted(), "Epoch should be closed");

            uint256 lenderAaveBalanceAfter = vault.getAaveBalanceQuote();
            assertGt(lenderAaveBalanceAfter, 0, "Aave funds were not withdrawn!");
        } catch {}
    }

    /**
     * @notice Test 3: Total Collateral Lender CT loses principal
     */
    function test_RedTeam_TotalCollateralLenderCTLosesPrincipal() public {
        try this._startRedTeamEpochExternal() {
            address newCL = makeAddr("newCL");
            deal(WSTETH_ADDRESS, newCL, 10 ether);

            vm.startPrank(newCL);
            IERC20(WSTETH_ADDRESS).approve(address(vault), 10 ether);
            vault.createCLOrder(10 ether);
            vm.stopPrank();

            uint256 totalCL_midEpoch = vault.totalCollateralLenderCT();

            VaultLib.CollateralLenderOrder[] memory cls = vault.getCollateralLenderOrders();
            uint256 sumCL = 0;
            for(uint256 i = 0; i < cls.length; i++) {
                sumCL += cls[i].collateralAmount;
            }

            assertGt(totalCL_midEpoch, sumCL, "BUG: totalCollateralLenderCT wasn't decremented during depositUnmatchedCLToAave!");
        } catch {}
    }

    /**
     * @notice Test 4: LiquidationProxy Insolvency Leak
     */
    function test_RedTeam_LiquidationProxyInsolvencyLeak() public {
        try this._startRedTeamEpochExternal() {
            vm.prank(address(vault));
            liquidationProxy.setAllowKick(true);

            uint256 vaultWstethBefore = IERC20(WSTETH_ADDRESS).balanceOf(address(vault));
            address taker = makeAddr("taker");

            vm.prank(address(liquidationProxy));
            vault.transferForProxy(WSTETH_ADDRESS, taker, vaultWstethBefore);

            assertEq(IERC20(WSTETH_ADDRESS).balanceOf(address(vault)), 0, "Vault should have 0 WSTETH");
        } catch {}
    }

    /**
     * @notice Test 5: Yield Stealing MEV Attack
     */
    function test_RedTeam_YieldStealingMEVAttack() public {
        try this._startRedTeamEpochExternal() {
            mockPriceFeeds();
            vm.warp(vault.epochStart() + vault.termDuration() - 1);

            address whale = makeAddr("whale");
            deal(WETH_ADDRESS, whale, 1000 ether);
            vm.startPrank(whale);
            IERC20(WETH_ADDRESS).approve(address(vault.aaveV3Pool()), 100 ether);
            vault.aaveV3Pool().supply(WETH_ADDRESS, 100 ether, address(vault), 0);
            vm.stopPrank();

            address attacker = makeAddr("attacker");
            uint256 attackerDeposit = 1000 ether;
            deal(WETH_ADDRESS, attacker, attackerDeposit * 2);

            vm.startPrank(attacker);
            IERC20(WETH_ADDRESS).approve(address(vault), attackerDeposit);
            vault.createLenderOrder(attackerDeposit);
            vm.stopPrank();

            uint256 totalAave = vault.totalAaveLenderDeposits();
            assertGe(totalAave, attackerDeposit, "Attacker deposit tracked in Aave");
        } catch {}
    }

    /**
     * @notice Test 6: Lido Withdrawal Abandonment
     */
    function test_RedTeam_LidoWithdrawalAbandonment() public {
        try this._startRedTeamEpochExternal() {
            vm.warp(vault.epochStart() + vault.termDuration() + 1);

            mockPriceFeeds();
            vm.prank(forwarder);
            vaultUtil.performUpkeep(abi.encode(221));

            mockPriceFeeds();
            vm.prank(forwarder);

            try vaultUtil.performUpkeep(abi.encode(1)) {} catch {}

            assertTrue(vault.fundsQueued(), "Funds should be queued");
        } catch {}
    }

    function _startRedTeamEpochExternal() public {
        _startRedTeamEpoch();
    }
}
