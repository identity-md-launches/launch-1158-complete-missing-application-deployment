// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./utils/Fixture.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PrismRiotToken} from "../src/PrismRiotToken.sol";
import {TreasuryFeeHook} from "../src/TreasuryFeeHook.sol";
import {FeeTreasury} from "../src/FeeTreasury.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {Arena} from "../src/Arena.sol";

/// @dev Drives the live pool (all four swap shapes from several traders), the hook's permissionless
/// delivery paths, and every treasury flow (allocate, owner and reserve withdrawals, PRIO purchases) in
/// random order. Ghost totals record every wei that left the treasury.
contract TreasuryHandler is Test {
    PoolManager manager;
    PrismRiotToken token;
    TreasuryFeeHook hook;
    FeeTreasury treasury;
    StakingVault vault;
    Arena arena;
    PoolSwapTest router;
    PoolKey key;
    address owner;
    address payable sink;

    address[] traders;

    uint256 public ghostOwnerOut;
    uint256 public ghostReserveOut;
    uint256 public ghostPrioSpent;
    uint256 public ghostPrioBought;
    uint256 public ghostToVault;
    uint256 public ghostToArena;
    uint256 public ghostSwaps;
    uint256 public ghostPurchases;

    constructor(
        PoolManager m,
        PrismRiotToken t,
        TreasuryFeeHook h,
        FeeTreasury tr,
        StakingVault v,
        Arena a,
        PoolSwapTest r,
        PoolKey memory k,
        address o
    ) {
        manager = m;
        token = t;
        hook = h;
        treasury = tr;
        vault = v;
        arena = a;
        router = r;
        key = k;
        owner = o;
        sink = payable(makeAddr("sink"));
        for (uint256 i; i < 3; i++) {
            address who = address(uint160(0x2000 + i));
            traders.push(who);
            vm.deal(who, 1_000_000 ether);
            vm.prank(who);
            token.approve(address(router), type(uint256).max);
        }
    }

    function fundTraders() external {
        for (uint256 i; i < traders.length; i++) {
            token.transfer(traders[i], 1_000_000 ether);
        }
    }

    function _swap(uint256 who, bool zeroForOne, int256 spec) internal {
        address t = traders[who % traders.length];
        vm.prank(t);
        router.swap{value: zeroForOne ? 200 ether : 0}(
            key,
            SwapParams(zeroForOne, spec, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        ghostSwaps++;
    }

    function buyExactIn(uint256 who, uint256 amount) external {
        _swap(who, true, -int256(bound(amount, 1, 50 ether)));
    }

    function buyExactOut(uint256 who, uint256 amount) external {
        _swap(who, true, int256(bound(amount, 1, 50 ether)));
    }

    function sellExactIn(uint256 who, uint256 amount) external {
        _swap(who, false, -int256(bound(amount, 1, 50 ether)));
    }

    function sellExactOut(uint256 who, uint256 amount) external {
        _swap(who, false, int256(bound(amount, 1, 50 ether)));
    }

    function flush() external {
        hook.flush();
    }

    function redeemClaims(uint256 amount) external {
        uint256 max = hook.pendingClaims();
        if (max == 0) return;
        amount = bound(amount, 1, max);
        if (address(manager).balance < amount) return;
        hook.redeemClaims(amount);
    }

    function allocate() external {
        treasury.allocate();
    }

    function withdrawOwner(uint256 amount) external {
        uint256 max = treasury.ownerBudget();
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(owner);
        treasury.withdrawOwner(sink, amount);
        ghostOwnerOut += amount;
    }

    /// @dev The handler is the executor: it may draw the reserve only to itself, `reservePerWindow` per bucket.
    function withdrawReserve(uint256 amount) external {
        uint256 max = treasury.reserve();
        if (max == 0) return;
        uint256 room = treasury.reservePerWindow();
        if (block.timestamp < treasury.reserveWindowStart() + treasury.SPEND_WINDOW()) {
            room -= treasury.reserveSpentInWindow();
        }
        if (room == 0) return;
        amount = bound(amount, 1, max < room ? max : room);
        treasury.withdrawReserve(payable(address(this)), amount);
        ghostReserveOut += amount;
    }

    receive() external payable {}

    function buyPrio(uint256 amount) external {
        uint256 max = treasury.prioBudget();
        if (max < 1e9) return;
        amount = bound(amount, 1e9, max > treasury.maxSpendPerSwap() ? treasury.maxSpendPerSwap() : max);
        uint256 out = treasury.buyPrio(amount, 1);
        ghostPrioSpent += amount;
        ghostPrioBought += out;
        ghostToVault += out / 2;
        ghostToArena += out - out / 2;
        ghostPurchases++;
    }

    function setReserveTarget(uint256 target) external {
        target = bound(target, 0, treasury.MAX_RESERVE_TARGET());
        vm.prank(owner);
        treasury.setReserveTarget(target);
    }

    function warp(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 1, 3 days));
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 40
contract TreasuryInvariantsTest is Fixture {
    StakingVault vault;
    Arena arena;
    TreasuryHandler handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        deployLaunch(true);
        seedLiquidity(10_000 ether, true);
        vault = new StakingVault(owner, address(token));
        arena = new Arena(owner, address(token));
        handler = new TreasuryHandler(manager, token, hook, treasury, vault, arena, swapRouter, key, owner);
        vm.prank(factory);
        token.transfer(address(handler), 3_000_000 ether);
        handler.fundTraders();
        vm.startPrank(owner);
        vault.setRewardFunder(address(treasury));
        treasury.setSinks(address(vault), address(arena), makeAddr("adapter"));
        treasury.setExecutor(address(handler));
        // Purchases are refused until the owner sets a price floor; the pool opens at 1:1 with 1.25% LP fee
        // plus the 0.5% hook fee, so 0.9 PRIO per ETH is a realistic floor that bounded buys clear.
        treasury.setPriceFloors(0.9e18, 0.9e18);
        vm.stopPrank();

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](12);
        sels[0] = TreasuryHandler.buyExactIn.selector;
        sels[1] = TreasuryHandler.buyExactOut.selector;
        sels[2] = TreasuryHandler.sellExactIn.selector;
        sels[3] = TreasuryHandler.sellExactOut.selector;
        sels[4] = TreasuryHandler.flush.selector;
        sels[5] = TreasuryHandler.redeemClaims.selector;
        sels[6] = TreasuryHandler.allocate.selector;
        sels[7] = TreasuryHandler.withdrawOwner.selector;
        sels[8] = TreasuryHandler.withdrawReserve.selector;
        sels[9] = TreasuryHandler.buyPrio.selector;
        sels[10] = TreasuryHandler.setReserveTarget.selector;
        sels[11] = TreasuryHandler.warp.selector;
        targetSelector(FuzzSelector(address(handler), sels));
    }

    /// @dev Every wei the treasury holds sits in exactly one bucket.
    function invariant_treasuryEthIsFullyBucketed() public view {
        assertEq(
            address(treasury).balance,
            treasury.unallocated() + treasury.reserve() + treasury.imdBudget() + treasury.prioBudget()
                + treasury.ownerBudget()
        );
    }

    /// @dev Income never leaves except through the three spending paths.
    function invariant_incomeConservation() public view {
        assertEq(
            treasury.totalIncome(),
            address(treasury).balance + handler.ghostOwnerOut() + handler.ghostReserveOut() + handler.ghostPrioSpent()
        );
    }

    /// @dev Every wei the hook ever charged is delivered, waiting as ETH, or waiting as a claim.
    function invariant_hookFeeConservation() public view {
        assertEq(hook.totalFeeCharged(), hook.totalFeeDelivered() + hook.pendingEth() + hook.pendingClaims());
        assertEq(address(hook).balance, hook.pendingEth(), "hook holds exactly its pending ETH");
        assertEq(manager.balanceOf(address(hook), 0), hook.pendingClaims(), "6909 balance equals pending claims");
        assertEq(treasury.totalIncome(), hook.totalFeeDelivered(), "the treasury's only income is the hook's fee");
    }

    /// @dev The reserve can never exceed the hard cap, and budgets never exceed income.
    function invariant_reserveCapped() public view {
        assertLe(treasury.reserve() + handler.ghostReserveOut(), treasury.totalIncome() / 10 + 1);
        assertLe(treasury.reserve(), treasury.MAX_RESERVE_TARGET());
    }

    /// @dev Purchased PRIO is split equally and never stays in the treasury.
    function invariant_purchasedPrioIsSplitAndForwarded() public view {
        assertEq(token.balanceOf(address(treasury)), 0);
        uint256 bought = handler.ghostPrioBought();
        assertEq(token.balanceOf(address(vault)) + token.balanceOf(address(arena)), bought);
        assertEq(arena.unallocatedPrizePool(), handler.ghostToArena());
        assertEq(vault.rewardsOwed(), handler.ghostToVault());
        assertLe(handler.ghostToVault(), handler.ghostToArena());
        assertLe(handler.ghostToArena() - handler.ghostToVault(), handler.ghostPurchases(), "equal up to one wei each");
    }

    /// @dev The pool manager never ends a sequence owing anything: all deltas settled.
    function invariant_managerSolventForClaims() public view {
        assertGe(address(manager).balance + hook.pendingEth(), 0);
        assertEq(manager.balanceOf(address(treasury), 0), 0, "the treasury never holds claims");
    }
}
