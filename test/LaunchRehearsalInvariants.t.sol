// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Replica} from "./utils/Replica.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PrismRiotToken} from "../src/PrismRiotToken.sol";
import {TreasuryFeeHook} from "../src/TreasuryFeeHook.sol";
import {FeeTreasury} from "../src/FeeTreasury.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {Arena} from "../src/Arena.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockIntake} from "./utils/MockIntake.sol";

/// @dev Drives the whole wired system (the plan has run) in random order: trades on the live pool in all
/// four shapes, fee delivery, allocation, both purchases, both withdrawals, staking, and paid oracle
/// requests answered by the Intake stand-in. Ghost totals record every allocation line and every exit.
contract SystemHandler is Test {
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    bytes32 constant QUESTION = keccak256("q");

    PrismRiotToken prio;
    PrismRiotToken imd;
    TreasuryFeeHook hook;
    FeeTreasury treasury;
    StakingVault vault;
    Arena arena;
    OracleAdapter adapter;
    MockIntake intake;
    PoolSwapTest router;
    PoolKey key;
    address owner;
    address executor;
    address[] traders;
    address[] stakers;

    uint256 public ghostDirectIncome; // fee ETH delivered straight from the hook address
    uint256 public ghostReserveIn;
    uint256 public ghostImdIn;
    uint256 public ghostPrioIn;
    uint256 public ghostOwnerIn;
    uint256 public ghostAllocated;
    uint256 public ghostAllocations;
    uint256 public ghostOwnerOut;
    uint256 public ghostReserveOut;
    uint256 public ghostPrioSpent;
    uint256 public ghostImdSpent;
    uint256 public ghostPrioBought;
    uint256 public ghostImdBought;
    uint256 public ghostToVault;
    uint256 public ghostToArena;
    uint256 public ghostRewardsClaimed;
    uint256 public ghostOracleSpent;
    uint256 public ghostRequests;
    uint256 public ghostSwaps;
    uint256 public nextRound = 1;
    uint256[] public openRounds;

    constructor(
        PrismRiotToken p,
        PrismRiotToken i,
        TreasuryFeeHook h,
        FeeTreasury t,
        StakingVault v,
        Arena a,
        OracleAdapter o,
        MockIntake n,
        PoolSwapTest r,
        PoolKey memory k,
        address owner_,
        address executor_
    ) {
        prio = p;
        imd = i;
        hook = h;
        treasury = t;
        vault = v;
        arena = a;
        adapter = o;
        intake = n;
        router = r;
        key = k;
        owner = owner_;
        executor = executor_;
        for (uint256 j; j < 3; j++) {
            address who = address(uint160(0x4000 + j));
            traders.push(who);
            vm.deal(who, 100 ether);
            vm.prank(who);
            prio.approve(address(router), type(uint256).max);
        }
        for (uint256 j; j < 3; j++) {
            address who = address(uint160(0x5000 + j));
            stakers.push(who);
            vm.prank(who);
            prio.approve(address(vault), type(uint256).max);
        }
    }

    function fund() external {
        for (uint256 j; j < traders.length; j++) {
            prio.transfer(traders[j], 10_000_000 ether);
        }
        for (uint256 j; j < stakers.length; j++) {
            prio.transfer(stakers[j], 1_000_000 ether);
        }
    }

    receive() external payable {}

    // ------------------------------------------------------------------ the live pool

    function _swap(uint256 who, bool zeroForOne, int256 spec, uint256 value) internal {
        address t = traders[who % traders.length];
        vm.prank(t);
        try router.swap{value: value}(
            key,
            SwapParams(zeroForOne, spec, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {
            ghostSwaps++;
        } catch {}
    }

    function buyExactIn(uint256 who, uint256 amount) external {
        amount = bound(amount, 2, 0.2 ether);
        _swap(who, true, -int256(amount), amount);
    }

    function buyExactOut(uint256 who, uint256 amount) external {
        amount = bound(amount, 1 ether, 1_000_000 ether); // PRIO out
        _swap(who, true, int256(amount), 1 ether);
    }

    function sellExactIn(uint256 who, uint256 amount) external {
        amount = bound(amount, 1 ether, 1_000_000 ether); // PRIO in
        _swap(who, false, -int256(amount), 0);
    }

    function sellExactOut(uint256 who, uint256 amount) external {
        amount = bound(amount, 1, 0.01 ether); // ETH out
        _swap(who, false, int256(amount), 0);
    }

    function deliverFees(uint256 amount) external {
        uint256 claims = hook.pendingClaims();
        if (claims != 0) {
            uint256 max = address(hook.poolManager()).balance < claims ? address(hook.poolManager()).balance : claims;
            if (max != 0) hook.redeemClaims(bound(amount, 1, max));
        }
        hook.flush();
    }

    /// @dev Fee ETH delivered straight from the hook address (the only door): stands in for fees of swaps that
    /// happened elsewhere in the block.
    function hookIncome(uint256 amount) external {
        amount = bound(amount, 1, 0.1 ether);
        vm.deal(address(hook), address(hook).balance + amount);
        vm.prank(address(hook));
        (bool ok,) = address(treasury).call{value: amount}("");
        require(ok, "hook delivery refused");
        ghostDirectIncome += amount;
    }

    // ------------------------------------------------------------------ treasury

    function allocate() external {
        uint256 amount = treasury.unallocated();
        uint256 r0 = treasury.reserve();
        uint256 i0 = treasury.imdBudget();
        uint256 p0 = treasury.prioBudget();
        uint256 o0 = treasury.ownerBudget();
        treasury.allocate();
        uint256 toReserve = treasury.reserve() - r0;
        uint256 toImd = treasury.imdBudget() - i0;
        uint256 toPrio = treasury.prioBudget() - p0;
        uint256 toOwner = treasury.ownerBudget() - o0;
        assertEq(treasury.unallocated(), 0, "everything allocated");
        assertEq(toReserve + toImd + toPrio + toOwner, amount, "nothing lost in the split");
        assertLe(toReserve, amount / 10, "reserve takes at most 10%");
        assertLe(
            treasury.reserve(), treasury.reserveTarget() > r0 ? treasury.reserveTarget() : r0, "never past the target"
        );
        uint256 rest = amount - toReserve;
        assertEq(toImd, rest * 30 / 100, "30% IMD");
        assertEq(toPrio, rest * 30 / 100, "30% PRIO");
        assertEq(toOwner, rest - toImd - toPrio, "40% owner, with the rounding dust");
        ghostReserveIn += toReserve;
        ghostImdIn += toImd;
        ghostPrioIn += toPrio;
        ghostOwnerIn += toOwner;
        ghostAllocated += amount;
        if (amount != 0) ghostAllocations++;
    }

    function buyPrio(uint256 amount) external {
        uint256 budget = treasury.prioBudget();
        if (budget < 1e12) return;
        uint256 cap = treasury.maxSpendPerSwap() < budget ? treasury.maxSpendPerSwap() : budget;
        amount = bound(amount, 1e12, cap);
        uint256 vaultBefore = prio.balanceOf(address(vault));
        uint256 arenaBefore = prio.balanceOf(address(arena));
        vm.prank(executor);
        try treasury.buyPrio(amount, 1) returns (uint256 out) {
            ghostPrioSpent += budget - treasury.prioBudget();
            ghostPrioBought += out;
            uint256 toVault = prio.balanceOf(address(vault)) - vaultBefore;
            uint256 toArena = prio.balanceOf(address(arena)) - arenaBefore;
            assertEq(toVault + toArena, out, "all of it forwarded");
            assertLe(toVault, toArena);
            assertLe(toArena - toVault, 1, "split equally up to one wei");
            ghostToVault += toVault;
            ghostToArena += toArena;
        } catch {}
    }

    function buyImd(uint256 amount) external {
        uint256 budget = treasury.imdBudget();
        if (budget < 1e12) return;
        uint256 cap = treasury.maxSpendPerSwap() < budget ? treasury.maxSpendPerSwap() : budget;
        amount = bound(amount, 1e12, cap);
        vm.prank(executor);
        try treasury.buyImd(amount, 1) returns (uint256 out) {
            ghostImdSpent += budget - treasury.imdBudget();
            ghostImdBought += out;
        } catch {}
    }

    function withdrawOwner(uint256 amount) external {
        uint256 max = treasury.ownerBudget();
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(owner);
        treasury.withdrawOwner(payable(owner), amount);
        ghostOwnerOut += amount;
    }

    function withdrawReserveAsExecutor(uint256 amount) external {
        uint256 max = treasury.reserve();
        if (max == 0) return;
        uint256 room = treasury.reservePerWindow();
        if (block.timestamp < treasury.reserveWindowStart() + treasury.SPEND_WINDOW()) {
            room -= treasury.reserveSpentInWindow();
        }
        if (room == 0) return;
        amount = bound(amount, 1, max < room ? max : room);
        vm.prank(executor);
        treasury.withdrawReserve(payable(executor), amount);
        ghostReserveOut += amount;
    }

    function withdrawReserveAsOwner(uint256 amount) external {
        uint256 max = treasury.reserve();
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(owner);
        treasury.withdrawReserve(payable(owner), amount);
        ghostReserveOut += amount;
    }

    // ------------------------------------------------------------------ staking

    function stake(uint256 who, uint256 amount) external {
        address u = stakers[who % stakers.length];
        uint256 max = prio.balanceOf(u);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(u);
        vault.stake(amount);
    }

    function unstake(uint256 who, uint256 amount) external {
        address u = stakers[who % stakers.length];
        uint256 max = vault.staked(u);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(u);
        vault.withdraw(amount);
    }

    function claimRewards(uint256 who) external {
        address u = stakers[who % stakers.length];
        uint256 before = prio.balanceOf(u);
        vm.prank(u);
        vault.claim();
        ghostRewardsClaimed += prio.balanceOf(u) - before;
    }

    // ------------------------------------------------------------------ games and the oracle

    /// @dev The owner pins the next question at a commit deadline up to a day away and opens the round at the
    /// Arena with a prize from the game pool (A7 has run: the adapter sells nothing for a round that does not
    /// exist, so the round must be created first).
    function openRound(uint256 prize, uint256 inSeconds) external {
        uint256 id = arena.roundCount() + 1;
        prize = bound(prize, 0, arena.unallocatedPrizePool());
        uint64 commitDeadline = uint64(block.timestamp + bound(inSeconds, 1, 1 days));
        vm.prank(owner);
        adapter.pinQuestion(id, QUESTION, 1, 5, 4, commitDeadline, "");
        vm.prank(owner);
        uint256 created = arena.createRound(
            Arena.Mode.VaultRaid, 4, commitDeadline, commitDeadline + 1 hours, commitDeadline + 2 hours, prize, 0, 0
        );
        assertEq(created, id);
        assertEq(arena.rounds(id).prize, prize);
        openRounds.push(id);
        nextRound = id + 1;
    }

    /// @dev Once a round's commit deadline has passed the executor buys its answer, which the Intake delivers
    /// through the callback. IMD leaves the adapter only this way.
    function requestAnswer(uint256 which, uint256 answer) external {
        if (openRounds.length == 0) return;
        uint256 id = openRounds[which % openRounds.length];
        if (adapter.resultOf(id).settled || adapter.openRequest(id) != bytes32(0)) return;
        if (block.timestamp < adapter.pinned(id).notBefore) return;
        uint256 price = adapter.price();
        if (imd.balanceOf(address(adapter)) < price) return;
        if (block.timestamp < adapter.windowStart() + adapter.BUDGET_WINDOW()) {
            if (adapter.spentInWindow() + price > adapter.budgetPerWindow()) return;
        }
        vm.prank(executor);
        bytes32 intakeId = adapter.request(id);
        ghostOracleSpent += price;
        ghostRequests++;
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: intakeId,
            chainId: 1,
            questionHash: QUESTION,
            answerType: OracleAttestation.ANSWER_UINT256,
            answer: abi.encode(answer),
            figure: 0,
            fromBlock: 1,
            toBlock: 2,
            blockHash: 0,
            panelJobId: 0,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, adapter.attestationDigest(a));
        assertTrue(intake.deliver(abi.encode(intakeId, a, abi.encodePacked(r, s, v))), "callback lands");
        assertEq(adapter.resultOf(id).answer, answer);
    }

    function tryWithdrawImd(uint256 amount) external {
        amount = bound(amount, 0, imd.balanceOf(address(adapter)));
        vm.prank(owner);
        vm.expectRevert(OracleAdapter.AssetNotWithdrawable.selector);
        adapter.withdrawToken(address(imd), owner, amount);
    }

    function warp(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 1, 2 days));
    }
}

