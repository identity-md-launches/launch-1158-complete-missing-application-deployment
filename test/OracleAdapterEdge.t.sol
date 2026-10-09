// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {OracleAdapter, IIntake} from "../src/OracleAdapter.sol";
import {PrismRiotToken} from "../src/PrismRiotToken.sol";
import {MockIntake} from "./utils/MockIntake.sol";

interface ConsumerErrors {
    error AttestationNotYetValid(uint64 issuedAt);
    error BadSignature();
    error ZeroSigner();
    error AlreadyConsumed(bytes32 requestId);
}

/// @dev The adapter's remaining failure paths: not-yet-valid clocks, pinning rules, unconfigured or unfunded
/// paid requests, a callback that arrives after a manual relay, the budget window edge, signer rotation,
/// a signer that is a contract, and wrong-key or malformed signatures.
contract OracleAdapterEdgeTest is Test {
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant OTHER_KEY = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint64 constant T0 = 1_800_000_000;
    bytes32 constant QUESTION = keccak256("q");

    address owner = makeAddr("owner");
    address executor = makeAddr("executor");
    OracleAdapter adapter;
    MockIntake intake;
    PrismRiotToken imd;

    function setUp() public {
        vm.warp(T0);
        intake = new MockIntake();
        imd = new PrismRiotToken();
        adapter = new OracleAdapter(owner, SIGNER);
        vm.startPrank(owner);
        adapter.setIntake(IIntake(address(intake)));
        adapter.pinQuestion(1, QUESTION, 1, 5, 4, T0 - 1 hours, "");
        vm.stopPrank();
    }

    function att(uint256 answer) internal view returns (OracleAttestation.Attestation memory a) {
        a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("r", answer)),
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
            agreed: 4,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 hours)
        });
    }

    function signWith(uint256 k, OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(k, adapter.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function configurePaid() internal {
        vm.startPrank(owner);
        adapter.setAction(bytes32("oracle.request@oracle-1"));
        adapter.setPayment(address(imd), 0.5 ether);
        adapter.setCallbackConfigured(true);
        adapter.setExecutor(executor);
        adapter.setBudget(1 ether);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ clock

    function test_issuedInTheFutureBeyondToleranceIsRefused_andWithinToleranceAccepted() public {
        OracleAttestation.Attestation memory a = att(1);
        a.issuedAt = uint64(block.timestamp) + 5 minutes + 1;
        a.expiresAt = a.issuedAt + 1 hours;
        bytes memory sig = signWith(SIGNER_KEY, a);
        uint64 issued = a.issuedAt;
        vm.expectRevert(abi.encodeWithSelector(ConsumerErrors.AttestationNotYetValid.selector, issued));
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);
        a.issuedAt = uint64(block.timestamp) + 5 minutes;
        sig = signWith(SIGNER_KEY, a);
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);
        assertTrue(adapter.resultOf(1).settled);
    }

    function test_expiryBoundaryIsInclusive() public {
        OracleAttestation.Attestation memory a = att(1);
        bytes memory sig = signWith(SIGNER_KEY, a);
        vm.warp(a.expiresAt);
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);
        assertTrue(adapter.resultOf(1).settled);
    }

    // ------------------------------------------------------------------ signatures

    function test_wrongKeyAndMalformedSignaturesRefused() public {
        OracleAttestation.Attestation memory a = att(1);
        bytes memory wrongKey = signWith(OTHER_KEY, a);
        vm.expectRevert(ConsumerErrors.BadSignature.selector);
        vm.prank(owner);
        adapter.submitAttestation(1, a, wrongKey);
        vm.expectRevert(ConsumerErrors.BadSignature.selector);
        vm.prank(owner);
        adapter.submitAttestation(1, a, hex"");
        vm.expectRevert(ConsumerErrors.BadSignature.selector);
        vm.prank(owner);
        adapter.submitAttestation(1, a, hex"deadbeef");
        bytes memory sig = signWith(SIGNER_KEY, a);
        sig[0] = bytes1(uint8(sig[0]) ^ 0xff);
        vm.expectRevert(ConsumerErrors.BadSignature.selector);
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);
        assertFalse(adapter.resultOf(1).settled);
    }

    /// @dev Rotation is forward-only: a round pinned under the old signer keeps it (the new key cannot sign
    /// for it), and a round pinned after the rotation accepts only the new key. Zero is refused.
    function test_signerRotationRevokesOldSigner_andZeroRefused() public {
        address newSigner = vm.addr(OTHER_KEY);
        vm.prank(owner);
        vm.expectRevert(ConsumerErrors.ZeroSigner.selector);
        adapter.setSigner(address(0));
        vm.prank(executor);
        vm.expectRevert();
        adapter.setSigner(newSigner);
        vm.prank(owner);
        adapter.setSigner(newSigner);
        assertEq(adapter.oracleSigner(), newSigner);
        assertEq(adapter.pinned(1).signer, SIGNER, "round 1 keeps the signer it was pinned with");

        // Round 1: pinned before the rotation. The new key is a stranger to it; the old key still settles it.
        OracleAttestation.Attestation memory a = att(1);
        bytes memory aByNew = signWith(OTHER_KEY, a);
        bytes memory aByOld = signWith(SIGNER_KEY, a);
        vm.expectRevert(ConsumerErrors.BadSignature.selector);
        vm.prank(owner);
        adapter.submitAttestation(1, a, aByNew);
        vm.prank(owner);
        adapter.submitAttestation(1, a, aByOld);
        assertTrue(adapter.resultOf(1).settled);

        // Round 2: pinned after the rotation. The old key is revoked for it.
        vm.prank(owner);
        adapter.pinQuestion(2, QUESTION, 1, 5, 4, T0 - 1 hours, "");
        assertEq(adapter.pinned(2).signer, newSigner);
        OracleAttestation.Attestation memory b = att(2);
        bytes memory bByOld = signWith(SIGNER_KEY, b);
        bytes memory bByNew = signWith(OTHER_KEY, b);
        vm.expectRevert(ConsumerErrors.BadSignature.selector);
        vm.prank(owner);
        adapter.submitAttestation(2, b, bByOld);
        vm.prank(owner);
        adapter.submitAttestation(2, b, bByNew);
        assertTrue(adapter.resultOf(2).settled);
    }

    /// @dev The chain clock gate is exact: one second before `notBefore` nothing is stored, at it the same
    /// attestation (issued within the tolerance) is.
    function test_boundaryIsInclusiveOnTheChainClock() public {
        uint64 notBefore = T0 + 1 hours;
        vm.prank(owner);
        adapter.pinQuestion(2, QUESTION, 1, 5, 4, notBefore, "");
        OracleAttestation.Attestation memory a = att(7);
        a.issuedAt = notBefore - 5 minutes;
        a.expiresAt = notBefore + 1 days;
        bytes memory sig = signWith(SIGNER_KEY, a);
        vm.warp(notBefore - 1);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.BeforeBoundary.selector, notBefore));
        vm.prank(owner);
        adapter.submitAttestation(2, a, sig);
        assertFalse(adapter.resultOf(2).settled);
        vm.warp(notBefore);
        vm.prank(owner);
        adapter.submitAttestation(2, a, sig);
        assertTrue(adapter.resultOf(2).settled);
    }

    /// @dev A paid request is gated by the same clock, and a request refused for the clock spends nothing.
    function test_requestRefusedBeforeBoundarySpendsNothing() public {
        configurePaid();
        imd.transfer(address(adapter), 1 ether);
        uint64 notBefore = T0 + 1 hours;
        vm.prank(owner);
        adapter.pinQuestion(2, QUESTION, 1, 5, 4, notBefore, "");
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.BeforeBoundary.selector, notBefore));
        adapter.request(2);
        assertEq(adapter.spentInWindow(), 0);
        assertEq(imd.balanceOf(address(adapter)), 1 ether);
        vm.warp(notBefore);
        vm.prank(executor);
        adapter.request(2);
        assertEq(adapter.spentInWindow(), 0.5 ether);
    }

    /// @dev The same attestation cannot settle two rounds, even if both pin the same question.
    function test_oneAttestationSettlesOneRoundOnly() public {
        vm.prank(owner);
        adapter.pinQuestion(2, QUESTION, 1, 5, 4, T0 - 1 hours, "");
        OracleAttestation.Attestation memory a = att(1);
        bytes memory sig = signWith(SIGNER_KEY, a);
        vm.prank(owner);
        adapter.submitAttestation(2, a, sig);
        vm.expectRevert(abi.encodeWithSelector(ConsumerErrors.AlreadyConsumed.selector, a.requestId));
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);
    }

    // ------------------------------------------------------------------ pinning

    function test_pinningRules() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.AlreadyPinned.selector, 1));
        adapter.pinQuestion(1, QUESTION, 1, 5, 4, 0, "");
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NotConfigured.selector, "question"));
        adapter.pinQuestion(2, bytes32(0), 1, 5, 4, 0, "");
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NotConfigured.selector, "question"));
        adapter.pinQuestion(2, QUESTION, 1, 5, 1, 0, "");
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NotConfigured.selector, "question"));
        adapter.pinQuestion(2, QUESTION, 1, 3, 4, 0, "");
        adapter.pinQuestion(2, QUESTION, 1, 4, 4, 0, "");
        vm.stopPrank();
        vm.prank(executor);
        vm.expectRevert();
        adapter.pinQuestion(3, QUESTION, 1, 5, 4, 0, "");
        OracleAdapter.Pinned memory p = adapter.pinned(2);
        assertEq(p.minPanel, 4);
        assertEq(p.minQuorum, 4);
    }

    function test_configurationIsOwnerOnly() public {
        vm.startPrank(executor);
        vm.expectRevert();
        adapter.setIntake(IIntake(address(1)));
        vm.expectRevert();
        adapter.setAction(bytes32("x"));
        vm.expectRevert();
        adapter.setPayment(address(imd), 1);
        vm.expectRevert();
        adapter.setCallbackConfigured(true);
        vm.expectRevert();
        adapter.setExecutor(executor);
        vm.expectRevert();
        adapter.setBudget(1);
        vm.expectRevert();
        adapter.withdrawToken(address(imd), executor, 1);
        vm.stopPrank();
        vm.prank(owner);
        vm.expectRevert(OracleAdapter.ZeroAddress.selector);
        adapter.setIntake(IIntake(address(0)));
        vm.prank(owner);
        vm.expectRevert(OracleAdapter.ZeroAddress.selector);
        adapter.setPayment(address(0), 1);
    }

    // ------------------------------------------------------------------ paid requests

    /// @dev Each missing piece of configuration keeps paid requests off; only the full set turns them on.
    function test_everyConfigurationPieceIsRequired() public {
        configurePaid();
        assertTrue(adapter.paidRequestsEnabled());
        vm.startPrank(owner);
        adapter.setCallbackConfigured(false);
        assertFalse(adapter.paidRequestsEnabled());
        adapter.setCallbackConfigured(true);
        adapter.setBudget(0);
        assertFalse(adapter.paidRequestsEnabled());
        adapter.setBudget(1 ether);
        adapter.setExecutor(address(0));
        assertFalse(adapter.paidRequestsEnabled());
        adapter.setExecutor(executor);
        adapter.setAction(bytes32(0));
        assertFalse(adapter.paidRequestsEnabled());
        adapter.setAction(bytes32("a"));
        adapter.setPayment(address(imd), 0);
        assertFalse(adapter.paidRequestsEnabled());
        adapter.setPayment(address(imd), 0.5 ether);
        assertTrue(adapter.paidRequestsEnabled());
        vm.stopPrank();
    }

    function test_requestWithoutImdBalanceReverts_noIncomeNoOperations() public {
        configurePaid();
        assertEq(imd.balanceOf(address(adapter)), 0);
        vm.prank(executor);
        vm.expectRevert();
        adapter.request(1);
        assertEq(adapter.spentInWindow(), 0, "a failed request spends nothing");
    }

    function test_requestRefusesUnpinnedAndSettledRounds() public {
        configurePaid();
        imd.transfer(address(adapter), 5 ether);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.QuestionNotPinned.selector, 7));
        adapter.request(7);
        OracleAttestation.Attestation memory a = att(1);
        bytes memory sig = signWith(SIGNER_KEY, a);
        vm.prank(owner);
        adapter.submitAttestation(1, a, sig);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.AlreadySettled.selector, 1));
        adapter.request(1);
    }

    /// @dev A manual relay lands first; the paid callback for the same round then fails and is cleared
    /// as stale later. The result is the one that was verified first and it never changes.
    function test_callbackAfterManualRelayCannotOverwrite() public {
        configurePaid();
        imd.transfer(address(adapter), 5 ether);
        vm.prank(executor);
        bytes32 id = adapter.request(1);
        OracleAttestation.Attestation memory manual = att(3);
        bytes memory manualSig = signWith(SIGNER_KEY, manual);
        vm.prank(owner);
        adapter.submitAttestation(1, manual, manualSig);
        OracleAttestation.Attestation memory late = att(9);
        bool ok = intake.deliver(abi.encode(id, late, signWith(SIGNER_KEY, late)));
        assertFalse(ok, "the callback reverts: round already settled");
        assertEq(adapter.resultOf(1).answer, 3);
        assertEq(adapter.pendingRound(id), 1, "still pending until cleared");
        skip(2 days);
        adapter.clearStale(id);
        assertEq(adapter.pendingSince(id), 0);
        vm.expectRevert(OracleAdapter.RequestNotStale.selector);
        adapter.clearStale(id);
    }

    function test_callbackWithBadAttestationLeavesRequestPending() public {
        configurePaid();
        imd.transfer(address(adapter), 5 ether);
        vm.prank(executor);
        bytes32 id = adapter.request(1);
        OracleAttestation.Attestation memory a = att(3);
        a.questionHash = keccak256("other");
        assertFalse(intake.deliver(abi.encode(id, a, signWith(SIGNER_KEY, a))), "wrong question is refused");
        a = att(3);
        assertFalse(intake.deliver(abi.encode(id, a, signWith(OTHER_KEY, a))), "wrong signer is refused");
        assertFalse(adapter.resultOf(1).settled);
        assertEq(adapter.pendingRound(id), 1);
        // The right one still lands.
        assertTrue(intake.deliver(abi.encode(id, a, signWith(SIGNER_KEY, a))));
        assertEq(adapter.resultOf(1).answer, 3);
    }

    function test_budgetWindowBoundary() public {
        configurePaid();
        imd.transfer(address(adapter), 5 ether);
        vm.startPrank(owner);
        adapter.pinQuestion(2, QUESTION, 1, 5, 4, T0 - 1 hours, "");
        adapter.pinQuestion(3, QUESTION, 1, 5, 4, T0 - 1 hours, "");
        vm.stopPrank();
        vm.startPrank(executor);
        adapter.request(1);
        uint256 start = adapter.windowStart();
        adapter.request(2);
        vm.expectRevert(OracleAdapter.BudgetExceeded.selector);
        adapter.request(3);
        vm.warp(start + 1 days - 1);
        vm.expectRevert(OracleAdapter.BudgetExceeded.selector);
        adapter.request(3);
        vm.warp(start + 1 days);
        adapter.request(3);
        assertEq(adapter.spentInWindow(), 0.5 ether);
        vm.stopPrank();
        assertEq(imd.balanceOf(address(intake)), 1.5 ether, "every request paid the price");
    }

    function test_priceChangeAppliesToNextRequest() public {
        configurePaid();
        imd.transfer(address(adapter), 5 ether);
        vm.prank(owner);
        adapter.setPayment(address(imd), 2 ether);
        vm.prank(executor);
        vm.expectRevert(OracleAdapter.BudgetExceeded.selector);
        adapter.request(1);
    }

    function test_ownerCanWithdrawTokens() public {
        imd.transfer(address(adapter), 5 ether);
        vm.prank(owner);
        adapter.withdrawToken(address(imd), owner, 5 ether);
        assertEq(imd.balanceOf(owner), 5 ether);
    }
}
