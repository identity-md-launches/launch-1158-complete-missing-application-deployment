// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {TwoStepOwned} from "./TwoStepOwned.sol";

/// @notice What the adapter reads from the Arena: the last round id it has created.
interface IArenaRounds {
    function roundCount() external view returns (uint256);
}

/// @notice The IdentityMD Intake, as this contract calls it (oracle-consumer skill).
interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function priceOf(bytes32 action, address asset) external view returns (uint256);
    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId);
}

/// @title OracleAdapter: verified IMD panel attestations as Arena round results
/// @notice For each Arena round the owner pins one question (its canonical hash, the chain it is about, the
/// request body, the minimum panel and quorum, and the round's commit deadline as `notBefore`). The trusted
/// signer at pin time is recorded with the question, so rotating the signer later affects only future rounds.
/// A result settles the round only if a current, correctly signed EIP-712 attestation in this contract's
/// domain by the pinned signer carries exactly that question hash, was issued no earlier than the commit
/// deadline minus `ISSUED_AT_TOLERANCE`, is not expired, has `agreed >= quorum`, meets the pinned
/// panel/quorum minimums, has not been consumed before, and carries a `uint256` answer. Nothing is stored,
/// and nothing is requested, before `notBefore` on the chain's own clock: the tolerance covers signer clock
/// skew, never a window in which an answer is public while commitments are still open. The result and its
/// evidence reference (request id, panel job id, block window and hash) are stored; the Arena reads them.
///
/// Two ways in: the Intake's own callback after a paid `oracle.request` made by `request()`, and
/// `submitAttestation()`, a manual relay for a signed attestation. The question body is public once pinned
/// and the oracle sells answers to anyone, so a relay is accepted from anyone only when the attestation
/// answers a request this contract made for that round (`requestId` registered by `request()`); any other
/// attestation (one bought off chain by the operator through the HTTP door, or one bought by a third party)
/// may be relayed only by the executor or the owner. That way a player cannot buy competing answers until
/// one suits them and front-run the operator. One paid request per round is open at a time: a second
/// `request()` for the same round is refused until the first is answered or cleared as stale.
///
/// Paid requests are disabled until the owner has configured the intake, action, asset, price and callback,
/// pinned the round's question, set an executor, set a budget, and the contract holds IMD bought by the
/// treasury from earned fees. A pin is immutable once the Arena has created its round; before that (and
/// only when the owner has told this adapter which Arena to check with `setArena`) a mistaken pin can be
/// replaced, so a wrong `notBefore` cannot block round creation forever. `setArena` is one-shot: the Arena
/// whose `roundCount` decides which pins are consumed can never be swapped for one that reports fewer
/// rounds. While an Arena is set, no result is stored and no paid request is made for a round id that
/// Arena has not created yet, so a lapsed pin stays replaceable and a stored answer always belongs to a
/// real round.
contract OracleAdapter is OracleAttestationConsumer, TwoStepOwned {
    using SafeERC20 for IERC20;

    struct Pinned {
        bytes32 questionHash;
        uint256 chainId;
        uint16 minPanel;
        uint16 minQuorum;
        uint64 notBefore; // the round's commit deadline
        address signer; // the trusted signer when the question was pinned
        bytes body;
    }

    /// @dev Packed into five slots so the Intake's 200 000 gas callback can store it.
    struct Result {
        uint256 answer;
        bytes32 requestId;
        bytes32 panelJobId;
        bytes32 blockHash;
        uint64 fromBlock;
        uint64 toBlock;
        uint64 issuedAt;
        uint16 agreed;
        bool settled;
    }

    uint256 public constant BUDGET_WINDOW = 1 days;
    /// @notice After this long a pending intake request may be cleared (status 1/2 never call back).
    uint256 public constant REQUEST_TIMEOUT = 2 days;

    IIntake public intake;
    bytes32 public action;
    address public asset;
    uint256 public price;
    bool public callbackConfigured;
    address public executor;
    uint256 public budgetPerWindow;
    uint256 public windowStart;
    uint256 public spentInWindow;
    /// @notice The Arena whose `roundCount` tells which pins are already consumed (re-pin guard). One-shot.
    address public arena;
    /// @notice Every token ever configured as the payment asset: none of them can leave through `withdrawToken`.
    mapping(address token => bool) public wasAsset;

    mapping(uint256 roundId => Pinned) internal _pinned;
    mapping(uint256 roundId => Result) internal _results;
    mapping(bytes32 intakeId => uint256 roundId) public pendingRound;
    mapping(bytes32 intakeId => uint256) public pendingSince;
    /// @notice The intake request currently open for a round (zero when none).
    mapping(uint256 roundId => bytes32 intakeId) public openRequest;

    event IntakeSet(address indexed intake);
    event ActionSet(bytes32 indexed action);
    event PaymentSet(address indexed asset, uint256 price);
    event CallbackConfigured(bool configured);
    event ExecutorSet(address indexed executor);
    event ArenaSet(address indexed arena);
    event BudgetSet(uint256 budgetPerWindow);
    event QuestionPinned(uint256 indexed roundId, bytes32 questionHash, uint256 chainId, uint64 notBefore);
    event Requested(uint256 indexed roundId, bytes32 indexed intakeId, uint256 paid);
    event RequestCleared(bytes32 indexed intakeId);
    event ResultStored(uint256 indexed roundId, uint256 answer, bytes32 requestId, bytes32 panelJobId);

    error NotConfigured(string what);
    error NotExecutor();
    error NotTheIntake();
    error UnknownRequest();
    error QuestionNotPinned(uint256 roundId);
    error QuestionMismatch();
    error ChainMismatch();
    error PanelTooSmall();
    error QuorumTooSmall();
    error NotAgreed();
    error IssuedTooEarly(uint64 issuedAt, uint64 notBefore);
    error BeforeBoundary(uint64 notBefore);
    error AlreadySettled(uint256 roundId);
    error BudgetExceeded();
    error RequestNotStale();
    error ZeroAddress();
    error AlreadyPinned(uint256 roundId);
    error AssetNotWithdrawable();
    error RequestPending(uint256 roundId);
    error NotRelayer();
    error ArenaAlreadySet();
    error RoundNotCreated(uint256 roundId);

    constructor(address owner_, address signer_) OracleAttestationConsumer(signer_) TwoStepOwned(owner_) {}

    // ------------------------------------------------------------------ configuration (owner)

    function setIntake(IIntake to) external onlyOwner {
        if (address(to) == address(0)) revert ZeroAddress();
        intake = to;
        emit IntakeSet(address(to));
    }

    function setAction(bytes32 to) external onlyOwner {
        action = to;
        emit ActionSet(to);
    }

    /// @notice Asset and price move together; the asset is the chain's IMD. A token named here is remembered
    /// for ever as an asset (`wasAsset`), so renaming the asset never makes the old one withdrawable.
    function setPayment(address asset_, uint256 price_) external onlyOwner {
        if (asset_ == address(0)) revert ZeroAddress();
        asset = asset_;
        price = price_;
        wasAsset[asset_] = true;
        emit PaymentSet(asset_, price_);
    }

    /// @notice The explicit "callback is configured" switch: paid requests refuse until it is on.
    function setCallbackConfigured(bool on) external onlyOwner {
        callbackConfigured = on;
        emit CallbackConfigured(on);
    }

    function setExecutor(address to) external onlyOwner {
        executor = to;
        emit ExecutorSet(to);
    }

    /// @notice The Arena this adapter serves, so a pin for a round it has not created yet can be corrected.
    /// One-shot: once set it can never point elsewhere, so the pin of a round the Arena has created cannot be
    /// made replaceable again by naming a contract that reports fewer rounds.
    function setArena(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (arena != address(0)) revert ArenaAlreadySet();
        arena = to;
        emit ArenaSet(to);
    }

    /// @notice IMD the executor may spend per `BUDGET_WINDOW`.
    function setBudget(uint256 perWindow) external onlyOwner {
        budgetPerWindow = perWindow;
        emit BudgetSet(perWindow);
    }

    /// @notice Rotates the trusted signer for questions pinned from now on. Already pinned rounds keep theirs.
    function setSigner(address to) external onlyOwner {
        _setOracleSigner(to);
    }

    /// @notice Pins a round's question before it opens, with the current trusted signer. A pin can be replaced
    /// only while nothing depends on it: the Arena set with `setArena` has not created the round yet, no result
    /// is stored and no paid request is open. Once the Arena has created the round the pin is immutable.
    function pinQuestion(
        uint256 roundId,
        bytes32 questionHash,
        uint256 chainId,
        uint16 minPanel,
        uint16 minQuorum,
        uint64 notBefore,
        bytes calldata body
    ) external onlyOwner {
        if (_pinned[roundId].questionHash != bytes32(0) && !_replaceable(roundId)) {
            revert AlreadyPinned(roundId);
        }
        if (questionHash == bytes32(0) || minQuorum < 2 || minPanel < minQuorum) revert NotConfigured("question");
        _pinned[roundId] = Pinned(questionHash, chainId, minPanel, minQuorum, notBefore, oracleSigner, body);
        emit QuestionPinned(roundId, questionHash, chainId, notBefore);
    }

    /// @dev A pin may be replaced only when the configured Arena has not consumed the id, nothing is settled
    /// and no request is open for it.
    function _replaceable(uint256 roundId) internal view returns (bool) {
        if (arena == address(0) || _results[roundId].settled || openRequest[roundId] != bytes32(0)) return false;
        return IArenaRounds(arena).roundCount() < roundId;
    }

    /// @dev While an Arena is configured, a round id it has not created yet takes neither a result nor a paid
    /// request: a result for an uncreated round could never be undone and would make the id (and, since ids are
    /// sequential, every later round) impossible to create.
    function _requireCreated(uint256 roundId) internal view {
        if (arena != address(0) && IArenaRounds(arena).roundCount() < roundId) revert RoundNotCreated(roundId);
    }

    // ------------------------------------------------------------------ views

    function pinned(uint256 roundId) external view returns (Pinned memory) {
        return _pinned[roundId];
    }

    function resultOf(uint256 roundId) external view returns (Result memory) {
        return _results[roundId];
    }

    function paidRequestsEnabled() public view returns (bool) {
        return address(intake) != address(0) && action != bytes32(0) && asset != address(0) && price != 0
            && callbackConfigured && executor != address(0) && budgetPerWindow != 0;
    }

    // ------------------------------------------------------------------ paid request (executor)

    /// @notice Buys one panel answer for `roundId` from IMD this contract holds, within the budget. Refused
    /// before the round's commit boundary: an answer bought while commitments are open could leak or be wasted.
    function request(uint256 roundId) external returns (bytes32 intakeId) {
        if (msg.sender != executor) revert NotExecutor();
        if (!paidRequestsEnabled()) revert NotConfigured("paid requests");
        Pinned storage p = _pinned[roundId];
        if (p.questionHash == bytes32(0)) revert QuestionNotPinned(roundId);
        if (_results[roundId].settled) revert AlreadySettled(roundId);
        if (openRequest[roundId] != bytes32(0)) revert RequestPending(roundId);
        _requireCreated(roundId);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < p.notBefore) revert BeforeBoundary(p.notBefore);
        if (block.timestamp >= windowStart + BUDGET_WINDOW) {
            windowStart = block.timestamp;
            spentInWindow = 0;
        }
        if (spentInWindow + price > budgetPerWindow) revert BudgetExceeded();
        spentInWindow += price;
        IERC20(asset).forceApprove(address(intake), price);
        intakeId =
            intake.request(action, p.body, IIntake.Callback(address(this), this.onOracleResult.selector), asset, price);
        if (intakeId == bytes32(0) || pendingSince[intakeId] != 0) revert UnknownRequest();
        pendingRound[intakeId] = roundId;
        pendingSince[intakeId] = block.timestamp;
        openRequest[roundId] = intakeId;
        emit Requested(roundId, intakeId, price);
    }

    /// @notice Clears a request the plane never answered (refused body, no agreement). The price is spent.
    function clearStale(bytes32 intakeId) external {
        if (pendingSince[intakeId] == 0 || block.timestamp < pendingSince[intakeId] + REQUEST_TIMEOUT) {
            revert RequestNotStale();
        }
        _forget(intakeId);
        emit RequestCleared(intakeId);
    }

    // ------------------------------------------------------------------ results

    /// @notice The Intake's callback for `oracle.request`. Stays well under the 200 000 gas stipend.
    function onOracleResult(bytes32 intakeId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
    {
        if (msg.sender != address(intake)) revert NotTheIntake();
        if (pendingSince[intakeId] == 0) revert UnknownRequest();
        uint256 roundId = pendingRound[intakeId];
        _forget(intakeId);
        _accept(roundId, a, signature);
    }

    /// @notice Manual relay. Anyone may relay the answer to a request this contract made for the round
    /// (`a.requestId` registered by `request()`); any other attestation only the executor or the owner.
    function submitAttestation(uint256 roundId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
    {
        if (pendingSince[a.requestId] != 0 && pendingRound[a.requestId] == roundId) {
            _forget(a.requestId);
        } else if (msg.sender != executor && msg.sender != owner()) {
            revert NotRelayer();
        }
        _accept(roundId, a, signature);
    }

    function _forget(bytes32 intakeId) internal {
        uint256 roundId = pendingRound[intakeId];
        if (openRequest[roundId] == intakeId) delete openRequest[roundId];
        delete pendingRound[intakeId];
        delete pendingSince[intakeId];
    }

    function _accept(uint256 roundId, OracleAttestation.Attestation calldata a, bytes calldata signature) internal {
        Pinned storage p = _pinned[roundId];
        if (p.questionHash == bytes32(0)) revert QuestionNotPinned(roundId);
        if (_results[roundId].settled) revert AlreadySettled(roundId);
        _requireCreated(roundId);
        // The chain's own clock: no answer is on chain while the Arena still accepts commitments.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < p.notBefore) revert BeforeBoundary(p.notBefore);
        _verifyAttestationBy(p.signer, a, signature);
        if (a.questionHash != p.questionHash) revert QuestionMismatch();
        if (a.chainId != p.chainId) revert ChainMismatch();
        if (a.panelSize < p.minPanel) revert PanelTooSmall();
        if (a.quorum < p.minQuorum) revert QuorumTooSmall();
        if (a.agreed < a.quorum) revert NotAgreed();
        if (a.issuedAt + ISSUED_AT_TOLERANCE < p.notBefore) revert IssuedTooEarly(a.issuedAt, p.notBefore);
        uint256 answer = decodeUint256(a);
        _consume(a.requestId);
        _results[roundId] = Result({
            answer: answer,
            requestId: a.requestId,
            panelJobId: a.panelJobId,
            blockHash: a.blockHash,
            fromBlock: a.fromBlock,
            toBlock: a.toBlock,
            issuedAt: a.issuedAt,
            agreed: a.agreed,
            settled: true
        });
        emit ResultStored(roundId, answer, a.requestId, a.panelJobId);
    }

    /// @dev The base contract's checks (expiry, issued-at skew, signature) against the signer pinned with the
    /// round's question rather than the current one, so a rotation never changes an open round's authority.
    function _verifyAttestationBy(address signer, OracleAttestation.Attestation calldata a, bytes calldata signature)
        internal
        view
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > a.expiresAt) revert AttestationExpired(a.expiresAt);
        // forge-lint: disable-next-line(block-timestamp)
        if (a.issuedAt > block.timestamp + ISSUED_AT_TOLERANCE) revert AttestationNotYetValid(a.issuedAt);
        if (!SignatureChecker.isValidSignatureNow(signer, attestationDigest(a), signature)) revert BadSignature();
    }

    /// @notice Returns a token sent here by mistake. The payment asset, and every token that has ever been the
    /// payment asset (the IMD bought from fees for agent work), cannot be withdrawn: it is spent only on panel
    /// answers, and renaming the asset with `setPayment` does not release it.
    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == asset || wasAsset[token]) revert AssetNotWithdrawable();
        IERC20(token).safeTransfer(to, amount);
    }
}
