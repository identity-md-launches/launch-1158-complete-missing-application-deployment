// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {FeeTreasury} from "../src/FeeTreasury.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {Arena} from "../src/Arena.sol";
import {PrismRiotToken} from "../src/PrismRiotToken.sol";
import {TwoStepOwned} from "../src/TwoStepOwned.sol";

contract RejectsEth {
    receive() external payable {
        revert("no");
    }
}

/// @dev Treasury failure paths: zero allocation, a reserve above a lowered target, a recipient that rejects
/// ETH, purchases without the funder role, the IMD venue flow on a second pool, slippage, caller guards,
/// ownership, and the configuration order.
/// forge-config: default.fuzz.runs = 512
contract FeeTreasuryEdgeTest is Fixture {
    StakingVault vault;
    Arena arena;
    PrismRiotToken imd;
    address executor = makeAddr("executor");
    address adapterAddr = makeAddr("adapter");

    receive() external payable {}

    function setUp() public {
        deployLaunch(true);
        seedLiquidity(10_000 ether, true);
        vm.deal(trader, 10_000 ether);
        vault = new StakingVault(owner, address(token));
        arena = new Arena(owner, address(token));
        vm.startPrank(owner);
        vault.setRewardFunder(address(treasury));
        treasury.setSinks(address(vault), address(arena), adapterAddr);
        treasury.setExecutor(executor);
        // Both pools open at 1:1; 0.9 tokens per ETH is a floor every bounded purchase here clears.
        treasury.setPriceFloors(0.9e18, 0.9e18);
        vm.stopPrank();
    }

    /// @dev A treasury with the hook, PRIO and executor configured but nothing else: the state right after
    /// deployment, before sinks and floors exist.
    function freshTreasury() internal returns (FeeTreasury fresh) {
        fresh = new FeeTreasury(manager, owner);
        vm.startPrank(owner);
        fresh.bindHook(address(hook));
        fresh.setPrio(address(token));
        fresh.setExecutor(executor);
        vm.stopPrank();
    }

    function earn(uint256 ethIn) internal {
        swap(trader, true, -int256(ethIn), ethIn);
    }

    function bucketsEqualBalance() internal view {
        assertEq(
            address(treasury).balance,
            treasury.unallocated() + treasury.reserve() + treasury.imdBudget() + treasury.prioBudget()
                + treasury.ownerBudget()
        );
    }

    // ------------------------------------------------------------------ allocation

    function test_allocateWithNothingIsANoOp() public {
        treasury.allocate();
        assertEq(treasury.reserve(), 0);
        assertEq(treasury.ownerBudget(), 0);
        bucketsEqualBalance();
    }

    function test_allocateIsIdempotentUntilNewIncome() public {
        earn(10 ether);
        treasury.allocate();
        uint256 r = treasury.reserve();
        uint256 o = treasury.ownerBudget();
        treasury.allocate();
        assertEq(treasury.reserve(), r);
        assertEq(treasury.ownerBudget(), o);
        bucketsEqualBalance();
    }

    /// @dev Lowering the target below the reserve stops replenishment; nothing is clawed back.
    function test_reserveAboveLoweredTargetGetsNothingMore() public {
        earn(100 ether);
        treasury.allocate();
        uint256 reserve = treasury.reserve();
        assertGt(reserve, 0.01 ether);
        vm.prank(owner);
        treasury.setReserveTarget(0.01 ether);
        earn(100 ether);
        uint256 income = treasury.unallocated();
        treasury.allocate();
        assertEq(treasury.reserve(), reserve, "no more to the reserve");
        assertEq(
            treasury.imdBudget() + treasury.prioBudget() + treasury.ownerBudget(),
            address(treasury).balance - reserve,
            "the whole new allocation went to the three budgets"
        );
        income;
        bucketsEqualBalance();
    }

    /// @dev For any income and target, the reserve never takes more than 10% of an allocation and never
    /// passes the target, and the remainder splits exactly 30/30/40 with nothing lost.
    function testFuzz_allocationArithmetic(uint96 ethIn, uint256 target) public {
        uint256 amountIn = bound(ethIn, 1e9, 500 ether);
        target = bound(target, 0, 2 ether);
        vm.prank(owner);
        treasury.setReserveTarget(target);
        earn(amountIn);
        uint256 income = treasury.unallocated();
        treasury.allocate();
        uint256 toReserve = treasury.reserve();
        assertLe(toReserve, income / 10);
        assertLe(toReserve, target);
        uint256 rest = income - toReserve;
        assertEq(treasury.imdBudget(), rest * 3 / 10);
        assertEq(treasury.prioBudget(), rest * 3 / 10);
        assertEq(treasury.ownerBudget(), rest - rest * 3 / 10 - rest * 3 / 10);
        assertGe(treasury.ownerBudget() * 10, rest * 4 - 20, "owner share is 40% up to rounding");
        bucketsEqualBalance();
    }

    // ------------------------------------------------------------------ withdrawals

    function test_withdrawToRejectingRecipientRevertsAndKeepsBudget() public {
        earn(10 ether);
        treasury.allocate();
        uint256 budget = treasury.ownerBudget();
        address payable bad = payable(address(new RejectsEth()));
        vm.prank(owner);
        vm.expectRevert(FeeTreasury.TransferFailed.selector);
        treasury.withdrawOwner(bad, budget);
        assertEq(treasury.ownerBudget(), budget);
        vm.prank(executor);
        vm.expectRevert(FeeTreasury.WrongDestination.selector);
        treasury.withdrawReserve(bad, 1);
        vm.prank(owner);
        vm.expectRevert(FeeTreasury.TransferFailed.selector);
        treasury.withdrawReserve(bad, 1);
        bucketsEqualBalance();
    }

    function test_executorCannotTakeOwnerBudget_ownerCannotExceedReserve() public {
        earn(10 ether);
        treasury.allocate();
        address payable sink = payable(makeAddr("sink"));
        vm.prank(executor);
        vm.expectRevert();
        treasury.withdrawOwner(sink, 1);
        uint256 reserve = treasury.reserve();
        vm.prank(owner);
        vm.expectRevert(FeeTreasury.ExceedsBudget.selector);
        treasury.withdrawReserve(sink, reserve + 1);
        vm.prank(owner);
        treasury.withdrawReserve(sink, reserve);
        assertEq(treasury.reserve(), 0);
        bucketsEqualBalance();
    }

    function test_withdrawZeroIsHarmless() public {
        address payable sink = payable(makeAddr("sink"));
        vm.prank(owner);
        treasury.withdrawOwner(sink, 0);
        vm.prank(executor);
        treasury.withdrawReserve(payable(executor), 0);
        assertEq(sink.balance, 0);
        assertEq(executor.balance, 0);
    }

    // ------------------------------------------------------------------ purchases

    function test_buyPrioFailsWithoutFunderRoleAndRollsBack() public {
        earn(100 ether);
        treasury.allocate();
        vm.prank(owner);
        vault.setRewardFunder(address(0));
        uint256 budget = treasury.prioBudget();
        vm.prank(executor);
        vm.expectRevert(StakingVault.NotFunder.selector);
        treasury.buyPrio(0.05 ether, 1);
        assertEq(treasury.prioBudget(), budget, "a failed buy spends nothing");
        bucketsEqualBalance();
    }

    function test_buyPrioRefusesZeroAndUnsetSinks() public {
        earn(100 ether);
        treasury.allocate();
        vm.prank(executor);
        vm.expectRevert(FeeTreasury.ExceedsBudget.selector);
        treasury.buyPrio(0, 0);
        // Sinks are one-shot, so the unconfigured state only exists on a fresh treasury.
        FeeTreasury fresh = freshTreasury();
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(FeeTreasury.NotConfigured.selector, "sinks"));
        fresh.buyPrio(0.1 ether, 0);
        // The order of refusals: sinks, then the price floor, then the budget.
        vm.prank(owner);
        fresh.setSinks(address(vault), address(arena), adapterAddr);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(FeeTreasury.NotConfigured.selector, "prio price floor"));
        fresh.buyPrio(0.1 ether, 0);
        vm.prank(owner);
        fresh.setPriceFloors(1, 0);
        vm.prank(executor);
        vm.expectRevert(FeeTreasury.ExceedsBudget.selector);
        fresh.buyPrio(0.1 ether, 0);
    }

    // ------------------------------------------------------------------ price floors and the rolling window

    /// @dev The floor is checked on the ETH actually spent: a floor exactly at the realised price passes, one
    /// wei per ETH above it refuses, whatever `minOut` the executor passes (zero here).
    function test_priceFloorBoundaryIsExactOnTheSpentLeg() public {
        earn(400 ether); // 2 ETH of fees: 0.2 reserve, 0.54 ETH on the PRIO line
        treasury.allocate();
        uint256 snap = vm.snapshotState();
        vm.prank(executor);
        uint256 out = treasury.buyPrio(0.5 ether, 0);
        vm.revertToState(snap);
        // out == spent * floor / 1e18  <=> floor == out * 1e18 / spent (rounded down passes, +1 refuses).
        uint256 spent = 0.5 ether;
        uint256 exact = (out * 1e18) / spent;
        vm.prank(owner);
        treasury.setPriceFloors(exact, 1);
        vm.prank(executor);
        assertEq(treasury.buyPrio(0.5 ether, 0), out, "same pool state, same output");
        vm.revertToState(snap);
        // The floor is scaled by the spent ETH with floor division, so the smallest refusing floor is the
        // first one whose scaled requirement exceeds `out` by a wei.
        uint256 refusing = exact + 1;
        while ((spent * refusing) / 1e18 <= out) refusing++;
        vm.prank(owner);
        treasury.setPriceFloors(refusing, 1);
        uint256 budget = treasury.prioBudget();
        vm.prank(executor);
        vm.expectRevert(FeeTreasury.Slippage.selector);
        treasury.buyPrio(0.5 ether, 0);
        assertEq(treasury.prioBudget(), budget, "a refused buy spends nothing");
        bucketsEqualBalance();
    }

    /// @dev The window is a hard cap on the sum of purchases: exactly the cap passes, one wei more refuses,
    /// and the counter resets only once a full SPEND_WINDOW has elapsed since the window opened.
    function test_rollingWindowBoundaries() public {
        earn(2_000 ether); // 10 ETH of fees: 0.5 reserve (the target), 2.85 ETH on the PRIO line
        treasury.allocate();
        vm.startPrank(owner);
        treasury.setMaxSpendPerSwap(10 ether);
        treasury.setSpendPerWindow(1 ether);
        treasury.setPriceFloors(1, 1); // the big buy moved the price; the window is what is under test here
        vm.stopPrank();
        vm.startPrank(executor);
        treasury.buyPrio(0.6 ether, 0);
        vm.expectRevert(FeeTreasury.ExceedsWindow.selector);
        treasury.buyPrio(0.4 ether + 1, 0);
        treasury.buyPrio(0.4 ether, 0);
        assertEq(treasury.spentInWindow(), 1 ether);
        vm.expectRevert(FeeTreasury.ExceedsWindow.selector);
        treasury.buyPrio(1, 0);
        // One second short of the window: still capped. At the window: fresh counter.
        uint256 start = treasury.windowStart();
        vm.warp(start + treasury.SPEND_WINDOW() - 1);
        vm.expectRevert(FeeTreasury.ExceedsWindow.selector);
        treasury.buyPrio(1, 0);
        vm.warp(start + treasury.SPEND_WINDOW());
        treasury.buyPrio(1 ether, 0);
        assertEq(treasury.windowStart(), start + treasury.SPEND_WINDOW());
        assertEq(treasury.spentInWindow(), 1 ether);
        vm.stopPrank();
        bucketsEqualBalance();
    }

    /// @dev Zero floors unset the price check again: refusing is the safe default and must come back.
    function test_zeroFloorDisablesPurchasesAgain() public {
        earn(100 ether);
        treasury.allocate();
        vm.prank(owner);
        treasury.setPriceFloors(0, 0.9e18);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(FeeTreasury.NotConfigured.selector, "prio price floor"));
        treasury.buyPrio(0.1 ether, 0);
    }

    function test_buyPrioOnUnboundTreasuryRefused() public {
        FeeTreasury fresh = new FeeTreasury(manager, owner);
        vm.prank(owner);
        fresh.setExecutor(executor);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(FeeTreasury.NotConfigured.selector, "prio"));
        fresh.buyPrio(1, 0);
    }

    /// @dev Repeated purchases drain the PRIO budget to zero but never past it; ETH buckets stay exact.
    function testFuzz_repeatedBuysNeverOverspend(uint8 n) public {
        n = uint8(bound(n, 1, 8));
        earn(200 ether);
        treasury.allocate();
        uint256 budget = treasury.prioBudget();
        uint256 spent;
        for (uint256 i; i < n; i++) {
            uint256 left = treasury.prioBudget();
            if (left == 0) break;
            uint256 amount = left / 2 + 1 > treasury.maxSpendPerSwap() ? treasury.maxSpendPerSwap() : left / 2 + 1;
            if (amount > left) amount = left;
            vm.prank(executor);
            treasury.buyPrio(amount, 1);
            spent += amount;
            bucketsEqualBalance();
        }
        assertEq(treasury.prioBudget() + spent, budget);
        assertEq(token.balanceOf(address(treasury)), 0);
    }

    // ------------------------------------------------------------------ IMD venue

    function setUpImdPool() internal returns (PoolKey memory imdKey) {
        imd = new PrismRiotToken();
        imdKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(imd)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(imdKey, SQRT_PRICE_1_1);
        imd.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 1_000 ether);
        lpRouter.modifyLiquidity{value: 200 ether}(
            imdKey,
            ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 100 ether, bytes32(0)),
            ""
        );
    }

    function test_setImdPoolRequiresImdFirst_thenBuyImdDeliversToAdapter() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FeeTreasury.NotConfigured.selector, "imd"));
        treasury.setImdPool(3000, 60, address(0));
        PoolKey memory imdKey = setUpImdPool();
        vm.startPrank(owner);
        treasury.setImd(address(imd));
        treasury.setImdPool(3000, 60, address(0));
        vm.stopPrank();
        assertTrue(treasury.imdPoolSet());
        assertEq(Currency.unwrap(treasury.imdPoolKey().currency1), address(imd));
        imdKey;

        earn(100 ether);
        treasury.allocate();
        uint256 budget = treasury.imdBudget();
        vm.prank(executor);
        vm.expectRevert(FeeTreasury.Slippage.selector);
        treasury.buyImd(0.1 ether, type(uint256).max);
        vm.prank(executor);
        uint256 out = treasury.buyImd(0.1 ether, 1);
        assertGt(out, 0);
        assertEq(imd.balanceOf(adapterAddr), out, "IMD lands in the oracle adapter");
        assertEq(treasury.imdBudget(), budget - 0.1 ether);
        assertEq(imd.balanceOf(address(treasury)), 0);
        bucketsEqualBalance();
        // Guards.
        vm.prank(trader);
        vm.expectRevert(FeeTreasury.NotExecutor.selector);
        treasury.buyImd(0.1 ether, 0);
        vm.prank(owner);
        treasury.setMaxSpendPerSwap(0.01 ether);
        vm.prank(executor);
        vm.expectRevert(FeeTreasury.ExceedsMaxSpend.selector);
        treasury.buyImd(0.01 ether + 1, 0);
        vm.prank(owner);
        treasury.setMaxSpendPerSwap(1 ether);
        uint256 imdBudget = treasury.imdBudget();
        vm.prank(executor);
        vm.expectRevert(FeeTreasury.ExceedsBudget.selector);
        treasury.buyImd(imdBudget + 1, 0);
        // A fresh treasury with the IMD pool but no sinks: refused for the missing adapter, not for the floor.
        FeeTreasury fresh = freshTreasury();
        vm.startPrank(owner);
        fresh.setImd(address(imd));
        fresh.setImdPool(3000, 60, address(0));
        vm.stopPrank();
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(FeeTreasury.NotConfigured.selector, "oracle adapter"));
        fresh.buyImd(0.1 ether, 0);
        vm.prank(owner);
        fresh.setSinks(address(vault), address(arena), adapterAddr);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(FeeTreasury.NotConfigured.selector, "imd price floor"));
        fresh.buyImd(0.1 ether, 0);
        // After the first IMD purchase the IMD token and the adapter sink are frozen (finding d6110259);
        // the vault and the arena are not, since no PRIO was bought here; the venue stays movable.
        assertTrue(treasury.imdPurchased());
        assertFalse(treasury.prioPurchased());
        vm.startPrank(owner);
        vm.expectRevert(FeeTreasury.AlreadySet.selector);
        treasury.setImd(address(token));
        vm.expectRevert(FeeTreasury.AlreadySet.selector);
        treasury.setSinks(address(vault), address(arena), makeAddr("otherAdapter"));
        treasury.setSinks(address(arena), address(vault), adapterAddr); // PRIO sinks still correctable
        treasury.setSinks(address(vault), address(arena), adapterAddr);
        treasury.setImdPool(3000, 60, address(0));
        vm.stopPrank();
        // Changing the IMD token after the pool was set drops the pool: the next buy must wait for a new key.
        vm.startPrank(owner);
        fresh.setImd(address(token));
        vm.stopPrank();
        assertFalse(fresh.imdPoolSet());
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(FeeTreasury.NotConfigured.selector, "imd pool"));
        fresh.buyImd(0.1 ether, 0);
    }

    /// @dev Finding 95221d55: a swap against a pool with nothing to sell below the current price fills
    /// nothing (spent 0, out 0) without reverting in the PoolManager, and used to count as a purchase: it
    /// froze PRIO and the sinks, emitted `ImdBought(0, 0)` and parked the pool at the price limit. A zero
    /// fill now reverts `NoFill` and changes nothing.
    function test_zeroFillIsNotAPurchase() public {
        setUpImdPool(); // deploys `imd` and a 3000/60 pool with liquidity, not used here
        PoolKey memory emptyKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(imd)),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
        manager.initialize(emptyKey, SQRT_PRICE_1_1); // initialized, no liquidity at all
        vm.startPrank(owner);
        treasury.setImd(address(imd));
        treasury.setImdPool(10_000, 200, address(0));
        vm.stopPrank();
        earn(100 ether);
        treasury.allocate();
        uint256 budget = treasury.imdBudget();
        uint256 window = treasury.spentInWindow();
        vm.prank(executor);
        vm.expectRevert(FeeTreasury.NoFill.selector);
        treasury.buyImd(0.1 ether, 0);
        assertFalse(treasury.purchased(), "a zero fill must not freeze PRIO and the sinks");
        assertEq(treasury.imdBudget(), budget);
        assertEq(treasury.spentInWindow(), window);
        assertEq(imd.balanceOf(adapterAddr), 0);
        bucketsEqualBalance();
        // The pool was not parked at the limit: the same call on the pool with liquidity fills normally.
        vm.prank(owner);
        treasury.setImdPool(3000, 60, address(0));
        vm.prank(executor);
        assertGt(treasury.buyImd(0.1 ether, 1), 0);
        assertTrue(treasury.imdPurchased());
    }

    // ------------------------------------------------------------------ guards and ownership

    function test_unlockCallbackOnlyFromManager() public {
        vm.expectRevert(FeeTreasury.NotPoolManager.selector);
        treasury.unlockCallback(abi.encode(key, uint256(1)));
    }

    function test_configurationIsOwnerOnlyAndOneShotWhereStated() public {
        vm.startPrank(trader);
        vm.expectRevert();
        treasury.bindHook(trader);
        vm.expectRevert();
        treasury.setPrio(trader);
        vm.expectRevert();
        treasury.setImd(trader);
        vm.expectRevert();
        treasury.setSinks(trader, trader, trader);
        vm.expectRevert();
        treasury.setExecutor(trader);
        vm.expectRevert();
        treasury.setReserveTarget(1);
        vm.expectRevert();
        treasury.setMaxSpendPerSwap(1);
        vm.stopPrank();
        // Before any income or purchase the bindings are correctable (finding 0cd78a87)...
        vm.startPrank(owner);
        treasury.bindHook(trader);
        treasury.bindHook(address(hook));
        treasury.setPrio(trader);
        treasury.setPrio(address(token));
        vm.expectRevert(FeeTreasury.ZeroAddress.selector);
        treasury.setImd(address(0));
        vm.stopPrank();
        // ...and frozen once a fee has arrived (hook) and a purchase has happened (PRIO).
        earn(100 ether);
        treasury.allocate();
        vm.prank(executor);
        treasury.buyPrio(0.1 ether, 0);
        vm.startPrank(owner);
        vm.expectRevert(FeeTreasury.HookAlreadyBound.selector);
        treasury.bindHook(trader);
        vm.expectRevert(FeeTreasury.AlreadySet.selector);
        treasury.setPrio(trader);
        vm.stopPrank();
        FeeTreasury fresh = new FeeTreasury(manager, owner);
        vm.startPrank(owner);
        vm.expectRevert(FeeTreasury.ZeroAddress.selector);
        fresh.bindHook(address(0));
        vm.expectRevert(FeeTreasury.ZeroAddress.selector);
        fresh.setPrio(address(0));
        vm.stopPrank();
    }

    function test_strangerEthRefusedEvenAfterBinding() public {
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        (bool ok,) = address(treasury).call{value: 1}("");
        assertFalse(ok);
        vm.prank(trader);
        (ok,) = address(treasury).call{value: 1}(hex"12345678");
        assertFalse(ok, "no fallback accepts ETH either");
        assertEq(address(treasury).balance, 0);
    }

    function test_ownershipTwoStepNoRenounce() public {
        vm.prank(owner);
        vm.expectRevert(TwoStepOwned.RenunciationDisabled.selector);
        treasury.renounceOwnership();
        vm.prank(owner);
        treasury.transferOwnership(trader);
        assertEq(treasury.owner(), owner);
        vm.prank(trader);
        treasury.acceptOwnership();
        assertEq(treasury.owner(), trader);
        vm.prank(owner);
        vm.expectRevert();
        treasury.setExecutor(owner);
    }
}

