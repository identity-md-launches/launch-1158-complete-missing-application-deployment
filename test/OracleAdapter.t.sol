// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {OracleAdapter, IIntake} from "../src/OracleAdapter.sol";
import {PrismRiotToken} from "../src/PrismRiotToken.sol";
import {MockIntake} from "./utils/MockIntake.sol";

/// @dev The protocol's conformance vector (oracle-consumer skill) plus the adapter's own rules.
contract OracleAdapterTest is Test {
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";
    bytes32 constant QUESTION = keccak256("which vault holds the prism?");

    address owner = makeAddr("owner");
    address executor = makeAddr("executor");
    OracleAdapter adapter;
    MockIntake intake;
    PrismRiotToken imd;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        intake = new MockIntake();
        imd = new PrismRiotToken();
        bytes memory creation = abi.encodePacked(type(OracleAdapter).creationCode, abi.encode(owner, SIGNER));
        vm.etch(VECTOR_CONSUMER, creation);
        (bool ok, bytes memory runtime) = VECTOR_CONSUMER.call("");
        require(ok, "adapter constructor reverted");
        vm.etch(VECTOR_CONSUMER, runtime);
        adapter = OracleAdapter(VECTOR_CONSUMER);
        vm.startPrank(owner);
        adapter.setIntake(IIntake(address(intake)));
        adapter.pinQuestion(1, QUESTION, 1, 5, 4, ISSUED_AT - 1 hours, bytes('{"v":1}'));
        vm.stopPrank();
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function roundAnswer(uint256 answer) internal pure returns (OracleAttestation.Attestation memory a) {
        a = vector();
        a.requestId = keccak256(abi.encode("round", answer));
        a.questionHash = QUESTION;
        a.answerType = OracleAttestation.ANSWER_UINT256;
        a.answer = abi.encode(answer);
    }

    function sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, adapter.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------------------ conformance

    function test_digestMatchesTheProtocol() public view {
        assertEq(adapter.attestationDigest(vector()), VECTOR_DIGEST, "struct, type string or domain differs");
    }

    function test_callbackSelectorIsCanonical() public view {
        assertEq(adapter.onOracleResult.selector, bytes4(keccak256(bytes(CALLBACK))));
    }

    // ------------------------------------------------------------------ manual relay

    function test_manualRelayStoresResultAndEvidence() public {
        OracleAttestation.Attestation memory a = roundAnswer(7);
        bytes memory sig = sign(a);
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);
        OracleAdapter.Result memory r = adapter.resultOf(1);
        assertTrue(r.settled);
        assertEq(r.answer, 7);
        assertEq(r.panelJobId, a.panelJobId);
        assertEq(r.requestId, a.requestId);
        assertEq(r.toBlock, 200);
        assertTrue(adapter.consumed(a.requestId));
    }

    function test_relayRejectsReplayAndSecondResult() public {
        OracleAttestation.Attestation memory a = roundAnswer(7);
        bytes memory sig = sign(a);
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.AlreadySettled.selector, 1));
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);
        vm.prank(owner);
        adapter.pinQuestion(2, QUESTION, 1, 5, 4, ISSUED_AT - 1 hours, "");
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumerErrors.AlreadyConsumed.selector, a.requestId));
        vm.prank(owner);
        adapter.submitAttestation(2, a, sig);
    }

    function test_relayRejectsWrongQuestionChainQuorumPanelSignerExpiryAndType() public {
        OracleAttestation.Attestation memory a = roundAnswer(1);
        bytes memory sig;
        a.questionHash = keccak256("other");
        sig = sign(a);
        vm.expectRevert(OracleAdapter.QuestionMismatch.selector);
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);

        a = roundAnswer(1);
        a.chainId = 2;
        sig = sign(a);
        vm.expectRevert(OracleAdapter.ChainMismatch.selector);
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);

        a = roundAnswer(1);
        a.agreed = 3;
        sig = sign(a);
        vm.expectRevert(OracleAdapter.NotAgreed.selector);
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);

        a = roundAnswer(1);
        a.quorum = 3;
        a.agreed = 3;
        sig = sign(a);
        vm.expectRevert(OracleAdapter.QuorumTooSmall.selector);
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);

        a = roundAnswer(1);
        a.panelSize = 4;
        sig = sign(a);
        vm.expectRevert(OracleAdapter.PanelTooSmall.selector);
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);

        a = roundAnswer(1);
        sig = sign(a);
        a.figure = 1; // tampered after signing
        vm.expectRevert(OracleAttestationConsumerErrors.BadSignature.selector);
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);

        a = roundAnswer(1);
        sig = sign(a);
        vm.warp(EXPIRES_AT + 1);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumerErrors.AttestationExpired.selector, EXPIRES_AT));
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);
        vm.warp(ISSUED_AT);

        a = roundAnswer(1);
        a.answerType = OracleAttestation.ANSWER_BOOL;
        a.answer = abi.encode(true);
        sig = sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumerErrors.WrongAnswerType.selector, 3, 0));
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);

        a = roundAnswer(1);
        a.issuedAt = ISSUED_AT - 2 hours; // before the commit boundary minus tolerance
        sig = sign(a);
        vm.expectRevert(
            abi.encodeWithSelector(OracleAdapter.IssuedTooEarly.selector, ISSUED_AT - 2 hours, ISSUED_AT - 1 hours)
        );
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);

        a = roundAnswer(1);
        sig = sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.QuestionNotPinned.selector, 9));
        vm.prank(owner);
        adapter.submitAttestation(9, a, sig);
    }

    // ------------------------------------------------------------------ paid requests

    function configurePaid() internal {
        vm.startPrank(owner);
        adapter.setAction(bytes32("oracle.request@oracle-1"));
        adapter.setPayment(address(imd), 0.5 ether);
        adapter.setCallbackConfigured(true);
        adapter.setExecutor(executor);
        adapter.setBudget(1 ether);
        vm.stopPrank();
        imd.transfer(address(adapter), 5 ether);
    }

    function test_paidRequestDisabledUntilConfigured() public {
        assertFalse(adapter.paidRequestsEnabled());
        vm.prank(owner);
        adapter.setExecutor(executor);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NotConfigured.selector, "paid requests"));
        adapter.request(1);
    }

    function test_paidRequestThenCallbackUnder200kGas() public {
        configurePaid();
        vm.prank(executor);
        bytes32 id = adapter.request(1);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        assertEq(adapter.pendingRound(id), 1);
        OracleAttestation.Attestation memory a = roundAnswer(3);
        bool ok = intake.deliver(abi.encode(id, a, sign(a)));
        assertTrue(ok, "callback must fit the stipend");
        assertEq(adapter.resultOf(1).answer, 3);
        assertEq(adapter.pendingSince(id), 0);
    }

    function test_callbackRefusesWrongSenderAndUnknownId() public {
        configurePaid();
        vm.prank(executor);
        bytes32 id = adapter.request(1);
        OracleAttestation.Attestation memory a = roundAnswer(3);
        bytes memory sig = sign(a);
        vm.expectRevert(OracleAdapter.NotTheIntake.selector);
        adapter.onOracleResult(id, a, sig);
        vm.prank(address(intake));
        vm.expectRevert(OracleAdapter.UnknownRequest.selector);
        adapter.onOracleResult(keccak256("nope"), a, sig);
    }

    function test_budgetAndExecutorEnforced() public {
        configurePaid();
        vm.prank(address(this));
        vm.expectRevert(OracleAdapter.NotExecutor.selector);
        adapter.request(1);
        // One request per round is open at a time, so the budget is exercised across rounds.
        vm.startPrank(owner);
        adapter.pinQuestion(2, QUESTION, 1, 5, 4, ISSUED_AT - 1 hours, "");
        adapter.pinQuestion(3, QUESTION, 1, 5, 4, ISSUED_AT - 1 hours, "");
        adapter.pinQuestion(4, QUESTION, 1, 5, 4, ISSUED_AT - 1 hours, "");
        vm.stopPrank();
        vm.startPrank(executor);
        adapter.request(1);
        adapter.request(2);
        vm.expectRevert(OracleAdapter.BudgetExceeded.selector);
        adapter.request(3);
        skip(1 days);
        adapter.request(3);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.RequestPending.selector, 3));
        adapter.request(3);
        vm.stopPrank();
    }

    /// @dev Finding d260feaf: any attestation for the pinned question used to settle the round, so whoever
    /// bought and relayed a second panel answer first chose the result. Now an attestation settles a round
    /// from any relayer only when it answers this adapter's own request; others need the executor or owner.
    function test_competingAttestationCannotBeRelayedByAStranger_ownRequestCanBeRelayedByAnyone() public {
        configurePaid();
        vm.prank(executor);
        bytes32 id = adapter.request(1);
        assertEq(adapter.openRequest(1), id);
        // A player buys their own answer to the public question and tries to relay it first.
        OracleAttestation.Attestation memory bought = roundAnswer(2);
        bytes memory boughtSig = sign(bought);
        vm.prank(makeAddr("player"));
        vm.expectRevert(OracleAdapter.NotRelayer.selector);
        adapter.submitAttestation(1, bought, boughtSig);
        assertFalse(adapter.resultOf(1).settled);
        // The answer to the adapter's own request carries its request id: anyone may relay it.
        OracleAttestation.Attestation memory own = roundAnswer(1);
        own.requestId = id;
        bytes memory ownSig = sign(own);
        vm.prank(makeAddr("anyone"));
        adapter.submitAttestation(1, own, ownSig);
        assertEq(adapter.resultOf(1).answer, 1);
        assertEq(adapter.openRequest(1), bytes32(0), "the open request is closed by its answer");
        assertEq(adapter.pendingSince(id), 0);
        // The bought answer can no longer be used by anyone, trusted or not.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.AlreadySettled.selector, 1));
        adapter.submitAttestation(1, bought, boughtSig);
    }

    function test_ownRequestIdForAnotherRoundIsNotAFreePass() public {
        configurePaid();
        vm.prank(owner);
        adapter.pinQuestion(2, QUESTION, 1, 5, 4, ISSUED_AT - 1 hours, "");
        vm.prank(executor);
        bytes32 id = adapter.request(2);
        OracleAttestation.Attestation memory a = roundAnswer(5);
        a.requestId = id;
        bytes memory sig = sign(a);
        // The request was for round 2; relaying its answer into round 1 is a stranger's relay.
        vm.prank(makeAddr("anyone"));
        vm.expectRevert(OracleAdapter.NotRelayer.selector);
        adapter.submitAttestation(1, a, sig);
        // The executor may relay an attestation it obtained off chain (HTTP door) for any round.
        OracleAttestation.Attestation memory offChain = roundAnswer(8);
        bytes memory offSig = sign(offChain);
        vm.prank(executor);
        adapter.submitAttestation(1, offChain, offSig);
        assertEq(adapter.resultOf(1).answer, 8);
    }

    function test_secondRequestForAnOpenRoundIsRefusedUntilAnsweredOrCleared() public {
        configurePaid();
        vm.prank(executor);
        bytes32 id = adapter.request(1);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.RequestPending.selector, 1));
        adapter.request(1);
        skip(2 days);
        adapter.clearStale(id);
        assertEq(adapter.openRequest(1), bytes32(0));
        vm.prank(executor);
        bytes32 second = adapter.request(1);
        assertTrue(second != id);
        OracleAttestation.Attestation memory a = roundAnswer(4);
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
        assertTrue(intake.deliver(abi.encode(second, a, sign(a))), "the callback answers the open request");
        assertEq(adapter.openRequest(1), bytes32(0));
        assertEq(imd.balanceOf(address(intake)), 1 ether, "two answers were paid for, not three");
    }

    /// @dev Finding 0fb49e68: a pin whose `notBefore` can never match a future round blocked every round.
    function test_mistakenPinCanBeReplacedUntilTheArenaCreatesTheRound() public {
        ArenaStub stub = new ArenaStub();
        vm.startPrank(owner);
        // Without a configured Arena the pin stays immutable (conservative default).
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.AlreadyPinned.selector, 1));
        adapter.pinQuestion(1, QUESTION, 1, 5, 4, ISSUED_AT + 1 days, "");
        adapter.setArena(address(stub));
        // Round 1 not created yet (roundCount 0): the pin can be corrected.
        adapter.pinQuestion(1, keccak256("corrected"), 1, 6, 5, ISSUED_AT + 1 days, "body");
        assertEq(adapter.pinned(1).questionHash, keccak256("corrected"));
        assertEq(adapter.pinned(1).notBefore, ISSUED_AT + 1 days);
        // Once the Arena has created it, the pin is frozen.
        stub.set(1);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.AlreadyPinned.selector, 1));
        adapter.pinQuestion(1, QUESTION, 1, 5, 4, ISSUED_AT + 2 days, "");
        // A round the Arena has not created takes no paid request (finding 615b6c64); once created, an open
        // request freezes the pin too.
        adapter.pinQuestion(2, QUESTION, 1, 5, 4, ISSUED_AT - 1 hours, "");
        vm.stopPrank();
        configurePaid();
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.RoundNotCreated.selector, 2));
        adapter.request(2);
        stub.set(2);
        vm.prank(executor);
        adapter.request(2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.AlreadyPinned.selector, 2));
        adapter.pinQuestion(2, keccak256("x"), 1, 5, 4, ISSUED_AT - 1 hours, "");
    }

    /// @dev Finding 04dbc34c: re-pointing `setArena` at a contract reporting fewer rounds made the pin of an
    /// open round replaceable. The Arena is one-shot.
    function test_setArenaIsOneShot() public {
        ArenaStub stub = new ArenaStub();
        ArenaStub empty = new ArenaStub();
        vm.startPrank(owner);
        vm.expectRevert(OracleAdapter.ZeroAddress.selector);
        adapter.setArena(address(0));
        adapter.setArena(address(stub));
        stub.set(1);
        vm.expectRevert(OracleAdapter.ArenaAlreadySet.selector);
        adapter.setArena(address(empty));
        vm.expectRevert(OracleAdapter.ArenaAlreadySet.selector);
        adapter.setArena(address(stub));
        assertEq(adapter.arena(), address(stub));
        // The pin consumed by round 1 stays what it was, whatever the owner tries.
        adapter.setSigner(makeAddr("rogue"));
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.AlreadyPinned.selector, 1));
        adapter.pinQuestion(1, keccak256("rogue"), 1, 5, 4, ISSUED_AT - 1 hours, "");
        vm.stopPrank();
        assertEq(adapter.pinned(1).questionHash, QUESTION);
        assertEq(adapter.pinned(1).signer, SIGNER);
    }

    /// @dev Finding 615b6c64: a result stored for a pinned round the Arena had not created could never be
    /// undone and made that id (and every later one) impossible to create. With an Arena configured, neither
    /// a relay nor the Intake callback stores a result for an uncreated round, and the pin stays replaceable.
    function test_noResultForARoundTheArenaHasNotCreated_pinStaysReplaceable() public {
        ArenaStub stub = new ArenaStub();
        vm.startPrank(owner);
        adapter.setArena(address(stub));
        adapter.setExecutor(executor);
        adapter.pinQuestion(2, QUESTION, 1, 5, 4, ISSUED_AT + 1 hours, "");
        vm.stopPrank();
        vm.warp(ISSUED_AT + 1 hours); // the commit deadline lapses before the round is created
        OracleAttestation.Attestation memory a = roundAnswer(9);
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
        bytes memory sig = sign(a);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.RoundNotCreated.selector, 2));
        adapter.submitAttestation(2, a, sig);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.RoundNotCreated.selector, 2));
        adapter.submitAttestation(2, a, sig);
        assertFalse(adapter.resultOf(2).settled);
        assertFalse(adapter.consumed(a.requestId), "a refused attestation is not consumed");
        // The owner re-pins for a new commit deadline; once the Arena has created the round the same
        // attestation (if still valid) settles it.
        vm.prank(owner);
        adapter.pinQuestion(2, QUESTION, 1, 5, 4, uint64(block.timestamp + 1 hours), "");
        assertEq(adapter.pinned(2).notBefore, uint64(block.timestamp + 1 hours));
        stub.set(2);
        vm.warp(block.timestamp + 1 hours);
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
        sig = sign(a);
        vm.prank(owner);
        adapter.submitAttestation(2, a, sig);
        assertEq(adapter.resultOf(2).answer, 9);
        // Round 1 (created, roundCount >= 1) is unaffected: the fixture's past-boundary pin still accepts.
        stub.set(2);
        OracleAttestation.Attestation memory b = roundAnswer(4);
        b.issuedAt = uint64(block.timestamp);
        b.expiresAt = uint64(block.timestamp + 1 hours);
        bytes memory sigB = sign(b);
        vm.prank(owner);
        adapter.submitAttestation(1, b, sigB);
        assertEq(adapter.resultOf(1).answer, 4);
    }

    /// @dev Finding 615b6c64, Intake side: the callback for a round the Arena has not created reverts, so
    /// the request stays pending (and can be answered once the round exists, or cleared as stale).
    function test_intakeCallbackForAnUncreatedRoundIsRefused() public {
        ArenaStub stub = new ArenaStub();
        configurePaid();
        vm.startPrank(owner);
        adapter.setArena(address(stub));
        adapter.pinQuestion(2, QUESTION, 1, 5, 4, ISSUED_AT - 1 hours, "");
        vm.stopPrank();
        stub.set(2);
        vm.prank(executor);
        bytes32 id = adapter.request(2);
        stub.set(1); // a stub only: a real Arena's roundCount never decreases
        OracleAttestation.Attestation memory a = roundAnswer(3);
        assertFalse(intake.deliver(abi.encode(id, a, sign(a))), "callback refused for an uncreated round");
        assertEq(adapter.openRequest(2), id, "the request is still pending");
        stub.set(2);
        assertTrue(intake.deliver(abi.encode(id, a, sign(a))));
        assertEq(adapter.resultOf(2).answer, 3);
    }

    /// @dev Finding 02cf1770: rotating `asset` with `setPayment` made the IMD bought for agent work
    /// withdrawable. Every token ever configured as the asset is refused by `withdrawToken`.
    function test_withdrawTokenRefusesEveryFormerAsset() public {
        configurePaid();
        PrismRiotToken other = new PrismRiotToken();
        vm.startPrank(owner);
        adapter.setPayment(address(other), 1);
        assertTrue(adapter.wasAsset(address(imd)));
        vm.expectRevert(OracleAdapter.AssetNotWithdrawable.selector);
        adapter.withdrawToken(address(imd), owner, 1 ether);
        adapter.setPayment(address(imd), 0.5 ether);
        vm.expectRevert(OracleAdapter.AssetNotWithdrawable.selector);
        adapter.withdrawToken(address(other), owner, 0);
        vm.stopPrank();
        assertEq(imd.balanceOf(address(adapter)), 5 ether, "the IMD bought for agent work stays");
    }

    // ------------------------------------------------------------------ the commit boundary

    /// @dev Finding f3ad4c90: a valid answer issued inside the tolerance before the boundary was stored early.
    function test_nothingIsStoredOrRequestedBeforeTheBoundary() public {
        uint64 boundary = ISSUED_AT + 1 hours;
        vm.prank(owner);
        adapter.pinQuestion(2, QUESTION, 1, 5, 4, boundary, "");
        vm.warp(boundary - 4 minutes);
        OracleAttestation.Attestation memory a = roundAnswer(6);
        a.issuedAt = uint64(block.timestamp);
        bytes memory sig = sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.BeforeBoundary.selector, boundary));
        vm.prank(owner);
        adapter.submitAttestation(2, a, sig);
        assertFalse(adapter.resultOf(2).settled);
        configurePaid();
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.BeforeBoundary.selector, boundary));
        adapter.request(2);
        // At the boundary both work, and the issued-at skew tolerance still applies.
        vm.warp(boundary);
        vm.prank(executor);
        adapter.request(2);
        vm.prank(owner);
        adapter.submitAttestation(2, a, sig);
        assertEq(adapter.resultOf(2).answer, 6);
    }

    function test_pinnedSignerOutlivesRotation() public {
        OracleAttestation.Attestation memory a = roundAnswer(4);
        bytes memory sig = sign(a);
        vm.prank(owner);
        adapter.setSigner(makeAddr("rotated"));
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);
        assertEq(adapter.resultOf(1).answer, 4);
        // A question pinned after the rotation needs the new signer.
        vm.prank(owner);
        adapter.pinQuestion(3, QUESTION, 1, 5, 4, ISSUED_AT - 1, "");
        a = roundAnswer(5);
        sig = sign(a);
        vm.expectRevert(OracleAttestationConsumerErrors.BadSignature.selector);
        vm.prank(owner);
        adapter.submitAttestation(3, a, sig);
    }

    function test_withdrawTokenRefusesTheConfiguredAsset() public {
        configurePaid();
        vm.startPrank(owner);
        vm.expectRevert(OracleAdapter.AssetNotWithdrawable.selector);
        adapter.withdrawToken(address(imd), owner, 1 ether);
        PrismRiotToken stray = new PrismRiotToken();
        stray.transfer(address(adapter), 1 ether);
        adapter.withdrawToken(address(stray), owner, 1 ether);
        vm.stopPrank();
        assertEq(stray.balanceOf(address(adapter)), 0);
        assertEq(imd.balanceOf(address(adapter)), 5 ether, "the IMD bought for agent work stays");
    }

    function test_clearStaleAfterTimeout() public {
        configurePaid();
        vm.prank(executor);
        bytes32 id = adapter.request(1);
        vm.expectRevert(OracleAdapter.RequestNotStale.selector);
        adapter.clearStale(id);
        skip(2 days);
        adapter.clearStale(id);
        assertEq(adapter.pendingSince(id), 0);
    }
}

/// @dev Stands in for the Arena's `roundCount()`.
contract ArenaStub {
    uint256 public roundCount;

    function set(uint256 n) external {
        roundCount = n;
    }
}

/// @dev The base contract's errors, for `expectRevert` selectors.
interface OracleAttestationConsumerErrors {
    error AlreadyConsumed(bytes32 requestId);
    error AttestationExpired(uint64 expiresAt);
    error BadSignature();
    error WrongAnswerType(uint8 expected, uint8 got);
}
