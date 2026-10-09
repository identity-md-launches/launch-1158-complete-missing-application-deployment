// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PrismRiotToken} from "../src/PrismRiotToken.sol";
import {OracleAdapter, IIntake} from "../src/OracleAdapter.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockIntake} from "./utils/MockIntake.sol";

interface ConsumerErrors {
    error AlreadyConsumed(bytes32 requestId);
    error BadSignature();
}

/// @dev Stands in for the Arena: the adapter reads nothing of it but `roundCount`.
contract ArenaStub {
    uint256 public roundCount;

    function create() external {
        roundCount++;
    }
}

/// @dev Drives the adapter, which holds the IMD bought for agent work, in random order: pins and re-pins, the
/// one-shot Arena binding, round creation at the Arena, paid requests, Intake callbacks with good and bad
/// attestations, manual relays from strangers, the executor and the owner, stale clearing, budget and price
/// changes, stray-token withdrawals and attempts on the payment asset. Both regimes are exercised: before
/// `setArena` (pins immutable, no round check) and after it (a pin is replaceable until its round exists, and
/// nothing is bought or stored for a round the Arena has not created). Ghost records hold every result the
/// moment it was stored, every pin the moment its round was created, and every IMD movement.
contract AdapterHandler is Test {
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant OTHER_KEY = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    bytes32 constant QUESTION = keccak256("q");

    OracleAdapter adapter;
    MockIntake intake;
    PrismRiotToken imd;
    PrismRiotToken stray;
    ArenaStub arenaStub;
    address owner;
    address executor;
    address stranger = makeAddr("stranger");

    uint256 public pins;
    uint256 public ghostFunded;
    uint256 public ghostSpent;
    uint256 public ghostRequests;
    uint256 public ghostResults;
    uint256 public ghostStrayIn;
    uint256 public ghostStrayOut;
    uint256 public ghostStrangerRelays;
    uint256 public ghostCreated;
    uint256 public ghostRepins;
    uint256 public ghostRepinsRefused;
    uint256 public ghostRefusedUncreated;
    uint256 boughtNonce;
    mapping(uint256 => uint256) public storedAnswer;
    mapping(uint256 => bytes32) public storedRequestId;
    /// @dev Whether the adapter had its Arena when the result was stored (only then is the round check on).
    mapping(uint256 => bool) public storedWhileArenaSet;
    mapping(uint256 => bytes32) public hashAtCreation;
    mapping(uint256 => uint64) public notBeforeAtCreation;
    bytes32[] public consumedIds;
    bytes32[] public openIds;

    constructor(
        OracleAdapter a,
        MockIntake i,
        PrismRiotToken t,
        PrismRiotToken s,
        ArenaStub r,
        address owner_,
        address executor_
    ) {
        adapter = a;
        intake = i;
        imd = t;
        stray = s;
        arenaStub = r;
        owner = owner_;
        executor = executor_;
    }

    /// @dev A round the adapter will take a result or a request for: any round before `setArena`, and after
    /// it only one the Arena has created.
    function created(uint256 roundId) public view returns (bool) {
        return adapter.arena() == address(0) || arenaStub.roundCount() >= roundId;
    }

    function consumedCount() external view returns (uint256) {
        return consumedIds.length;
    }

    function openCount() external view returns (uint256) {
        return openIds.length;
    }

    function _att(bytes32 requestId, uint256 answer, uint64 issuedAt)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        a = OracleAttestation.Attestation({
            requestId: requestId,
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
            issuedAt: issuedAt,
            expiresAt: uint64(block.timestamp + 1 days)
        });
    }

    function _sign(uint256 k, OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(k, adapter.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _record(uint256 roundId) internal {
        OracleAdapter.Result memory res = adapter.resultOf(roundId);
        storedAnswer[roundId] = res.answer;
        storedRequestId[roundId] = res.requestId;
        storedWhileArenaSet[roundId] = adapter.arena() != address(0);
        consumedIds.push(res.requestId);
        ghostResults++;
    }

    // ------------------------------------------------------------------ owner

    /// @dev Pins the next round at a boundary up to a day away; an earlier boundary is in the past already.
    function pin(uint256 inSeconds) external {
        pins++;
        uint64 notBefore = uint64(block.timestamp + bound(inSeconds, 0, 1 days));
        vm.prank(owner);
        adapter.pinQuestion(pins, QUESTION, 1, 5, 4, notBefore, "body");
    }

    /// @dev Re-pins an existing round at a new boundary. Allowed exactly when the Arena is set, has not created
    /// the round, nothing is stored for it and no request is open; refused as `AlreadyPinned` otherwise.
    function repin(uint256 which, uint256 inSeconds) external {
        if (pins == 0) return;
        uint256 roundId = bound(which, 1, pins);
        uint64 notBefore = uint64(block.timestamp + bound(inSeconds, 0, 1 days));
        bool replaceable = adapter.arena() != address(0) && arenaStub.roundCount() < roundId
            && !adapter.resultOf(roundId).settled && adapter.openRequest(roundId) == bytes32(0);
        vm.prank(owner);
        if (replaceable) {
            adapter.pinQuestion(roundId, QUESTION, 1, 5, 4, notBefore, "body");
            assertEq(adapter.pinned(roundId).notBefore, notBefore, "replaced");
            ghostRepins++;
        } else {
            vm.expectRevert(abi.encodeWithSelector(OracleAdapter.AlreadyPinned.selector, roundId));
            adapter.pinQuestion(roundId, QUESTION, 1, 5, 4, notBefore, "body");
            ghostRepinsRefused++;
        }
    }

    /// @dev The owner binds the Arena once; a second binding, to anything, is refused, as is a stranger's.
    function setArena() external {
        vm.prank(stranger);
        vm.expectRevert();
        adapter.setArena(address(arenaStub));
        bool unset = adapter.arena() == address(0);
        vm.prank(owner);
        if (unset) {
            adapter.setArena(address(arenaStub));
            assertEq(adapter.arena(), address(arenaStub));
        } else {
            vm.expectRevert(OracleAdapter.ArenaAlreadySet.selector);
            adapter.setArena(address(this));
        }
    }

    /// @dev The Arena creates its next round (only one whose question is pinned, as the real Arena requires);
    /// the pin as it stands at that moment is what the round was created against.
    function createNext() external {
        uint256 roundId = arenaStub.roundCount() + 1;
        if (roundId > pins) return;
        OracleAdapter.Pinned memory p = adapter.pinned(roundId);
        hashAtCreation[roundId] = p.questionHash;
        notBeforeAtCreation[roundId] = p.notBefore;
        arenaStub.create();
        ghostCreated++;
    }

    function fundImd(uint256 amount) external {
        amount = bound(amount, 0, 5 ether);
        if (imd.balanceOf(address(this)) < amount) return;
        imd.transfer(address(adapter), amount);
        ghostFunded += amount;
    }

    function setBudget(uint256 perWindow) external {
        perWindow = bound(perWindow, 0.5 ether, 10 ether);
        vm.prank(owner);
        adapter.setBudget(perWindow);
    }

    function setPrice(uint256 price) external {
        price = bound(price, 0.1 ether, 1 ether);
        vm.prank(owner);
        adapter.setPayment(address(imd), price);
    }

    function strayIn(uint256 amount) external {
        amount = bound(amount, 1, 10 ether);
        if (stray.balanceOf(address(this)) < amount) return;
        stray.transfer(address(adapter), amount);
        ghostStrayIn += amount;
    }

    function strayOut(uint256 amount) external {
        uint256 max = stray.balanceOf(address(adapter));
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(owner);
        adapter.withdrawToken(address(stray), owner, amount);
        ghostStrayOut += amount;
    }

    /// @dev The payment asset can never be withdrawn, by anyone, in any amount.
    function tryWithdrawImd(uint256 amount) external {
        amount = bound(amount, 0, imd.balanceOf(address(adapter)));
        vm.prank(owner);
        vm.expectRevert(OracleAdapter.AssetNotWithdrawable.selector);
        adapter.withdrawToken(address(imd), owner, amount);
        vm.prank(executor);
        vm.expectRevert();
        adapter.withdrawToken(address(imd), executor, amount);
    }

    // ------------------------------------------------------------------ executor

    function request(uint256 which) external {
        if (pins == 0) return;
        uint256 roundId = bound(which, 1, pins);
        OracleAdapter.Pinned memory p = adapter.pinned(roundId);
        if (block.timestamp < p.notBefore || adapter.resultOf(roundId).settled) return;
        if (adapter.openRequest(roundId) != bytes32(0)) return;
        if (!created(roundId)) {
            vm.prank(executor);
            vm.expectRevert(abi.encodeWithSelector(OracleAdapter.RoundNotCreated.selector, roundId));
            adapter.request(roundId);
            ghostRefusedUncreated++;
            return;
        }
        uint256 price = adapter.price();
        if (imd.balanceOf(address(adapter)) < price) return;
        if (block.timestamp < adapter.windowStart() + adapter.BUDGET_WINDOW()) {
            if (adapter.spentInWindow() + price > adapter.budgetPerWindow()) return;
        } else if (price > adapter.budgetPerWindow()) {
            return; // a fresh window still cannot afford one answer at this price
        }
        uint256 before = imd.balanceOf(address(adapter));
        vm.prank(executor);
        bytes32 id = adapter.request(roundId);
        assertEq(before - imd.balanceOf(address(adapter)), price, "exactly the price left");
        assertEq(adapter.pendingRound(id), roundId);
        assertEq(adapter.openRequest(roundId), id);
        ghostSpent += price;
        ghostRequests++;
        openIds.push(id);
    }

    function strangerCannotRequest(uint256 which) external {
        if (pins == 0) return;
        uint256 roundId = bound(which, 1, pins);
        vm.prank(stranger);
        vm.expectRevert(OracleAdapter.NotExecutor.selector);
        adapter.request(roundId);
    }

    // ------------------------------------------------------------------ results

    /// @dev The Intake answers an open request. A good attestation settles the round once; a second answer
    /// for the same round, one with the wrong key, or one for a round the Arena (bound after the request was
    /// made) has not created, is refused and leaves the request pending.
    function deliver(uint256 which, uint256 answer, bool goodKey) external {
        if (openIds.length == 0) return;
        bytes32 id = openIds[which % openIds.length];
        if (adapter.pendingSince(id) == 0) return;
        uint256 roundId = adapter.pendingRound(id);
        bool wasSettled = adapter.resultOf(roundId).settled;
        bool exists = created(roundId);
        OracleAttestation.Attestation memory a = _att(id, answer, uint64(block.timestamp));
        bool ok = intake.deliver(abi.encode(id, a, _sign(goodKey ? SIGNER_KEY : OTHER_KEY, a)));
        if (goodKey && !wasSettled && exists) {
            assertTrue(ok, "a good first answer lands under the stipend");
            assertEq(adapter.pendingSince(id), 0, "forgotten");
            assertEq(adapter.openRequest(roundId), bytes32(0));
            assertEq(adapter.resultOf(roundId).answer, answer);
            _record(roundId);
        } else {
            assertFalse(ok, "a wrong key, a second answer or an uncreated round is refused");
            assertEq(adapter.pendingRound(id), roundId, "still pending");
            if (!exists) ghostRefusedUncreated++;
        }
    }

    /// @dev Anyone may relay the answer to the adapter's own open request for the round it was made for,
    /// unless the Arena bound since has not created that round.
    function strangerRelaysOwnRequest(uint256 which, uint256 answer) external {
        if (openIds.length == 0) return;
        bytes32 id = openIds[which % openIds.length];
        if (adapter.pendingSince(id) == 0) return;
        uint256 roundId = adapter.pendingRound(id);
        if (adapter.resultOf(roundId).settled) return;
        OracleAttestation.Attestation memory a = _att(id, answer, uint64(block.timestamp));
        bytes memory sig = _sign(SIGNER_KEY, a);
        if (!created(roundId)) {
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(OracleAdapter.RoundNotCreated.selector, roundId));
            adapter.submitAttestation(roundId, a, sig);
            assertEq(adapter.openRequest(roundId), id, "the refused relay forgot nothing");
            ghostRefusedUncreated++;
            return;
        }
        vm.prank(stranger);
        adapter.submitAttestation(roundId, a, sig);
        assertEq(adapter.openRequest(roundId), bytes32(0));
        _record(roundId);
        ghostStrangerRelays++;
    }

    /// @dev A stranger relaying any other attestation, even validly signed, is always refused.
    function strangerRelaysForeign(uint256 which, uint256 answer) external {
        if (pins == 0) return;
        uint256 roundId = bound(which, 1, pins);
        OracleAttestation.Attestation memory a =
            _att(keccak256(abi.encode("foreign", which, answer)), answer, uint64(block.timestamp));
        bytes memory sig = _sign(SIGNER_KEY, a);
        vm.prank(stranger);
        vm.expectRevert(OracleAdapter.NotRelayer.selector);
        adapter.submitAttestation(roundId, a, sig);
    }

    /// @dev The owner relays a bought attestation for a round past its boundary; a second one is refused, and
    /// so is one for a round the bound Arena has not created.
    function ownerRelays(uint256 which, uint256 answer) external {
        if (pins == 0) return;
        uint256 roundId = bound(which, 1, pins);
        OracleAdapter.Pinned memory p = adapter.pinned(roundId);
        if (block.timestamp < p.notBefore) return;
        bool wasSettled = adapter.resultOf(roundId).settled;
        OracleAttestation.Attestation memory a =
            _att(keccak256(abi.encode("bought", ++boughtNonce)), answer, uint64(block.timestamp));
        bytes memory sig = _sign(SIGNER_KEY, a);
        bool exists = created(roundId);
        vm.prank(owner);
        if (wasSettled) {
            vm.expectRevert(abi.encodeWithSelector(OracleAdapter.AlreadySettled.selector, roundId));
            adapter.submitAttestation(roundId, a, sig);
        } else if (!exists) {
            vm.expectRevert(abi.encodeWithSelector(OracleAdapter.RoundNotCreated.selector, roundId));
            adapter.submitAttestation(roundId, a, sig);
            ghostRefusedUncreated++;
        } else {
            adapter.submitAttestation(roundId, a, sig);
            _record(roundId);
        }
    }

    /// @dev A consumed request id can never be accepted again, for any round, by anyone (for an uncreated
    /// round the refusal comes earlier, as `RoundNotCreated`).
    function replayConsumed(uint256 which, uint256 target) external {
        if (consumedIds.length == 0 || pins == 0) return;
        bytes32 id = consumedIds[which % consumedIds.length];
        uint256 roundId = bound(target, 1, pins);
        OracleAdapter.Pinned memory p = adapter.pinned(roundId);
        if (block.timestamp < p.notBefore || adapter.resultOf(roundId).settled) return;
        OracleAttestation.Attestation memory a = _att(id, 7, uint64(block.timestamp));
        bytes memory sig = _sign(SIGNER_KEY, a);
        bool exists = created(roundId);
        vm.prank(owner);
        if (exists) {
            vm.expectRevert(abi.encodeWithSelector(ConsumerErrors.AlreadyConsumed.selector, id));
        } else {
            vm.expectRevert(abi.encodeWithSelector(OracleAdapter.RoundNotCreated.selector, roundId));
        }
        adapter.submitAttestation(roundId, a, sig);
    }

    function clearStale(uint256 which) external {
        if (openIds.length == 0) return;
        bytes32 id = openIds[which % openIds.length];
        uint256 since = adapter.pendingSince(id);
        if (since == 0) return;
        if (block.timestamp < since + adapter.REQUEST_TIMEOUT()) {
            vm.expectRevert(OracleAdapter.RequestNotStale.selector);
            adapter.clearStale(id);
            return;
        }
        uint256 roundId = adapter.pendingRound(id);
        vm.prank(stranger);
        adapter.clearStale(id);
        assertEq(adapter.pendingSince(id), 0);
        assertEq(adapter.openRequest(roundId), bytes32(0));
    }

    function warp(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 1, 3 days));
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 50
contract OracleAdapterInvariantsTest is Test {
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    OracleAdapter adapter;
    MockIntake intake;
    PrismRiotToken imd;
    PrismRiotToken stray;
    ArenaStub arenaStub;
    AdapterHandler handler;
    address owner = makeAddr("owner");
    address executor = makeAddr("executor");

    function setUp() public {
        vm.warp(1_800_000_000);
        intake = new MockIntake();
        imd = new PrismRiotToken();
        stray = new PrismRiotToken();
        arenaStub = new ArenaStub();
        adapter = new OracleAdapter(owner, SIGNER);
        vm.startPrank(owner);
        adapter.setIntake(IIntake(address(intake)));
        adapter.setAction(bytes32("oracle.request@oracle-1"));
        adapter.setPayment(address(imd), 0.5 ether);
        adapter.setCallbackConfigured(true);
        adapter.setExecutor(executor);
        adapter.setBudget(2 ether);
        vm.stopPrank();
        handler = new AdapterHandler(adapter, intake, imd, stray, arenaStub, owner, executor);
        imd.transfer(address(handler), 1_000 ether);
        stray.transfer(address(handler), 1_000 ether);
        handler.pin(0);
        handler.fundImd(5 ether);
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](20);
        sels[17] = AdapterHandler.setArena.selector;
        sels[18] = AdapterHandler.createNext.selector;
        sels[19] = AdapterHandler.repin.selector;
        sels[0] = AdapterHandler.pin.selector;
        sels[1] = AdapterHandler.fundImd.selector;
        sels[2] = AdapterHandler.setBudget.selector;
        sels[3] = AdapterHandler.setPrice.selector;
        sels[4] = AdapterHandler.strayIn.selector;
        sels[5] = AdapterHandler.strayOut.selector;
        sels[6] = AdapterHandler.tryWithdrawImd.selector;
        sels[7] = AdapterHandler.request.selector;
        sels[8] = AdapterHandler.strangerCannotRequest.selector;
        sels[9] = AdapterHandler.deliver.selector;
        sels[10] = AdapterHandler.strangerRelaysOwnRequest.selector;
        sels[11] = AdapterHandler.strangerRelaysForeign.selector;
        sels[12] = AdapterHandler.ownerRelays.selector;
        sels[13] = AdapterHandler.replayConsumed.selector;
        sels[14] = AdapterHandler.clearStale.selector;
        sels[15] = AdapterHandler.warp.selector;
        sels[16] = AdapterHandler.request.selector;
        targetSelector(FuzzSelector(address(handler), sels));
    }

    /// @dev IMD enters only by transfer and leaves only as the price of a request: never by withdrawal.
    function invariant_imdIsSpentOnlyOnAnswers() public view {
        assertEq(imd.balanceOf(address(adapter)), handler.ghostFunded() - handler.ghostSpent());
        assertEq(imd.balanceOf(address(intake)), handler.ghostSpent(), "every request paid exactly the price");
        assertEq(stray.balanceOf(address(adapter)), handler.ghostStrayIn() - handler.ghostStrayOut());
    }

    /// @dev A stored result never changes, and its request id is consumed forever.
    function invariant_resultsAreImmutableOnceStored() public view {
        uint256 settled;
        for (uint256 id = 1; id <= handler.pins(); id++) {
            OracleAdapter.Result memory r = adapter.resultOf(id);
            if (!r.settled) continue;
            settled++;
            assertEq(r.answer, handler.storedAnswer(id), "answer frozen");
            assertEq(r.requestId, handler.storedRequestId(id), "evidence frozen");
            assertTrue(adapter.consumed(r.requestId), "request id consumed");
            OracleAdapter.Pinned memory p = adapter.pinned(id);
            assertTrue(p.questionHash != bytes32(0), "a result only exists for a pinned round");
            assertGe(uint256(r.issuedAt) + adapter.ISSUED_AT_TOLERANCE(), p.notBefore, "never older than the boundary");
            assertGe(r.agreed, p.minQuorum);
        }
        assertEq(
            settled, handler.ghostResults(), "every result was recorded when it was stored, none appeared otherwise"
        );
        for (uint256 i; i < handler.consumedCount(); i++) {
            assertTrue(adapter.consumed(handler.consumedIds(i)));
        }
    }

    /// @dev Open-request bookkeeping is consistent in both directions: at most one open request per round,
    /// and every open request points back at its round.
    function invariant_openRequestsAreConsistent() public view {
        for (uint256 id = 1; id <= handler.pins(); id++) {
            bytes32 open = adapter.openRequest(id);
            if (open == bytes32(0)) continue;
            assertEq(adapter.pendingRound(open), id, "open request points at its round");
            assertGt(adapter.pendingSince(open), 0, "and is pending");
        }
        for (uint256 i; i < handler.openCount(); i++) {
            bytes32 id = handler.openIds(i);
            if (adapter.pendingSince(id) == 0) {
                assertEq(adapter.pendingRound(id), 0, "a forgotten request keeps no round");
            } else {
                assertEq(adapter.openRequest(adapter.pendingRound(id)), id, "a pending request is its round's open one");
            }
        }
    }

    /// @dev Once the Arena is bound it never changes, and from then on no result is stored for a round it has
    /// not created: every result stored while the Arena was set belongs to a created round, so no id (and no
    /// later id, since they are sequential) can be made impossible to create by an answer on file.
    function invariant_resultsOnlyForCreatedRoundsOnceArenaIsBound() public view {
        assertEq(arenaStub.roundCount(), handler.ghostCreated());
        if (adapter.arena() == address(0)) return;
        assertEq(adapter.arena(), address(arenaStub), "one-shot");
        for (uint256 id = 1; id <= handler.pins(); id++) {
            if (!adapter.resultOf(id).settled || !handler.storedWhileArenaSet(id)) continue;
            assertLe(id, arenaStub.roundCount(), "a result stored under the Arena check belongs to a created round");
        }
    }

    /// @dev A pin is frozen from the moment its round exists: what the Arena created the round against is what
    /// the adapter still pins, so a result can only ever answer the question the players committed to.
    function invariant_pinsAreFrozenOnceTheirRoundExists() public view {
        for (uint256 id = 1; id <= arenaStub.roundCount(); id++) {
            OracleAdapter.Pinned memory p = adapter.pinned(id);
            assertEq(p.questionHash, handler.hashAtCreation(id), "question frozen");
            assertEq(p.notBefore, handler.notBeforeAtCreation(id), "boundary frozen");
        }
    }

    /// @dev The executor's spend in the current window never exceeds the budget it was checked against.
    function invariant_budgetWindowHolds() public view {
        assertLe(handler.ghostSpent(), handler.ghostFunded());
        if (block.timestamp < adapter.windowStart() + adapter.BUDGET_WINDOW()) {
            assertLe(adapter.spentInWindow(), handler.ghostSpent());
        }
    }
}
