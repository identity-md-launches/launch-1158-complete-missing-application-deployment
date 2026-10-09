// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PrismRiotToken} from "../src/PrismRiotToken.sol";
import {Arena, IRoundOracle} from "../src/Arena.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {TwoStepOwned} from "../src/TwoStepOwned.sol";

/// @dev Failure paths and boundaries of the Arena: unapproved balances, exact deadline edges, wrong-state
/// calls, non-entrants, double claims, prize dust with many winners, and the published payout bounds.
/// forge-config: default.fuzz.runs = 512
contract ArenaEdgeTest is Test {
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    bytes32 constant QUESTION = keccak256("round question");
    uint64 constant T0 = 1_800_000_000;

    PrismRiotToken token;
    Arena arena;
    OracleAdapter adapter;
    address owner = makeAddr("owner");
    address funder = makeAddr("funder");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(T0);
        token = new PrismRiotToken();
        arena = new Arena(owner, address(token));
        adapter = new OracleAdapter(owner, SIGNER);
        vm.prank(owner);
        arena.setOracle(IRoundOracle(address(adapter)));
        token.transfer(alice, 10_000 ether);
        token.transfer(bob, 10_000 ether);
        token.transfer(funder, 100_000 ether);
        vm.startPrank(funder);
        token.approve(address(arena), type(uint256).max);
        arena.fundPrizes(10_000 ether);
        vm.stopPrank();
    }

    function createRound(Arena.Mode mode, uint8 choices, uint256 prize, uint16 threshold)
        internal
        returns (uint256 id)
    {
        uint64 commitDeadline = uint64(vm.getBlockTimestamp() + 1 hours);
        vm.startPrank(owner);
        // The round's question (and the signer of the moment) must be pinned before the round exists.
        adapter.pinQuestion(arena.roundCount() + 1, QUESTION, 1, 5, 4, commitDeadline, "");
        id = arena.createRound(
            mode, choices, commitDeadline, commitDeadline + 1 hours, commitDeadline + 2 hours, prize, threshold, 0
        );
        vm.stopPrank();
    }

    function enter(uint256 id, address who, uint8 choice) internal {
        bytes32 c = arena.commitmentOf(id, who, choice, keccak256(abi.encode(who, id)));
        vm.startPrank(who);
        token.approve(address(arena), 102 ether);
        arena.enter(id, c);
        vm.stopPrank();
    }

    function reveal(uint256 id, address who, uint8 choice) internal {
        vm.prank(who);
        arena.reveal(id, choice, keccak256(abi.encode(who, id)));
    }

    function attest(uint256 id, uint256 answer, uint64 issuedAt) internal {
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("req", id, answer, issuedAt)),
            chainId: 1,
            questionHash: QUESTION,
            answerType: OracleAttestation.ANSWER_UINT256,
            answer: abi.encode(answer),
            figure: 0,
            fromBlock: 1,
            toBlock: 2,
            blockHash: bytes32(uint256(1)),
            panelJobId: bytes32(uint256(2)),
            panelSize: 5,
            quorum: 4,
            agreed: 4,
            issuedAt: issuedAt,
            expiresAt: uint64(block.timestamp + 1 days)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, adapter.attestationDigest(a));
        vm.prank(owner);
        adapter.submitAttestation(id, a, abi.encodePacked(r, s, v));
    }

    function accounted() internal view {
        assertEq(
            token.balanceOf(address(arena)), arena.totalEscrowed() + arena.lockedPrizes() + arena.unallocatedPrizePool()
        );
    }

    // ------------------------------------------------------------------ never debit what was not approved

    function test_entryWithoutApprovalReverts_andWithShortApprovalReverts() public {
        uint256 id = createRound(Arena.Mode.VaultRaid, 4, 0, 0);
        bytes32 c = arena.commitmentOf(id, alice, 1, 0);
        vm.prank(alice);
        vm.expectRevert();
        arena.enter(id, c);
        vm.startPrank(alice);
        token.approve(address(arena), 102 ether - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(arena), 102 ether - 1, 102 ether
            )
        );
        arena.enter(id, c);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 10_000 ether);
        assertEq(arena.totalEscrowed(), 0);
    }

    function test_entryPullsExactly102AndNothingLater() public {
        uint256 id = createRound(Arena.Mode.VaultRaid, 4, 100 ether, 0);
        vm.prank(alice);
        token.approve(address(arena), type(uint256).max);
        bytes32 c = arena.commitmentOf(id, alice, 1, 0);
        vm.prank(alice);
        arena.enter(id, c);
        assertEq(token.balanceOf(alice), 10_000 ether - 102 ether);
        skip(1 hours);
        vm.prank(alice);
        arena.reveal(id, 1, 0);
        skip(1 hours);
        attest(id, 0, uint64(block.timestamp));
        arena.settle(id);
        vm.prank(alice);
        arena.claim(id);
        // Unlimited approval, yet reveal/settle/claim moved nothing more out of alice.
        assertEq(token.balanceOf(alice), 10_000 ether - 102 ether + 100 ether + 100 ether);
    }

    function test_zeroCommitmentRefused() public {
        uint256 id = createRound(Arena.Mode.VaultRaid, 4, 0, 0);
        vm.startPrank(alice);
        token.approve(address(arena), 102 ether);
        vm.expectRevert(Arena.BadReveal.selector);
        arena.enter(id, bytes32(0));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ wrong state, wrong round, wrong caller

    function test_unknownRoundRefusesEverything() public {
        vm.prank(alice);
        vm.expectRevert(Arena.NotOpen.selector);
        arena.enter(42, bytes32(uint256(1)));
        vm.prank(alice);
        vm.expectRevert(Arena.NotOpen.selector);
        arena.reveal(42, 1, 0);
        vm.expectRevert(Arena.NotOpen.selector);
        arena.settle(42);
        vm.expectRevert(Arena.NotOpen.selector);
        arena.cancel(42);
        vm.expectRevert(Arena.NotSettled.selector);
        arena.claim(42);
        vm.expectRevert(Arena.NotCancelled.selector);
        arena.refund(42);
        assertEq(arena.payoutOf(42, alice), 0);
    }

    function test_nonEntrantCannotClaimOrRefund() public {
        uint256 id = createRound(Arena.Mode.VaultRaid, 4, 0, 0);
        enter(id, alice, 1);
        skip(2 hours);
        attest(id, 0, uint64(block.timestamp));
        arena.settle(id);
        vm.prank(bob);
        vm.expectRevert(Arena.NotEntered.selector);
        arena.claim(id);
        assertEq(arena.payoutOf(id, bob), 0);

        uint256 id2 = createRound(Arena.Mode.VaultRaid, 4, 0, 0);
        enter(id2, alice, 1);
        skip(3 hours + 72 hours);
        arena.cancel(id2);
        vm.prank(bob);
        vm.expectRevert(Arena.NotEntered.selector);
        arena.refund(id2);
        vm.prank(alice);
        arena.refund(id2);
        vm.prank(alice);
        vm.expectRevert(Arena.AlreadyClaimed.selector);
        arena.refund(id2);
        accounted();
    }

    function test_settledRoundCannotBeCancelledAndCancelledCannotSettle() public {
        uint256 id = createRound(Arena.Mode.VaultRaid, 4, 10 ether, 0);
        enter(id, alice, 1);
        skip(2 hours);
        attest(id, 0, uint64(block.timestamp));
        arena.settle(id);
        skip(100 days);
        vm.expectRevert(Arena.NotOpen.selector);
        arena.cancel(id);
        vm.expectRevert(Arena.NotOpen.selector);
        arena.settle(id);
        vm.prank(alice);
        vm.expectRevert(Arena.NotCancelled.selector);
        arena.refund(id);
        Arena.Round memory r = arena.rounds(id);
        assertEq(uint256(r.state), uint256(Arena.RoundState.Settled));
    }

    function test_onlyOwnerCreatesAndSetsOracle_andOracleMustBeSetFirst() public {
        Arena fresh = new Arena(owner, address(token));
        vm.prank(owner);
        vm.expectRevert(Arena.ZeroAddress.selector);
        fresh.createRound(Arena.Mode.VaultRaid, 4, T0 + 1, T0 + 2, T0 + 3, 0, 0, 0);
        vm.prank(alice);
        vm.expectRevert();
        fresh.setOracle(IRoundOracle(address(adapter)));
        vm.prank(owner);
        vm.expectRevert(Arena.ZeroAddress.selector);
        fresh.setOracle(IRoundOracle(address(0)));
        vm.prank(owner);
        vm.expectRevert(Arena.BadChoices.selector);
        arena.createRound(Arena.Mode.VaultRaid, 1, T0 + 1, T0 + 2, T0 + 3, 0, 0, 0);
        vm.prank(owner);
        vm.expectRevert(Arena.BadDeadlines.selector);
        arena.createRound(Arena.Mode.VaultRaid, 2, uint64(T0), T0 + 2, T0 + 3, 0, 0, 0);
        vm.prank(owner);
        vm.expectRevert(Arena.BadDeadlines.selector);
        arena.createRound(Arena.Mode.VaultRaid, 2, T0 + 1, T0 + 2, T0 + 2, 0, 0, 0);
    }

    function test_ownershipTwoStepNoRenounce() public {
        vm.prank(owner);
        vm.expectRevert(TwoStepOwned.RenunciationDisabled.selector);
        arena.renounceOwnership();
        vm.prank(owner);
        arena.transferOwnership(bob);
        vm.prank(bob);
        vm.expectRevert();
        arena.createRound(Arena.Mode.VaultRaid, 2, T0 + 1, T0 + 2, T0 + 3, 0, 0, 0);
        vm.prank(bob);
        arena.acceptOwnership();
        assertEq(arena.owner(), bob);
    }

    // ------------------------------------------------------------------ exact boundaries

    function test_deadlineBoundariesAreHalfOpen() public {
        uint256 id = createRound(Arena.Mode.VaultRaid, 4, 0, 0);
        Arena.Round memory r = arena.rounds(id);
        vm.warp(r.commitDeadline - 1);
        enter(id, alice, 1);
        vm.warp(r.commitDeadline);
        vm.startPrank(bob);
        token.approve(address(arena), 102 ether);
        vm.expectRevert(Arena.CommitClosed.selector);
        arena.enter(id, bytes32(uint256(1)));
        vm.stopPrank();
        // Reveal opens exactly at the commit deadline and closes exactly at the reveal deadline.
        reveal(id, alice, 1);
        vm.warp(r.revealDeadline - 1);
        vm.expectRevert(Arena.RevealNotOver.selector);
        arena.settle(id);
        vm.warp(r.revealDeadline);
        vm.expectRevert(Arena.NoResult.selector);
        arena.settle(id);
        vm.warp(r.resultDeadline + 72 hours - 1);
        vm.expectRevert(Arena.NotCancellable.selector);
        arena.cancel(id);
        vm.warp(r.resultDeadline + 72 hours);
        arena.cancel(id);
        assertEq(uint256(arena.rounds(id).state), uint256(Arena.RoundState.Cancelled));
        assertEq(arena.payoutOf(id, alice), 102 ether);
    }

    /// @dev The Arena applies the same 5 minute tolerance as the adapter: a result issued exactly at
    /// commitDeadline - tolerance settles; one second earlier does not reach the Arena at all.
    function test_issuedAtToleranceIsConsistentWithTheAdapter() public {
        uint256 id = createRound(Arena.Mode.VaultRaid, 4, 0, 0);
        Arena.Round memory r = arena.rounds(id);
        uint64 tol = adapter.ISSUED_AT_TOLERANCE();
        assertEq(tol, 5 minutes);
        enter(id, alice, 1);
        skip(2 hours);
        // One second too early: the adapter refuses it, so the Arena never sees it.
        OracleAttestation.Attestation memory a;
        {
            uint64 early = r.commitDeadline - tol - 1;
            a = OracleAttestation.Attestation({
                requestId: keccak256("early"),
                chainId: 1,
                questionHash: QUESTION,
                answerType: OracleAttestation.ANSWER_UINT256,
                answer: abi.encode(uint256(0)),
                figure: 0,
                fromBlock: 1,
                toBlock: 2,
                blockHash: 0,
                panelJobId: 0,
                panelSize: 5,
                quorum: 4,
                agreed: 4,
                issuedAt: early,
                expiresAt: uint64(block.timestamp + 1 days)
            });
            (uint8 v, bytes32 rr, bytes32 s) = vm.sign(SIGNER_KEY, adapter.attestationDigest(a));
            vm.expectRevert(abi.encodeWithSelector(OracleAdapter.IssuedTooEarly.selector, early, r.commitDeadline));
            vm.prank(owner);
            adapter.submitAttestation(id, a, abi.encodePacked(rr, s, v));
        }
        // Exactly at the boundary: accepted by both.
        attest(id, 0, r.commitDeadline - tol);
        arena.settle(id);
        assertEq(uint256(arena.rounds(id).state), uint256(Arena.RoundState.Settled));
    }

    // ------------------------------------------------------------------ scoring

    function test_factionDuelSplitsPrizeAmongAllCorrect() public {
        uint256 id = createRound(Arena.Mode.FactionDuel, 2, 101 ether, 0);
        enter(id, alice, 2);
        enter(id, bob, 2);
        skip(1 hours);
        reveal(id, alice, 2);
        reveal(id, bob, 2);
        skip(1 hours);
        attest(id, 3, uint64(block.timestamp)); // 3 % 2 + 1 = 2
        arena.settle(id);
        Arena.Round memory r = arena.rounds(id);
        assertEq(r.correct, 2);
        assertEq(r.prizePerWinner, 50.5 ether);
        assertEq(arena.payoutOf(id, alice), 150.5 ether);
        assertEq(arena.payoutOf(id, bob), 150.5 ether);
        accounted();
    }

    /// @dev Prize dust from integer division goes back to the game pool, not to anyone's claim.
    function test_prizeDustReturnsToPool() public {
        uint256 id = createRound(Arena.Mode.VaultRaid, 3, 100 ether + 1, 0);
        enter(id, alice, 1);
        enter(id, bob, 1);
        skip(1 hours);
        reveal(id, alice, 1);
        reveal(id, bob, 1);
        skip(1 hours);
        uint256 poolBefore = arena.unallocatedPrizePool();
        attest(id, 3, uint64(block.timestamp)); // 3 % 3 + 1 = 1
        arena.settle(id);
        assertEq(arena.rounds(id).prizePerWinner, 50 ether);
        assertEq(arena.unallocatedPrizePool(), poolBefore + 1, "the dust wei");
        vm.prank(alice);
        arena.claim(id);
        vm.prank(bob);
        arena.claim(id);
        assertEq(arena.totalEscrowed(), 0);
        accounted();
    }

    function test_bossThresholdMetPaysPrize() public {
        uint256 id = createRound(Arena.Mode.BossChallenge, 3, 90 ether, 2);
        enter(id, alice, 1);
        enter(id, bob, 1);
        skip(1 hours);
        reveal(id, alice, 1);
        reveal(id, bob, 1);
        skip(1 hours);
        attest(id, 0, uint64(block.timestamp)); // 0 % 3 + 1 = 1
        arena.settle(id);
        assertEq(arena.rounds(id).prizePerWinner, 45 ether);
        assertEq(arena.payoutOf(id, alice), 145 ether);
    }

    /// @dev Whatever the choices and answer, a settled entry pays 80, 90 or 100 + share, so the loss is
    /// bounded by MAX_LOSS and never stacks; and a cancelled entry pays 102.
    function testFuzz_payoutBounds(uint8 choices, uint8 aliceChoice, bool aliceReveals, uint256 answer, uint96 prize)
        public
    {
        choices = uint8(bound(choices, 2, 255));
        aliceChoice = uint8(bound(aliceChoice, 1, choices));
        prize = uint96(bound(prize, 0, 10_000 ether));
        uint256 id = createRound(Arena.Mode.VaultRaid, choices, prize, 0);
        enter(id, alice, aliceChoice);
        skip(1 hours);
        if (aliceReveals) reveal(id, alice, aliceChoice);
        skip(1 hours);
        attest(id, answer, uint64(block.timestamp));
        arena.settle(id);
        uint256 payout = arena.payoutOf(id, alice);
        uint8 winning = uint8(answer % choices) + 1;
        if (!aliceReveals) {
            assertEq(payout, 80 ether);
        } else if (aliceChoice != winning) {
            assertEq(payout, 90 ether);
        } else {
            assertEq(payout, 100 ether + prize);
        }
        assertGe(payout + arena.MAX_LOSS(), 102 ether, "loss never exceeds 22 PRIO");
        vm.prank(alice);
        arena.claim(id);
        assertEq(token.balanceOf(alice), 10_000 ether - 102 ether + payout);
        accounted();
    }

    function testFuzz_prizeSplitNeverExceedsPrize(uint8 winners, uint96 prize) public {
        winners = uint8(bound(winners, 1, 20));
        prize = uint96(bound(prize, 0, 10_000 ether));
        uint256 id = createRound(Arena.Mode.VaultRaid, 2, prize, 0);
        address[] memory players = new address[](winners);
        for (uint256 i; i < winners; i++) {
            players[i] = address(uint160(0x5000 + i));
            token.transfer(players[i], 102 ether);
            enter(id, players[i], 1);
        }
        skip(1 hours);
        for (uint256 i; i < winners; i++) {
            reveal(id, players[i], 1);
        }
        skip(1 hours);
        attest(id, 0, uint64(block.timestamp)); // 0 % 2 + 1 = 1
        arena.settle(id);
        uint256 per = arena.rounds(id).prizePerWinner;
        assertLe(per * winners, prize);
        assertLt(prize - per * winners, winners, "dust is less than one wei per winner");
        uint256 paid;
        for (uint256 i; i < winners; i++) {
            vm.prank(players[i]);
            arena.claim(id);
            paid += token.balanceOf(players[i]);
        }
        assertEq(paid, winners * 100 ether + per * winners);
        assertEq(arena.totalEscrowed(), 0);
        assertEq(arena.lockedPrizes(), 0);
        accounted();
    }

    // ------------------------------------------------------------------ the result source is frozen before entry

    /// @dev A round cannot open without its question, and the pin's `notBefore` must equal the commit deadline
    /// to the second: one second either way is refused, so the adapter can never store an answer while
    /// commitments are still open.
    function test_createRoundRefusesMissingOrMisalignedPin() public {
        uint64 commitDeadline = uint64(vm.getBlockTimestamp() + 1 hours);
        uint256 next = arena.roundCount() + 1;
        vm.startPrank(owner);
        vm.expectRevert(Arena.QuestionNotPinned.selector);
        arena.createRound(
            Arena.Mode.VaultRaid, 4, commitDeadline, commitDeadline + 1 hours, commitDeadline + 2 hours, 0, 0, 0
        );
        adapter.pinQuestion(next, QUESTION, 1, 5, 4, commitDeadline, "");
        vm.expectRevert(Arena.QuestionNotPinned.selector);
        arena.createRound(
            Arena.Mode.VaultRaid, 4, commitDeadline - 1, commitDeadline + 1 hours, commitDeadline + 2 hours, 0, 0, 0
        );
        vm.expectRevert(Arena.QuestionNotPinned.selector);
        arena.createRound(
            Arena.Mode.VaultRaid, 4, commitDeadline + 1, commitDeadline + 1 hours, commitDeadline + 2 hours, 0, 0, 0
        );
        uint256 id = arena.createRound(
            Arena.Mode.VaultRaid, 4, commitDeadline, commitDeadline + 1 hours, commitDeadline + 2 hours, 0, 0, 0
        );
        vm.stopPrank();
        assertEq(id, next);
        Arena.Round memory r = arena.rounds(id);
        assertEq(address(r.oracle), address(adapter));
        assertEq(r.questionHash, QUESTION);
        // The same pin cannot be reused for the next round (ids are sequential, pins are per id).
        vm.prank(owner);
        vm.expectRevert(Arena.QuestionNotPinned.selector);
        arena.createRound(
            Arena.Mode.VaultRaid, 4, commitDeadline, commitDeadline + 1 hours, commitDeadline + 2 hours, 0, 0, 0
        );
    }

    /// @dev After the grace, `cancel` and `settle` are exclusive: a result stored after the grace flips the
    /// round from cancellable to settle-only in the same second, and a cancelled round rejects a late result.
    function test_cancelAndSettleAreExclusiveAfterTheGrace() public {
        uint256 id = createRound(Arena.Mode.VaultRaid, 4, 10 ether, 0);
        enter(id, alice, 1);
        Arena.Round memory r = arena.rounds(id);
        vm.warp(uint256(r.resultDeadline) + 72 hours);
        assertFalse(arena.resolved(id));
        // Resolved at the last moment: cancel is refused, settle works.
        attest(id, 0, uint64(block.timestamp));
        assertTrue(arena.resolved(id));
        vm.expectRevert(Arena.RoundResolved.selector);
        arena.cancel(id);
        arena.settle(id);
        assertEq(arena.payoutOf(id, alice), 80 ether, "alice never revealed");

        // A second round cancelled first: the result that arrives later cannot settle it.
        uint256 id2 = createRound(Arena.Mode.VaultRaid, 4, 10 ether, 0);
        enter(id2, bob, 2);
        r = arena.rounds(id2);
        vm.warp(uint256(r.resultDeadline) + 72 hours);
        arena.cancel(id2);
        attest(id2, 0, uint64(block.timestamp));
        vm.expectRevert(Arena.NotOpen.selector);
        arena.settle(id2);
        assertEq(arena.payoutOf(id2, bob), 102 ether);
        assertFalse(arena.resolved(id2) && arena.rounds(id2).state == Arena.RoundState.Open);
        accounted();
    }

    function test_fundPrizesZeroIsHarmless() public {
        uint256 pool = arena.unallocatedPrizePool();
        vm.prank(funder);
        arena.fundPrizes(0);
        assertEq(arena.unallocatedPrizePool(), pool);
        accounted();
    }
}
