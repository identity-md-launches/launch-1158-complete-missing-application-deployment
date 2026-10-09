// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TwoStepOwned} from "./TwoStepOwned.sol";

/// @notice What the Arena reads from the OracleAdapter.
interface IRoundOracle {
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

    struct Pinned {
        bytes32 questionHash;
        uint256 chainId;
        uint16 minPanel;
        uint16 minQuorum;
        uint64 notBefore;
        address signer;
        bytes body;
    }

    function resultOf(uint256 roundId) external view returns (Result memory);
    function pinned(uint256 roundId) external view returns (Pinned memory);
    function ISSUED_AT_TOLERANCE() external view returns (uint64);
}

/// @title Arena: Vault Raid, faction duels and cooperative boss challenges on commit-reveal choices
/// @notice Every round is frozen when the owner creates it: mode, number of choices, deadlines, funded prize,
/// boss threshold, a hash of the published rules, and its result source: the oracle adapter and the question
/// pinned there (whose `notBefore` must equal the round's commit deadline). Nothing about an open round can
/// change: `setOracle` only affects rounds created afterwards, and the adapter keeps a pinned question and
/// its signer immutable.
///
/// Fixed published scoring, identical in every mode:
///   - entry locks 100 PRIO escrow + 2 PRIO entry fee (102 PRIO, pulled from the player's approval);
///   - correct choice: 100 PRIO escrow returned plus an equal share of the round's prize;
///   - wrong choice: 90 PRIO returned (10 PRIO penalty);
///   - missed reveal: 80 PRIO returned (20 PRIO penalty). Penalties never stack: the maximum loss is the
///     2 PRIO fee plus one penalty, 22 PRIO.
///   - cancelled round (no valid result 72 hours after `resultDeadline`): 102 PRIO back, no penalty.
/// Winning choice = (oracle answer mod choiceCount) + 1. Vault Raid: pick the vault (1..N) that the panel
/// finds. Faction duel: pick faction 1 or 2. Boss challenge: all players strike together; the prize is paid
/// only if at least `bossThreshold` players chose correctly, otherwise correct players keep their 100 PRIO
/// and the prize returns to the game pool. Ties cannot occur: every correct player wins the same share;
/// with no correct player the prize returns to the game pool. Fees, penalties and prize dust go to the
/// game pool (`unallocatedPrizePool`) that funds future rounds.
///
/// Settlement is O(1) (tallies are kept at reveal time) and every payout is a pull claim indexed by round,
/// so old rounds stay claimable forever. The Arena never touches staking principal (it is another contract)
/// and never pulls more than the 102 PRIO a player approved for one entry.
contract Arena is TwoStepOwned, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Mode {
        VaultRaid,
        FactionDuel,
        BossChallenge
    }

    enum RoundState {
        None,
        Open,
        Settled,
        Cancelled
    }

    struct Round {
        Mode mode;
        RoundState state;
        uint8 choiceCount;
        uint8 winningChoice;
        uint16 bossThreshold;
        uint64 commitDeadline;
        uint64 revealDeadline;
        uint64 resultDeadline;
        uint256 prize;
        uint256 prizePerWinner;
        uint256 entries;
        uint256 correct;
        bytes32 rulesHash;
        IRoundOracle oracle; // the result source, frozen at creation
        bytes32 questionHash; // the question pinned there for this round
    }

    struct Entry {
        bytes32 commitment;
        uint8 choice; // 0 = not revealed
        bool claimed;
    }

    uint256 public constant ESCROW = 100 ether;
    uint256 public constant ENTRY_FEE = 2 ether;
    uint256 public constant ENTRY_COST = ESCROW + ENTRY_FEE;
    uint256 public constant WRONG_RETURN = 90 ether;
    uint256 public constant MISSED_REVEAL_RETURN = 80 ether;
    uint256 public constant MAX_LOSS = ENTRY_FEE + (ESCROW - MISSED_REVEAL_RETURN);
    uint256 public constant CANCEL_GRACE = 72 hours;
    /// @notice Longest a round may run from its commit deadline to its result deadline, so escrow always has
    /// a reachable cancel path (`resultDeadline + CANCEL_GRACE`) if no result ever arrives.
    uint256 public constant MAX_ROUND_LENGTH = 30 days;

    IERC20 public immutable prio;
    IRoundOracle public oracle;

    uint256 public roundCount;
    mapping(uint256 => Round) internal _rounds;
    mapping(uint256 => mapping(address => Entry)) internal _entries;
    mapping(uint256 => mapping(uint8 => uint256)) public tally;

    /// @notice PRIO held for players: escrow + fees of unclaimed entries.
    uint256 public totalEscrowed;
    /// @notice PRIO locked as prizes of open rounds.
    uint256 public lockedPrizes;
    /// @notice Funded PRIO not yet assigned to a round.
    uint256 public unallocatedPrizePool;

    event OracleSet(address indexed oracle);
    event PrizesFunded(address indexed from, uint256 amount);
    event RoundCreated(uint256 indexed roundId, Mode mode, uint8 choiceCount, uint256 prize, bytes32 rulesHash);
    event Entered(uint256 indexed roundId, address indexed player, bytes32 commitment);
    event Revealed(uint256 indexed roundId, address indexed player, uint8 choice);
    event RoundSettled(uint256 indexed roundId, uint8 winningChoice, uint256 correct, uint256 prizePerWinner);
    event RoundCancelled(uint256 indexed roundId);
    event Claimed(uint256 indexed roundId, address indexed player, uint256 amount);
    event Refunded(uint256 indexed roundId, address indexed player, uint256 amount);

    error ZeroAddress();
    error BadRound();
    error BadDeadlines();
    error BadChoices();
    error PrizeNotFunded();
    error NotOpen();
    error CommitClosed();
    error RevealWindowClosed();
    error AlreadyEntered();
    error NotEntered();
    error AlreadyRevealed();
    error BadReveal();
    error BadChoice();
    error RevealNotOver();
    error NoResult();
    error ResultTooEarly();
    error NotCancellable();
    error RoundResolved();
    error QuestionNotPinned();
    error NotSettled();
    error NotCancelled();
    error AlreadyClaimed();
    error QuestionChanged();

    constructor(address owner_, address prio_) TwoStepOwned(owner_) {
        if (prio_ == address(0)) revert ZeroAddress();
        prio = IERC20(prio_);
    }

    // ------------------------------------------------------------------ owner

    /// @notice The adapter future rounds will be created against. Open rounds keep the one they were created with.
    function setOracle(IRoundOracle to) external onlyOwner {
        if (address(to) == address(0)) revert ZeroAddress();
        oracle = to;
        emit OracleSet(address(to));
    }

    /// @notice Creates a frozen round. The prize is locked from the game pool now, before anyone enters, and
    /// the round's question must already be pinned on the oracle with `notBefore == commitDeadline`, so the
    /// result source is fixed before the first entry. Round ids are sequential: pin `roundCount() + 1`.
    function createRound(
        Mode mode,
        uint8 choiceCount,
        uint64 commitDeadline,
        uint64 revealDeadline,
        uint64 resultDeadline,
        uint256 prize,
        uint16 bossThreshold,
        bytes32 rulesHash
    ) external onlyOwner returns (uint256 roundId) {
        if (address(oracle) == address(0)) revert ZeroAddress();
        if (choiceCount < 2) revert BadChoices();
        if (mode == Mode.FactionDuel && choiceCount != 2) revert BadChoices();
        if (mode != Mode.BossChallenge) bossThreshold = 0;
        if (!(block.timestamp < commitDeadline && commitDeadline < revealDeadline && revealDeadline < resultDeadline)) {
            revert BadDeadlines();
        }
        if (uint256(resultDeadline) - commitDeadline > MAX_ROUND_LENGTH) revert BadDeadlines();
        if (prize > unallocatedPrizePool) revert PrizeNotFunded();
        roundId = roundCount + 1;
        IRoundOracle.Pinned memory p = oracle.pinned(roundId);
        if (p.questionHash == bytes32(0) || p.notBefore != commitDeadline) revert QuestionNotPinned();
        unallocatedPrizePool -= prize;
        lockedPrizes += prize;
        roundCount = roundId;
        Round storage r = _rounds[roundId];
        r.oracle = oracle;
        r.questionHash = p.questionHash;
        r.mode = mode;
        r.state = RoundState.Open;
        r.choiceCount = choiceCount;
        r.bossThreshold = bossThreshold;
        r.commitDeadline = commitDeadline;
        r.revealDeadline = revealDeadline;
        r.resultDeadline = resultDeadline;
        r.prize = prize;
        r.rulesHash = rulesHash;
        emit RoundCreated(roundId, mode, choiceCount, prize, rulesHash);
    }

    // ------------------------------------------------------------------ funding

    /// @notice Anyone (normally the FeeTreasury) adds PRIO to the game pool.
    function fundPrizes(uint256 amount) external nonReentrant {
        prio.safeTransferFrom(msg.sender, address(this), amount);
        unallocatedPrizePool += amount;
        emit PrizesFunded(msg.sender, amount);
    }

    // ------------------------------------------------------------------ views

    function rounds(uint256 roundId) external view returns (Round memory) {
        return _rounds[roundId];
    }

    function entries(uint256 roundId, address player) external view returns (Entry memory) {
        return _entries[roundId][player];
    }

    function commitmentOf(uint256 roundId, address player, uint8 choice, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(roundId, player, choice, salt));
    }

    /// @notice What a player will receive from a settled or cancelled round.
    function payoutOf(uint256 roundId, address player) public view returns (uint256) {
        Round storage r = _rounds[roundId];
        Entry storage e = _entries[roundId][player];
        if (e.commitment == bytes32(0)) return 0;
        if (r.state == RoundState.Cancelled) return ENTRY_COST;
        if (r.state != RoundState.Settled) return 0;
        if (e.choice == 0) return MISSED_REVEAL_RETURN;
        if (e.choice != r.winningChoice) return WRONG_RETURN;
        return ESCROW + r.prizePerWinner;
    }

    // ------------------------------------------------------------------ players

    function enter(uint256 roundId, bytes32 commitment) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Open) revert NotOpen();
        if (block.timestamp >= r.commitDeadline) revert CommitClosed();
        if (commitment == bytes32(0)) revert BadReveal();
        Entry storage e = _entries[roundId][msg.sender];
        if (e.commitment != bytes32(0)) revert AlreadyEntered();
        e.commitment = commitment;
        r.entries += 1;
        totalEscrowed += ENTRY_COST;
        prio.safeTransferFrom(msg.sender, address(this), ENTRY_COST);
        emit Entered(roundId, msg.sender, commitment);
    }

    function reveal(uint256 roundId, uint8 choice, bytes32 salt) external {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Open) revert NotOpen();
        if (block.timestamp < r.commitDeadline || block.timestamp >= r.revealDeadline) revert RevealWindowClosed();
        Entry storage e = _entries[roundId][msg.sender];
        if (e.commitment == bytes32(0)) revert NotEntered();
        if (e.choice != 0) revert AlreadyRevealed();
        if (choice == 0 || choice > r.choiceCount) revert BadChoice();
        if (commitmentOf(roundId, msg.sender, choice, salt) != e.commitment) revert BadReveal();
        e.choice = choice;
        tally[roundId][choice] += 1;
        emit Revealed(roundId, msg.sender, choice);
    }

    // ------------------------------------------------------------------ settlement (permissionless)

    /// @notice A valid result is on file for the round at the oracle it was created with, and the question
    /// pinned there is still the one the round was created against.
    function resolved(uint256 roundId) public view returns (bool) {
        Round storage r = _rounds[roundId];
        if (r.state == RoundState.None) return false;
        if (r.oracle.pinned(roundId).questionHash != r.questionHash) return false;
        IRoundOracle.Result memory res = r.oracle.resultOf(roundId);
        // The same clock tolerance the adapter uses: the answer may not predate the commit boundary.
        return res.settled && uint256(res.issuedAt) + r.oracle.ISSUED_AT_TOLERANCE() >= r.commitDeadline;
    }

    /// @notice Settles with the verified result from the round's own oracle. Fails without one; never loops
    /// over players. There is no upper time bound: a resolved round settles, and only an unresolved one can
    /// be cancelled, so the two outcomes never compete. The Arena checks for itself that the adapter still
    /// pins the question the round was created against: a result for any other question never settles it,
    /// whatever the adapter's configuration became.
    function settle(uint256 roundId) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Open) revert NotOpen();
        if (block.timestamp < r.revealDeadline) revert RevealNotOver();
        if (r.oracle.pinned(roundId).questionHash != r.questionHash) revert QuestionChanged();
        IRoundOracle.Result memory res = r.oracle.resultOf(roundId);
        if (!res.settled) revert NoResult();
        if (uint256(res.issuedAt) + r.oracle.ISSUED_AT_TOLERANCE() < r.commitDeadline) revert ResultTooEarly();
        uint8 winning = uint8(res.answer % r.choiceCount) + 1;
        uint256 correct = tally[roundId][winning];
        bool prizePaid = correct > 0 && (r.mode != Mode.BossChallenge || correct >= r.bossThreshold);
        uint256 perWinner = prizePaid ? r.prize / correct : 0;
        uint256 paidOut = perWinner * correct;
        r.winningChoice = winning;
        r.correct = correct;
        r.prizePerWinner = perWinner;
        r.state = RoundState.Settled;
        lockedPrizes -= r.prize;
        unallocatedPrizePool += r.prize - paidOut;
        // Winners' prize shares stay reserved for their claims.
        totalEscrowed += paidOut;
        emit RoundSettled(roundId, winning, correct, perWinner);
    }

    /// @notice Cancels a round that is still unresolved 72 hours after its result deadline. Everyone is
    /// refunded. A round whose valid result is on file is resolved and must be settled instead.
    function cancel(uint256 roundId) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Open) revert NotOpen();
        if (block.timestamp < uint256(r.resultDeadline) + CANCEL_GRACE) revert NotCancellable();
        if (resolved(roundId)) revert RoundResolved();
        r.state = RoundState.Cancelled;
        lockedPrizes -= r.prize;
        unallocatedPrizePool += r.prize;
        emit RoundCancelled(roundId);
    }

    // ------------------------------------------------------------------ pull claims, indexed by round

    function claim(uint256 roundId) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Settled) revert NotSettled();
        uint256 amount = _takeEntry(roundId, msg.sender);
        emit Claimed(roundId, msg.sender, amount);
    }

    function refund(uint256 roundId) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Cancelled) revert NotCancelled();
        uint256 amount = _takeEntry(roundId, msg.sender);
        emit Refunded(roundId, msg.sender, amount);
    }

    function _takeEntry(uint256 roundId, address player) internal returns (uint256 amount) {
        Entry storage e = _entries[roundId][player];
        if (e.commitment == bytes32(0)) revert NotEntered();
        if (e.claimed) revert AlreadyClaimed();
        e.claimed = true;
        amount = payoutOf(roundId, player);
        Round storage r = _rounds[roundId];
        uint256 reserved =
            ENTRY_COST + (r.state == RoundState.Settled && e.choice == r.winningChoice ? r.prizePerWinner : 0);
        totalEscrowed -= reserved;
        // Fee and any penalty (never more than one) feed future prizes.
        unallocatedPrizePool += reserved - amount;
        prio.safeTransfer(player, amount);
    }
}
