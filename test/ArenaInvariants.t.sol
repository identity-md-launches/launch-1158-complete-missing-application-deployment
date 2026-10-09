// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PrismRiotToken} from "../src/PrismRiotToken.sol";
import {Arena, IRoundOracle} from "../src/Arena.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

/// @dev Full-lifecycle Arena handler: rounds are created, entered, revealed, settled through real signed
/// attestations on the OracleAdapter, cancelled, claimed and refunded in random order across many rounds.
/// Ghost variables record every payout so the published scoring can be checked per entry.
contract ArenaHandler is Test {
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    bytes32 constant QUESTION = keccak256("q");

    PrismRiotToken token;
    Arena arena;
    OracleAdapter adapter;
    address owner;
    address[] players;

    // ghosts
    uint256 public ghostEntries;
    uint256 public ghostPaidOut; // PRIO paid to players by claims and refunds
    uint256 public ghostEntryCost; // PRIO pulled from players
    uint256 public ghostFunded;
    uint256 public ghostClaims;
    uint256 public ghostRefunds;
    uint256 public ghostSettled;
    uint256 public ghostCancelled;
    mapping(uint256 => Arena.RoundState) public finalState;
    mapping(uint256 => uint8) public finalWinning;
    mapping(uint256 => uint256) public finalPerWinner;
    mapping(uint256 => uint256) public prizeOf;

    constructor(PrismRiotToken t, Arena a, OracleAdapter o, address owner_) {
        token = t;
        arena = a;
        adapter = o;
        owner = owner_;
    }

    function seed() external {
        for (uint256 i; i < 5; i++) {
            address p = address(uint160(0x3000 + i));
            players.push(p);
            token.transfer(p, 50_000 ether);
            vm.prank(p);
            token.approve(address(arena), type(uint256).max);
        }
    }

    function _player(uint256 who) internal view returns (address) {
        return players[who % players.length];
    }

    function _salt(uint256 id, address who) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, who));
    }

    // ------------------------------------------------------------------ owner

    function createRound(uint8 mode, uint8 choices, uint256 prize, uint16 threshold, uint256 commitIn) external {
        mode = uint8(bound(mode, 0, 2));
        choices = mode == 1 ? 2 : uint8(bound(choices, 2, 6));
        prize = bound(prize, 0, arena.unallocatedPrizePool());
        commitIn = bound(commitIn, 1 hours, 1 days);
        uint64 commitDeadline = uint64(block.timestamp + commitIn);
        vm.startPrank(owner);
        adapter.pinQuestion(arena.roundCount() + 1, QUESTION, 1, 5, 4, commitDeadline, "");
        uint256 id = arena.createRound(
            Arena.Mode(mode),
            choices,
            commitDeadline,
            commitDeadline + 1 hours,
            commitDeadline + 2 hours,
            prize,
            threshold,
            keccak256(abi.encode(arena.roundCount() + 1))
        );
        vm.stopPrank();
        prizeOf[id] = prize;
    }

    function fund(uint256 amount) external {
        amount = bound(amount, 0, 1_000 ether);
        if (token.balanceOf(address(this)) < amount) return;
        token.approve(address(arena), amount);
        arena.fundPrizes(amount);
        ghostFunded += amount;
    }

    // ------------------------------------------------------------------ players

    function enter(uint256 who, uint256 id, uint8 choice) external {
        if (arena.roundCount() == 0) return;
        id = bound(id, 1, arena.roundCount());
        address p = _player(who);
        Arena.Round memory r = arena.rounds(id);
        if (r.state != Arena.RoundState.Open || block.timestamp >= r.commitDeadline) return;
        if (arena.entries(id, p).commitment != bytes32(0)) return;
        if (token.balanceOf(p) < 102 ether) return;
        choice = uint8(bound(choice, 1, r.choiceCount));
        uint256 before = token.balanceOf(p);
        // Computed first: an external view call as an argument would consume the prank.
        bytes32 commitment = arena.commitmentOf(id, p, choice, _salt(id, p));
        vm.prank(p);
        arena.enter(id, commitment);
        assertEq(before - token.balanceOf(p), 102 ether, "exactly 102 PRIO pulled");
        ghostEntries++;
        ghostEntryCost += 102 ether;
    }

    function reveal(uint256 who, uint256 id, uint8 choice) external {
        if (arena.roundCount() == 0) return;
        id = bound(id, 1, arena.roundCount());
        address p = _player(who);
        Arena.Round memory r = arena.rounds(id);
        if (r.state != Arena.RoundState.Open) return;
        if (block.timestamp < r.commitDeadline || block.timestamp >= r.revealDeadline) return;
        Arena.Entry memory e = arena.entries(id, p);
        if (e.commitment == bytes32(0) || e.choice != 0) return;
        // Find the committed choice (the handler knows the salt); try each possible choice.
        for (uint8 c = 1; c <= r.choiceCount; c++) {
            if (arena.commitmentOf(id, p, c, _salt(id, p)) == e.commitment) {
                vm.prank(p);
                arena.reveal(id, c, _salt(id, p));
                return;
            }
        }
        choice;
    }

    function settle(uint256 id, uint256 answer) external {
        if (arena.roundCount() == 0) return;
        id = bound(id, 1, arena.roundCount());
        Arena.Round memory r = arena.rounds(id);
        if (r.state != Arena.RoundState.Open || block.timestamp < r.revealDeadline) return;
        if (!adapter.resultOf(id).settled) {
            OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
                requestId: keccak256(abi.encode("req", id, answer, block.timestamp)),
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
            (uint8 v, bytes32 rr, bytes32 s) = vm.sign(SIGNER_KEY, adapter.attestationDigest(a));
            vm.prank(owner);
            adapter.submitAttestation(id, a, abi.encodePacked(rr, s, v));
        }
        arena.settle(id);
        Arena.Round memory after_ = arena.rounds(id);
        finalState[id] = Arena.RoundState.Settled;
        finalWinning[id] = after_.winningChoice;
        finalPerWinner[id] = after_.prizePerWinner;
        assertLe(after_.prizePerWinner * after_.correct, r.prize, "never pays more than the funded prize");
        ghostSettled++;
    }

    function cancel(uint256 id) external {
        if (arena.roundCount() == 0) return;
        id = bound(id, 1, arena.roundCount());
        Arena.Round memory r = arena.rounds(id);
        if (r.state != Arena.RoundState.Open || block.timestamp < uint256(r.resultDeadline) + 72 hours) return;
        arena.cancel(id);
        finalState[id] = Arena.RoundState.Cancelled;
        ghostCancelled++;
    }

    function claimOrRefund(uint256 who, uint256 id) external {
        if (arena.roundCount() == 0) return;
        id = bound(id, 1, arena.roundCount());
        address p = _player(who);
        Arena.Round memory r = arena.rounds(id);
        Arena.Entry memory e = arena.entries(id, p);
        if (e.commitment == bytes32(0) || e.claimed) return;
        uint256 before = token.balanceOf(p);
        uint256 expected = arena.payoutOf(id, p);
        if (r.state == Arena.RoundState.Settled) {
            vm.prank(p);
            arena.claim(id);
            ghostClaims++;
            uint256 got = token.balanceOf(p) - before;
            assertEq(got, expected);
            if (e.choice == 0) assertEq(got, 80 ether, "missed reveal returns 80");
            else if (e.choice != r.winningChoice) assertEq(got, 90 ether, "wrong returns 90");
            else assertEq(got, 100 ether + r.prizePerWinner, "correct returns escrow plus share");
            assertGe(got + 22 ether, 102 ether, "max loss 22");
            ghostPaidOut += got;
        } else if (r.state == Arena.RoundState.Cancelled) {
            vm.prank(p);
            arena.refund(id);
            ghostRefunds++;
            assertEq(token.balanceOf(p) - before, 102 ether, "cancel refunds fee and escrow");
            ghostPaidOut += 102 ether;
        }
    }

    function warp(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 10 minutes, 4 days));
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 60
contract ArenaInvariantsTest is Test {
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    PrismRiotToken token;
    Arena arena;
    OracleAdapter adapter;
    ArenaHandler handler;
    address owner = makeAddr("owner");

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new PrismRiotToken();
        arena = new Arena(owner, address(token));
        adapter = new OracleAdapter(owner, SIGNER);
        vm.prank(owner);
        arena.setOracle(IRoundOracle(address(adapter)));
        handler = new ArenaHandler(token, arena, adapter, owner);
        token.transfer(address(handler), 2_000_000 ether);
        handler.seed();
        handler.fund(5_000 ether);
        handler.createRound(0, 4, 500 ether, 0, 2 hours);

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](8);
        sels[0] = ArenaHandler.createRound.selector;
        sels[1] = ArenaHandler.fund.selector;
        sels[2] = ArenaHandler.enter.selector;
        sels[3] = ArenaHandler.reveal.selector;
        sels[4] = ArenaHandler.settle.selector;
        sels[5] = ArenaHandler.cancel.selector;
        sels[6] = ArenaHandler.claimOrRefund.selector;
        sels[7] = ArenaHandler.warp.selector;
        targetSelector(FuzzSelector(address(handler), sels));
    }

    /// @dev Every PRIO the Arena holds is escrow, a locked prize or the game pool.
    function invariant_balanceFullyAccounted() public view {
        assertEq(
            token.balanceOf(address(arena)), arena.totalEscrowed() + arena.lockedPrizes() + arena.unallocatedPrizePool()
        );
    }

    /// @dev What came in equals what is held plus what went out.
    function invariant_tokenConservation() public view {
        assertEq(
            handler.ghostFunded() + handler.ghostEntryCost(), token.balanceOf(address(arena)) + handler.ghostPaidOut()
        );
    }

    /// @dev Locked prizes are exactly the prizes of the rounds still open; finished rounds never reopen or
    /// change their result.
    function invariant_roundsAreFrozenOnceFinished() public view {
        uint256 locked;
        for (uint256 id = 1; id <= arena.roundCount(); id++) {
            Arena.Round memory r = arena.rounds(id);
            assertEq(r.prize, handler.prizeOf(id), "prize frozen at creation");
            if (r.state == Arena.RoundState.Open) {
                locked += r.prize;
            } else {
                assertEq(uint256(r.state), uint256(handler.finalState(id)), "a finished round never changes state");
                if (r.state == Arena.RoundState.Settled) {
                    assertEq(r.winningChoice, handler.finalWinning(id));
                    assertEq(r.prizePerWinner, handler.finalPerWinner(id));
                }
            }
        }
        assertEq(arena.lockedPrizes(), locked);
    }

    /// @dev Players as a group can never take out more than they put in plus every prize ever funded.
    function invariant_playersNeverExtractMoreThanFunded() public view {
        assertLe(handler.ghostPaidOut(), handler.ghostEntryCost() + handler.ghostFunded());
    }
}
