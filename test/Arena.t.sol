// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PrismRiotToken} from "../src/PrismRiotToken.sol";
import {Arena, IRoundOracle} from "../src/Arena.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

contract ArenaTest is Test {
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    bytes32 constant QUESTION = keccak256("round question");
    uint64 constant T0 = 1_800_000_000;

    PrismRiotToken token;
    Arena arena;
    OracleAdapter adapter;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.warp(T0);
        token = new PrismRiotToken();
        arena = new Arena(owner, address(token));
        adapter = new OracleAdapter(owner, SIGNER);
        vm.prank(owner);
        arena.setOracle(IRoundOracle(address(adapter)));
        address[3] memory players = [alice, bob, carol];
        for (uint256 i; i < players.length; i++) {
            token.transfer(players[i], 1_000 ether);
            vm.prank(players[i]);
            token.approve(address(arena), 102 ether);
        }
        token.transfer(treasury, 10_000 ether);
        vm.startPrank(treasury);
        token.approve(address(arena), type(uint256).max);
        arena.fundPrizes(1_000 ether);
        vm.stopPrank();
    }

    function createRound(Arena.Mode mode, uint8 choices, uint256 prize, uint16 threshold)
        internal
        returns (uint256 id)
    {
        uint64 commitDeadline = uint64(block.timestamp + 1 hours);
        vm.startPrank(owner);
        // The question is pinned first, for the id the next round will get; creation refuses otherwise.
        adapter.pinQuestion(arena.roundCount() + 1, QUESTION, 1, 5, 4, commitDeadline, "");
        id = arena.createRound(
            mode,
            choices,
            commitDeadline,
            commitDeadline + 1 hours,
            commitDeadline + 2 hours,
            prize,
            threshold,
            keccak256("rules v1")
        );
        vm.stopPrank();
        assertEq(address(arena.rounds(id).oracle), address(adapter));
        assertEq(arena.rounds(id).questionHash, QUESTION);
    }

    function enter(uint256 id, address who, uint8 choice) internal returns (bytes32 salt) {
        salt = keccak256(abi.encode(who, id));
        bytes32 c = arena.commitmentOf(id, who, choice, salt);
        vm.prank(who);
        arena.enter(id, c);
    }

    function reveal(uint256 id, address who, uint8 choice) internal {
        vm.prank(who);
        arena.reveal(id, choice, keccak256(abi.encode(who, id)));
    }

    function attest(uint256 id, uint256 answer) internal {
        Arena.Round memory r = arena.rounds(id);
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("req", id)),
            chainId: 1,
            questionHash: QUESTION,
            answerType: OracleAttestation.ANSWER_UINT256,
            answer: abi.encode(answer),
            figure: 0,
            fromBlock: 1,
            toBlock: 2,
            blockHash: bytes32(uint256(1)),
            panelJobId: keccak256(abi.encode("job", id)),
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: r.commitDeadline,
            expiresAt: uint64(block.timestamp + 1 days)
        });
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(SIGNER_KEY, adapter.attestationDigest(a));
        vm.prank(owner);
        adapter.submitAttestation(id, a, abi.encodePacked(rr, s, v));
    }

    function balanceInvariant() internal view {
        assertEq(
            token.balanceOf(address(arena)),
            arena.totalEscrowed() + arena.lockedPrizes() + arena.unallocatedPrizePool(),
            "every PRIO in the arena is escrow, a locked prize or the game pool"
        );
    }

    // ------------------------------------------------------------------ lifecycle

    function test_vaultRaidFullLifecycle() public {
        uint256 id = createRound(Arena.Mode.VaultRaid, 4, 300 ether, 0);
        assertEq(arena.lockedPrizes(), 300 ether);
        enter(id, alice, 3); // correct: answer 6 % 4 + 1 = 3
        enter(id, bob, 1); // wrong
        enter(id, carol, 3); // correct but never reveals
        assertEq(token.balanceOf(alice), 898 ether);
        balanceInvariant();

        skip(1 hours);
        reveal(id, alice, 3);
        reveal(id, bob, 1);
        vm.expectRevert(Arena.RevealNotOver.selector);
        arena.settle(id);
        skip(1 hours);
        vm.expectRevert(Arena.NoResult.selector);
        arena.settle(id);

        attest(id, 6);
        arena.settle(id);
        Arena.Round memory r = arena.rounds(id);
        assertEq(uint256(r.state), uint256(Arena.RoundState.Settled));
        assertEq(r.winningChoice, 3);
        assertEq(r.correct, 1);
        assertEq(r.prizePerWinner, 300 ether);
        balanceInvariant();

        assertEq(arena.payoutOf(id, alice), 400 ether);
        assertEq(arena.payoutOf(id, bob), 90 ether);
        assertEq(arena.payoutOf(id, carol), 80 ether);
        vm.prank(alice);
        arena.claim(id);
        vm.prank(bob);
        arena.claim(id);
        vm.prank(carol);
        arena.claim(id);
        assertEq(token.balanceOf(alice), 1_298 ether);
        assertEq(token.balanceOf(bob), 988 ether);
        assertEq(token.balanceOf(carol), 978 ether);
        // fees 3*2 + penalties 10 + 20 feed the game pool
        assertEq(arena.unallocatedPrizePool(), 700 ether + 36 ether);
        assertEq(arena.totalEscrowed(), 0);
        balanceInvariant();

        vm.prank(alice);
        vm.expectRevert(Arena.AlreadyClaimed.selector);
        arena.claim(id);
    }

    function test_oldRoundStaysClaimableAfterNewRounds() public {
        uint256 first = createRound(Arena.Mode.FactionDuel, 2, 100 ether, 0);
        enter(first, alice, 2);
        skip(1 hours);
        reveal(first, alice, 2);
        skip(1 hours);
        attest(first, 1); // 1 % 2 + 1 = 2
        arena.settle(first);
        uint256 second = createRound(Arena.Mode.VaultRaid, 3, 50 ether, 0);
        vm.prank(bob);
        token.approve(address(arena), 102 ether);
        enter(second, bob, 1);
        skip(30 days);
        vm.prank(alice);
        arena.claim(first);
        assertEq(token.balanceOf(alice), 1_000 ether - 102 ether + 100 ether + 100 ether);
        balanceInvariant();
    }

    function test_bossChallengeNeedsThreshold() public {
        uint256 id = createRound(Arena.Mode.BossChallenge, 3, 300 ether, 2);
        enter(id, alice, 2);
        enter(id, bob, 1);
        skip(1 hours);
        reveal(id, alice, 2);
        reveal(id, bob, 1);
        skip(1 hours);
        attest(id, 1); // winning 2; only alice correct, threshold 2 -> no prize
        arena.settle(id);
        assertEq(arena.payoutOf(id, alice), 100 ether);
        assertEq(arena.payoutOf(id, bob), 90 ether);
        assertEq(arena.unallocatedPrizePool(), 1_000 ether, "prize returned to the game pool");
        balanceInvariant();
    }

    function test_noWinnerReturnsPrizeToPool() public {
        uint256 id = createRound(Arena.Mode.VaultRaid, 4, 200 ether, 0);
        enter(id, alice, 1);
        skip(2 hours);
        attest(id, 2); // winning 3
        arena.settle(id);
        assertEq(arena.rounds(id).prizePerWinner, 0);
        assertEq(arena.unallocatedPrizePool(), 1_000 ether);
        vm.prank(alice);
        arena.claim(id);
        assertEq(
            token.balanceOf(alice),
            1_000 ether - 102 ether + 80 ether,
            "missed reveal: 80 back, never stacked with wrong"
        );
        balanceInvariant();
    }

    function test_cancelAfter72hRefundsEverything() public {
        uint256 id = createRound(Arena.Mode.VaultRaid, 4, 200 ether, 0);
        enter(id, alice, 1);
        enter(id, bob, 2);
        skip(2 hours);
        vm.expectRevert(Arena.NotCancellable.selector);
        arena.cancel(id);
        skip(72 hours); // 72h after the reveal deadline is still inside the grace after the result deadline
        vm.expectRevert(Arena.NotCancellable.selector);
        arena.cancel(id);
        skip(1 hours);
        arena.cancel(id);
        vm.expectRevert(Arena.NotSettled.selector);
        arena.claim(id);
        vm.prank(alice);
        vm.expectRevert(Arena.NotCancelled.selector);
        arena.refund(1_000);
        vm.prank(alice);
        arena.refund(id);
        vm.prank(bob);
        arena.refund(id);
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(bob), 1_000 ether);
        assertEq(arena.unallocatedPrizePool(), 1_000 ether);
        assertEq(arena.lockedPrizes(), 0);
        balanceInvariant();
        // A result arriving late cannot resurrect a cancelled round.
        attest(id, 0);
        vm.expectRevert(Arena.NotOpen.selector);
        arena.settle(id);
    }

    // ------------------------------------------------------------------ failures

    function test_entryRules() public {
        uint256 id = createRound(Arena.Mode.VaultRaid, 4, 0, 0);
        enter(id, alice, 1);
        vm.prank(alice);
        vm.expectRevert(Arena.AlreadyEntered.selector);
        arena.enter(id, bytes32(uint256(1)));
        vm.prank(alice);
        vm.expectRevert(Arena.NotSettled.selector);
        arena.claim(id);
        // Only 102 PRIO is ever pulled: a second entry would need another approval.
        assertEq(token.allowance(alice, address(arena)), 0);
        skip(1 hours);
        vm.prank(bob);
        vm.expectRevert(Arena.CommitClosed.selector);
        arena.enter(id, bytes32(uint256(1)));
        vm.prank(alice);
        vm.expectRevert(Arena.BadReveal.selector);
        arena.reveal(id, 2, keccak256(abi.encode(alice, id)));
        vm.prank(alice);
        vm.expectRevert(Arena.BadChoice.selector);
        arena.reveal(id, 9, keccak256(abi.encode(alice, id)));
        reveal(id, alice, 1);
        vm.prank(alice);
        vm.expectRevert(Arena.AlreadyRevealed.selector);
        arena.reveal(id, 1, keccak256(abi.encode(alice, id)));
        skip(1 hours);
        vm.prank(alice);
        vm.expectRevert(Arena.RevealWindowClosed.selector);
        arena.reveal(id, 1, keccak256(abi.encode(alice, id)));
    }

    function test_roundCreationRules() public {
        vm.startPrank(owner);
        vm.expectRevert(Arena.PrizeNotFunded.selector);
        arena.createRound(
            Arena.Mode.VaultRaid,
            4,
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 2),
            uint64(block.timestamp + 3),
            5_000 ether,
            0,
            0
        );
        vm.expectRevert(Arena.BadDeadlines.selector);
        arena.createRound(
            Arena.Mode.VaultRaid,
            4,
            uint64(block.timestamp + 2),
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 3),
            0,
            0,
            0
        );
        vm.expectRevert(Arena.BadChoices.selector);
        arena.createRound(
            Arena.Mode.FactionDuel,
            3,
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 2),
            uint64(block.timestamp + 3),
            0,
            0,
            0
        );
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert();
        arena.createRound(
            Arena.Mode.VaultRaid,
            4,
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 2),
            uint64(block.timestamp + 3),
            0,
            0,
            0
        );
    }

    function test_resultIssuedBeforeCommitBoundaryCannotSettle() public {
        uint256 id = createRound(Arena.Mode.VaultRaid, 4, 0, 0);
        enter(id, alice, 1);
        skip(2 hours);
        // Pin a second round whose question allows an early answer, to show the Arena's own check.
        Arena.Round memory r = arena.rounds(id);
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: keccak256("early"),
            chainId: 1,
            questionHash: QUESTION,
            answerType: OracleAttestation.ANSWER_UINT256,
            answer: abi.encode(1),
            figure: 0,
            fromBlock: 1,
            toBlock: 2,
            blockHash: bytes32(0),
            panelJobId: bytes32(0),
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: r.commitDeadline - 10 minutes,
            expiresAt: uint64(block.timestamp + 1 days)
        });
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(SIGNER_KEY, adapter.attestationDigest(a));
        vm.expectRevert();
        vm.prank(owner);
        adapter.submitAttestation(id, a, abi.encodePacked(rr, s, v));
    }

    function test_constantsPublished() public view {
        assertEq(arena.ENTRY_COST(), 102 ether);
        assertEq(arena.MAX_LOSS(), 22 ether);
        assertEq(arena.CANCEL_GRACE(), 72 hours);
    }

    // ------------------------------------------------------------------ frozen result source

    function test_createRoundNeedsPinnedQuestionAtTheCommitBoundary() public {
        uint64 commitDeadline = uint64(block.timestamp + 1 hours);
        vm.startPrank(owner);
        vm.expectRevert(Arena.QuestionNotPinned.selector);
        arena.createRound(Arena.Mode.VaultRaid, 4, commitDeadline, commitDeadline + 1, commitDeadline + 2, 0, 0, 0);
        // Pinned, but with a boundary that is not the round's commit deadline: refused too.
        adapter.pinQuestion(1, QUESTION, 1, 5, 4, commitDeadline + 1, "");
        vm.expectRevert(Arena.QuestionNotPinned.selector);
        arena.createRound(Arena.Mode.VaultRaid, 4, commitDeadline, commitDeadline + 1, commitDeadline + 2, 0, 0, 0);
        arena.createRound(Arena.Mode.VaultRaid, 4, commitDeadline + 1, commitDeadline + 2, commitDeadline + 3, 0, 0, 0);
        vm.stopPrank();
        assertEq(arena.roundCount(), 1);
    }

    /// @dev Finding 4309f6e9: the owner could point the Arena at another oracle after reveals.
    function test_ownerCannotSwapOracleForAnOpenRound() public {
        uint256 id = createRound(Arena.Mode.FactionDuel, 2, 300 ether, 0);
        enter(id, alice, 2);
        enter(id, bob, 1);
        skip(1 hours);
        reveal(id, alice, 2);
        reveal(id, bob, 1);
        skip(1 hours);
        FakeOracle fake = new FakeOracle();
        vm.prank(owner);
        arena.setOracle(IRoundOracle(address(fake)));
        vm.expectRevert(Arena.NoResult.selector);
        arena.settle(id);
        // The real adapter's result still settles it, with the oracle the round opened with.
        attest(id, 1); // winning 2
        arena.settle(id);
        assertEq(arena.payoutOf(id, alice), 400 ether);
        assertEq(arena.payoutOf(id, bob), 90 ether);
        // A later `setOracle` is for rounds created after it; an existing round keeps its own.
        vm.prank(owner);
        arena.setOracle(IRoundOracle(address(adapter)));
        uint256 second = createRound(Arena.Mode.FactionDuel, 2, 0, 0);
        vm.prank(owner);
        arena.setOracle(IRoundOracle(address(fake)));
        assertEq(address(arena.rounds(second).oracle), address(adapter), "a round keeps the oracle it opened with");
        assertEq(address(arena.oracle()), address(fake));
    }

    function test_signerRotationDoesNotReachPinnedRounds() public {
        uint256 id = createRound(Arena.Mode.FactionDuel, 2, 0, 0);
        enter(id, alice, 1);
        vm.prank(owner);
        adapter.setSigner(makeAddr("newSigner"));
        skip(2 hours);
        attest(id, 0); // signed by the signer pinned with the question: accepted
        arena.settle(id);
        assertEq(arena.rounds(id).winningChoice, 1);
    }

    /// @dev Finding ac9ccf02: after the grace, cancel and settle were both live on a round with a result.
    function test_resolvedRoundCannotBeCancelled_onlySettled() public {
        uint256 id = createRound(Arena.Mode.FactionDuel, 2, 300 ether, 0);
        enter(id, alice, 2);
        enter(id, bob, 1);
        skip(1 hours);
        reveal(id, alice, 2);
        reveal(id, bob, 1);
        skip(2 hours + 72 hours); // past the result deadline's grace
        attest(id, 1); // winning 2, relayed late
        assertTrue(arena.resolved(id));
        vm.prank(bob);
        vm.expectRevert(Arena.RoundResolved.selector);
        arena.cancel(id);
        arena.settle(id);
        assertEq(arena.payoutOf(id, alice), 400 ether);
        assertEq(arena.payoutOf(id, bob), 90 ether);
    }

    function test_unresolvedRoundCancelsAndALateResultCannotSettleIt() public {
        uint256 id = createRound(Arena.Mode.FactionDuel, 2, 300 ether, 0);
        enter(id, alice, 2);
        skip(3 hours + 72 hours);
        assertFalse(arena.resolved(id));
        arena.cancel(id);
        attest(id, 1);
        vm.expectRevert(Arena.NotOpen.selector);
        arena.settle(id);
        assertEq(arena.payoutOf(id, alice), 102 ether);
    }

    /// @dev Finding 064e2296: nothing capped `resultDeadline`, so escrow could sit in a round with no reachable
    /// cancel path. A round runs at most `MAX_ROUND_LENGTH` from its commit deadline to its result deadline.
    function test_roundLengthIsCapped() public {
        uint64 commitDeadline = uint64(block.timestamp + 1 hours);
        uint64 max = commitDeadline + uint64(arena.MAX_ROUND_LENGTH());
        vm.startPrank(owner);
        adapter.pinQuestion(1, QUESTION, 1, 5, 4, commitDeadline, "");
        vm.expectRevert(Arena.BadDeadlines.selector);
        arena.createRound(Arena.Mode.VaultRaid, 4, commitDeadline, commitDeadline + 1 hours, max + 1, 0, 0, 0);
        vm.expectRevert(Arena.BadDeadlines.selector);
        arena.createRound(
            Arena.Mode.VaultRaid, 4, commitDeadline, commitDeadline + 1 hours, type(uint64).max - 1 days, 0, 0, 0
        );
        uint256 id = arena.createRound(Arena.Mode.VaultRaid, 4, commitDeadline, commitDeadline + 1 hours, max, 0, 0, 0);
        vm.stopPrank();
        enter(id, alice, 1);
        // The cancel path is always reachable: 30 days + 72 hours after the commit deadline at the latest.
        vm.warp(uint256(max) + arena.CANCEL_GRACE());
        arena.cancel(id);
        assertEq(arena.payoutOf(id, alice), 102 ether);
    }

    /// @dev Finding 04dbc34c (Arena side): the Arena checks for itself that the adapter still pins the question
    /// the round was created against. A result for any other question never settles the round; it is
    /// cancelled and refunded instead.
    function test_settleRefusesARoundWhosePinnedQuestionChanged() public {
        MutableOracle fake = new MutableOracle();
        vm.prank(owner);
        arena.setOracle(IRoundOracle(address(fake)));
        uint64 commitDeadline = uint64(block.timestamp + 1 hours);
        fake.pin(QUESTION, commitDeadline);
        vm.prank(owner);
        uint256 id = arena.createRound(
            Arena.Mode.FactionDuel,
            2,
            commitDeadline,
            commitDeadline + 1 hours,
            commitDeadline + 2 hours,
            300 ether,
            0,
            0
        );
        enter(id, alice, 2);
        skip(1 hours);
        reveal(id, alice, 2);
        skip(1 hours);
        fake.pin(keccak256("rogue question"), commitDeadline);
        fake.answer(0, commitDeadline); // winning = 1: Alice would lose
        assertFalse(arena.resolved(id), "a result for another question does not resolve the round");
        vm.expectRevert(Arena.QuestionChanged.selector);
        arena.settle(id);
        // Restored, the real result settles it as created.
        fake.pin(QUESTION, commitDeadline);
        fake.answer(1, commitDeadline); // winning = 2
        assertTrue(arena.resolved(id));
        arena.settle(id);
        assertEq(arena.payoutOf(id, alice), 400 ether);
        balanceInvariant();
    }
}

/// @dev An oracle whose pin and result the test controls: what a misconfigured or rogue adapter looks like.
contract MutableOracle is IRoundOracle {
    Pinned internal _p;
    Result internal _r;

    function pin(bytes32 questionHash, uint64 notBefore) external {
        _p.questionHash = questionHash;
        _p.notBefore = notBefore;
    }

    function answer(uint256 value, uint64 issuedAt) external {
        _r.answer = value;
        _r.issuedAt = issuedAt;
        _r.settled = true;
    }

    function resultOf(uint256) external view returns (Result memory) {
        return _r;
    }

    function pinned(uint256) external view returns (Pinned memory) {
        return _p;
    }

    function ISSUED_AT_TOLERANCE() external pure returns (uint64) {
        return 5 minutes;
    }
}

/// @dev An oracle that answers nothing: what a swapped-in result source looks like to an open round.
contract FakeOracle is IRoundOracle {
    function resultOf(uint256) external pure returns (Result memory r) {}

    function pinned(uint256) external pure returns (Pinned memory p) {
        p.questionHash = keccak256("fake");
        p.notBefore = type(uint64).max;
    }

    function ISSUED_AT_TOLERANCE() external pure returns (uint64) {
        return 5 minutes;
    }
}