/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 40
contract LaunchRehearsalInvariantsTest is Replica {
    SystemHandler handler;

    function setUp() public {
        setUpReplica();
        deployApplications();
        seedPrioOnly(4e22);
        seedBothSides(4e22, 5 ether);
        seedImdPool(8e20, 50 ether);
        runPlan();
        vm.startPrank(OWNER);
        adapter.setSigner(vm.addr(SIGNER_KEY));
        // B5 re-signed from the market: the pool's price moves with every trade below, and the floors only
        // need to refuse a manipulated price, not every honest one.
        treasury.setPriceFloors(1e7 ether, 50 ether);
        vm.stopPrank();
        handler =
            new SystemHandler(prio, imd, hook, treasury, vault, arena, adapter, intake, router, key, OWNER, executor);
        vm.prank(FACTORY);
        prio.transfer(address(handler), 40_000_000 ether);
        handler.fund();
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](19);
        sels[18] = SystemHandler.openRound.selector;
        sels[0] = SystemHandler.buyExactIn.selector;
        sels[1] = SystemHandler.buyExactOut.selector;
        sels[2] = SystemHandler.sellExactIn.selector;
        sels[3] = SystemHandler.sellExactOut.selector;
        sels[4] = SystemHandler.deliverFees.selector;
        sels[5] = SystemHandler.hookIncome.selector;
        sels[6] = SystemHandler.allocate.selector;
        sels[7] = SystemHandler.buyPrio.selector;
        sels[8] = SystemHandler.buyImd.selector;
        sels[9] = SystemHandler.withdrawOwner.selector;
        sels[10] = SystemHandler.withdrawReserveAsExecutor.selector;
        sels[11] = SystemHandler.withdrawReserveAsOwner.selector;
        sels[12] = SystemHandler.stake.selector;
        sels[13] = SystemHandler.unstake.selector;
        sels[14] = SystemHandler.claimRewards.selector;
        sels[15] = SystemHandler.requestAnswer.selector;
        sels[16] = SystemHandler.tryWithdrawImd.selector;
        sels[17] = SystemHandler.warp.selector;
        targetSelector(FuzzSelector(address(handler), sels));
    }

    /// @dev Every wei the treasury holds is on exactly one line.
    function invariant_treasuryEthIsFullyBucketed() public view {
        assertEq(address(treasury).balance, treasuryBuckets());
    }

    /// @dev Income only ever enters from the hook and only ever leaves through the four documented doors.
    function invariant_incomeConservation() public view {
        assertEq(treasury.totalIncome(), hook.totalFeeDelivered() + handler.ghostDirectIncome());
        assertEq(
            treasury.totalIncome(),
            address(treasury).balance + handler.ghostOwnerOut() + handler.ghostReserveOut() + handler.ghostPrioSpent()
                + handler.ghostImdSpent()
        );
        assertEq(hook.totalFeeCharged(), hook.totalFeeDelivered() + hook.pendingEth() + hook.pendingClaims());
    }

    /// @dev The 10%-capped reserve, then 30% IMD, 30% PRIO, 40% owner, over the whole history: each line
    /// still holds exactly what it was allocated minus what left it, and the two purchase lines are equal.
    function invariant_allocationLinesReconcile() public view {
        assertEq(treasury.reserve() + handler.ghostReserveOut(), handler.ghostReserveIn(), "reserve line");
        assertEq(treasury.imdBudget() + handler.ghostImdSpent(), handler.ghostImdIn(), "IMD line");
        assertEq(treasury.prioBudget() + handler.ghostPrioSpent(), handler.ghostPrioIn(), "PRIO line");
        assertEq(treasury.ownerBudget() + handler.ghostOwnerOut(), handler.ghostOwnerIn(), "owner line");
        assertEq(handler.ghostImdIn(), handler.ghostPrioIn(), "IMD and PRIO lines are allocated equally");
        assertLe(handler.ghostReserveIn(), handler.ghostAllocated() / 10 + handler.ghostAllocations(), "reserve <= 10%");
        assertLe(treasury.reserve(), treasury.MAX_RESERVE_TARGET());
        // owner = rest - 2 * floor(0.3 rest) >= 0.4 rest, and imd + prio = 2 * floor(0.3 rest) <= 0.6 rest.
        assertGe(
            handler.ghostOwnerIn() * 3,
            (handler.ghostImdIn() + handler.ghostPrioIn()) * 2,
            "owner is at least 40% of the rest"
        );
    }

    /// @dev Purchased PRIO is split and forwarded at once; purchased IMD sits in the adapter until a panel
    /// answer is bought; the treasury never holds a token and the adapter's IMD never leaves another way.
    function invariant_purchasesLandWhereTheBriefSays() public view {
        assertEq(prio.balanceOf(address(treasury)), 0);
        assertEq(imd.balanceOf(address(treasury)), 0);
        assertEq(handler.ghostToVault() + handler.ghostToArena(), handler.ghostPrioBought());
        assertEq(imd.balanceOf(address(adapter)), handler.ghostImdBought() - handler.ghostOracleSpent());
        assertEq(imd.balanceOf(INTAKE), handler.ghostOracleSpent());
        assertEq(
            arena.unallocatedPrizePool() + arena.lockedPrizes(),
            handler.ghostToArena(),
            "the game pool, free or locked in open rounds, is exactly the arena's half"
        );
        assertEq(
            vault.rewardsOwed() + handler.ghostRewardsClaimed(),
            handler.ghostToVault(),
            "the stream is exactly the vault's half"
        );
    }

    /// @dev Principal and escrow are never touched by the economy around them.
    function invariant_principalAndEscrowAreIsolated() public view {
        assertGe(prio.balanceOf(address(vault)), vault.totalStaked() + vault.rewardsOwed());
        assertEq(
            prio.balanceOf(address(arena)), arena.totalEscrowed() + arena.lockedPrizes() + arena.unallocatedPrizePool()
        );
    }

    /// @dev The operator's bounds hold under every interleaving.
    function invariant_executorBounds() public view {
        assertLe(treasury.spentInWindow(), treasury.spendPerWindow());
        assertLe(treasury.reserveSpentInWindow(), treasury.reservePerWindow());
        assertLe(adapter.spentInWindow(), adapter.budgetPerWindow());
        assertEq(hook.treasury(), address(treasury), "the permanent binding never moves");
        assertEq(treasury.hook(), HOOK);
    }
}