/// @dev Liquidity providers can leave: after the launch's LP pulls out and only a thin PRIO-only range is
/// left below the price, the treasury's buys fill partly. The window and the budget line must count only
/// what the pool actually took, and the rest must still be spendable.
contract FeeTreasuryThinPoolTest is Fixture {
    StakingVault vault;
    Arena arena;
    address executor = makeAddr("executor");

    function setUp() public {
        deployLaunch(true);
        seedLiquidity(10_000 ether, true);
        vm.deal(trader, 10_000 ether);
        vault = new StakingVault(owner, address(token));
        arena = new Arena(owner, address(token));
        vm.startPrank(owner);
        vault.setRewardFunder(address(treasury));
        treasury.setSinks(address(vault), address(arena), makeAddr("adapter"));
        treasury.setExecutor(executor);
        treasury.setPriceFloors(1, 1);
        treasury.setMaxSpendPerSwap(10 ether);
        treasury.setSpendPerWindow(1 ether);
        vm.stopPrank();
        // 400 ETH of buys: 2 ETH of fees, delivered directly (the manager holds ETH).
        swap(trader, true, -int256(400 ether), 400 ether);
        treasury.allocate();
        // The LP leaves, then a thin PRIO-only range well below the price is all that is left.
        vm.startPrank(factory);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), -10_000 ether, bytes32(0)
            ),
            ""
        );
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-3000, -1200, 1 ether, bytes32(0)), "");
        vm.stopPrank();
    }

    function bucketsEqualBalance() internal view {
        assertEq(
            address(treasury).balance,
            treasury.unallocated() + treasury.reserve() + treasury.imdBudget() + treasury.prioBudget()
                + treasury.ownerBudget()
        );
    }

    function test_rollingWindowCountsOnlyTheEthActuallySpent() public {
        uint256 budget = treasury.prioBudget();
        // fee = ceil(400 ETH * 50 / 10050) is just under 2 ETH; 30% of it net of the reserve is ~0.537 ETH.
        assertGt(budget, 0.5 ether);
        vm.prank(executor);
        uint256 out = treasury.buyPrio(0.5 ether, 0);
        uint256 spent = budget - treasury.prioBudget();
        assertGt(spent, 0, "something filled");
        assertLt(spent, 0.5 ether, "the range ran dry before half an ether");
        assertEq(treasury.spentInWindow(), spent, "window charged only what was spent");
        assertGt(out, 0);
        assertEq(token.balanceOf(address(treasury)), 0, "everything bought was forwarded");
        bucketsEqualBalance();
        // The unspent part is still on the line. The drained pool now sits at the minimum price, which is
        // the treasury's own swap limit, so v4 refuses the next buy outright (PriceLimitAlreadyExceeded):
        // the whole call reverts and nothing leaves the line or the window.
        uint256 left = treasury.prioBudget();
        vm.prank(executor);
        vm.expectRevert();
        treasury.buyPrio(left, 0);
        assertEq(treasury.prioBudget(), left, "an empty pool spends nothing");
        assertEq(treasury.spentInWindow(), spent);
        bucketsEqualBalance();
    }
}
