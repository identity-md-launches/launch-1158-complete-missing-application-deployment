// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TwoStepOwned} from "./TwoStepOwned.sol";

interface IFeeHook {
    function poolKey() external view returns (PoolKey memory);
}

interface IRewardSink {
    function notifyReward(uint256 amount) external;
}

interface IPrizeSink {
    function fundPrizes(uint256 amount) external;
}

/// @notice What a PRIO sink (StakingVault, Arena) reports as its token.
interface IPrioSink {
    function prio() external view returns (address);
}

/// @title FeeTreasury: earned ETH fees, and nothing else, fund the project
/// @notice Only the bound `TreasuryFeeHook` may send ETH here: there is no owner top-up path, so no income
/// means no paid operations. `allocate()` (permissionless) splits every new wei of income:
///   1. gas/operating reserve: at most 10% of the allocation, and only until `reserve` reaches
///      `reserveTarget` (owner-set, capped by `MAX_RESERVE_TARGET`, 2 ETH);
///   2. of the remainder: 30% IMD purchase budget (agent work), 30% PRIO purchase budget (rewards),
///      40% owner budget.
/// Budgets are spent only by the executor through bounded, slippage-checked swaps on the Uniswap v4
/// PoolManager: at most `maxSpendPerSwap` ETH per call, at most `spendPerWindow` ETH per `SPEND_WINDOW`
/// bucket across both purchases, and never below the owner's price floors (`minPrioPerEth`,
/// `minImdPerEth`), so a compromised executor key is bounded in rate and cannot buy at a self-set price.
/// The window is a fixed bucket, not a sliding one: it starts at the first purchase after the previous
/// bucket expired and lasts `SPEND_WINDOW`, so the most that can leave in any 24-hour span is
/// 2 x `spendPerWindow` (the end of one bucket and the start of the next). Size `spendPerWindow` with that
/// bound in mind. A swap that fills only partly (thin liquidity) spends only what the pool took; the rest
/// stays on its budget line, so every wei the contract holds is always on exactly one line. A swap that
/// fills nothing (the pool has no token to sell below the current price) is not a purchase: it reverts
/// `NoFill`, so it neither freezes a binding nor parks the pool at the price limit. Purchased PRIO
/// is split equally between the StakingVault (reward stream) and the Arena (game pool). Purchased IMD goes
/// to the OracleAdapter. PRIO purchases depend only on the hook's own pool; IMD purchases wait for an
/// owner-set IMD pool key. The reserve pays operator gas (`withdrawReserve`): a fee-funded bootstrap, never
/// an advance. The executor may draw it only to its own address and at most `reservePerWindow` per bucket.
///
/// Bindings (`bindHook`, `setPrio`, `setSinks`, `setImd`) can be corrected by the owner until they have been
/// used: the hook until the first fee arrives, PRIO and the two PRIO sinks until the first PRIO purchase,
/// the IMD token and the OracleAdapter sink until the first IMD purchase. From then on they are immutable,
/// so neither the 30% PRIO nor the 30% IMD allocation can be redirected once money has flowed on that line.
/// Only the venue of IMD purchases (`setImdPool`, a pool key for the frozen IMD token) stays movable, because
/// liquidity migrates between pools; every fill is still bounded by the owner's `minImdPerEth` floor.
contract FeeTreasury is IUnlockCallback, TwoStepOwned, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    uint256 public constant RESERVE_CAP_BPS = 1_000; // 10% of an allocation
    uint256 public constant IMD_BPS = 3_000;
    uint256 public constant PRIO_BPS = 3_000;
    uint256 public constant OWNER_BPS = 4_000;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_RESERVE_TARGET = 2 ether;
    uint256 public constant SPEND_WINDOW = 1 days;
    uint256 internal constant ONE = 1e18;

    IPoolManager public immutable poolManager;

    address public hook;
    IERC20 public prio;
    IERC20 public imd;
    address public stakingVault;
    address public arena;
    address public oracleAdapter;
    address public executor;
    uint256 public reserveTarget = 0.5 ether;
    uint256 public maxSpendPerSwap = 1 ether;
    /// @notice ETH the executor may spend on purchases per `SPEND_WINDOW` bucket (see the contract notice).
    uint256 public spendPerWindow = 1 ether;
    uint256 public windowStart;
    uint256 public spentInWindow;
    /// @notice ETH the executor may draw from the reserve to itself per `SPEND_WINDOW` bucket. The owner's
    /// own reserve withdrawals are not rate-limited.
    uint256 public reservePerWindow = 0.05 ether;
    uint256 public reserveWindowStart;
    uint256 public reserveSpentInWindow;
    /// @notice True once a PRIO purchase has filled: PRIO, the vault and the arena are frozen from then on.
    bool public prioPurchased;
    /// @notice True once an IMD purchase has filled: the IMD token and the OracleAdapter sink are frozen.
    bool public imdPurchased;
    /// @notice Price floors, token units (18 decimals) per 1 ETH spent. Zero means not configured: refused.
    uint256 public minPrioPerEth;
    uint256 public minImdPerEth;
    PoolKey internal _imdPoolKey;
    bool public imdPoolSet;

    uint256 public totalIncome;
    uint256 public unallocated;
    uint256 public reserve;
    uint256 public imdBudget;
    uint256 public prioBudget;
    uint256 public ownerBudget;

    event Income(uint256 amount);
    event Allocated(uint256 amount, uint256 toReserve, uint256 toImd, uint256 toPrio, uint256 toOwner);
    event HookBound(address indexed hook);
    event PrioSet(address indexed prio);
    event ImdSet(address indexed imd);
    event SinksSet(address indexed stakingVault, address indexed arena, address indexed oracleAdapter);
    event ExecutorSet(address indexed executor);
    event ReserveTargetSet(uint256 target);
    event MaxSpendSet(uint256 maxSpend);
    event SpendPerWindowSet(uint256 perWindow);
    event ReservePerWindowSet(uint256 perWindow);
    event PriceFloorsSet(uint256 minPrioPerEth, uint256 minImdPerEth);
    event ImdPoolSet(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);
    event PrioBought(uint256 ethIn, uint256 prioOut, uint256 toStaking, uint256 toArena);
    event ImdBought(uint256 ethIn, uint256 imdOut);
    event OwnerWithdrawn(address indexed to, uint256 amount);
    event ReserveWithdrawn(address indexed to, uint256 amount);

    error NotHook();
    error HookAlreadyBound();
    error AlreadySet();
    error ZeroAddress();
    error NotExecutor();
    error NotConfigured(string what);
    error ExceedsBudget();
    error ExceedsMaxSpend();
    error ExceedsWindow();
    error Slippage();
    error PoolMismatch();
    error NotPoolManager();
    error TooHigh();
    error TransferFailed();
    error SinkMismatch();
    error WrongDestination();
    error NoFill();

    constructor(IPoolManager poolManager_, address owner_) TwoStepOwned(owner_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
    }

    // ------------------------------------------------------------------ income

    receive() external payable {
        if (msg.sender != hook) revert NotHook();
        totalIncome += msg.value;
        unallocated += msg.value;
        emit Income(msg.value);
    }

    // ------------------------------------------------------------------ configuration (owner)

    /// @notice The hook whose fees fund this treasury. Correctable until the first fee has arrived, so a
    /// wrong address can be fixed before it matters; immutable afterwards.
    function bindHook(address hook_) external onlyOwner {
        if (totalIncome != 0) revert HookAlreadyBound();
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
        emit HookBound(hook_);
    }

    /// @notice The PRIO token purchases buy. Correctable until the first PRIO purchase; immutable afterwards.
    function setPrio(address prio_) external onlyOwner {
        if (prioPurchased) revert AlreadySet();
        if (prio_ == address(0)) revert ZeroAddress();
        prio = IERC20(prio_);
        emit PrioSet(prio_);
    }

    /// @notice The IMD token purchases buy. Correctable until the first IMD purchase; immutable afterwards.
    /// Changing it unsets the IMD pool: `setImdPool` must be called again for the new token.
    function setImd(address imd_) external onlyOwner {
        if (imdPurchased) revert AlreadySet();
        if (imd_ == address(0)) revert ZeroAddress();
        imd = IERC20(imd_);
        imdPoolSet = false;
        delete _imdPoolKey;
        emit ImdSet(imd_);
    }

    /// @notice Where purchases go. The vault and the arena must report the configured PRIO as their token (a
    /// swapped or foreign sink is refused). The vault and the arena are correctable until the first PRIO
    /// purchase, the OracleAdapter until the first IMD purchase; from then on that line cannot be redirected
    /// (passing the frozen address again is allowed, so the other line can still be corrected).
    function setSinks(address stakingVault_, address arena_, address oracleAdapter_) external onlyOwner {
        if (prioPurchased && (stakingVault_ != stakingVault || arena_ != arena)) revert AlreadySet();
        if (imdPurchased && oracleAdapter_ != oracleAdapter) revert AlreadySet();
        if (stakingVault_ == address(0) || arena_ == address(0) || oracleAdapter_ == address(0)) revert ZeroAddress();
        if (address(prio) == address(0)) revert NotConfigured("prio");
        if (IPrioSink(stakingVault_).prio() != address(prio) || IPrioSink(arena_).prio() != address(prio)) {
            revert SinkMismatch();
        }
        stakingVault = stakingVault_;
        arena = arena_;
        oracleAdapter = oracleAdapter_;
        emit SinksSet(stakingVault_, arena_, oracleAdapter_);
    }

    function setExecutor(address to) external onlyOwner {
        executor = to;
        emit ExecutorSet(to);
    }

    function setReserveTarget(uint256 target) external onlyOwner {
        if (target > MAX_RESERVE_TARGET) revert TooHigh();
        reserveTarget = target;
        emit ReserveTargetSet(target);
    }

    function setMaxSpendPerSwap(uint256 maxSpend) external onlyOwner {
        maxSpendPerSwap = maxSpend;
        emit MaxSpendSet(maxSpend);
    }

    function setSpendPerWindow(uint256 perWindow) external onlyOwner {
        spendPerWindow = perWindow;
        emit SpendPerWindowSet(perWindow);
    }

    /// @notice How much reserve ETH the executor may draw to itself per `SPEND_WINDOW` bucket.
    function setReservePerWindow(uint256 perWindow) external onlyOwner {
        reservePerWindow = perWindow;
        emit ReservePerWindowSet(perWindow);
    }

    /// @notice Minimum token units per ETH a purchase must return, whatever `minOut` the executor passes. The
    /// owner keeps these a little below the market price; a floor above the market refuses purchases (safe).
    function setPriceFloors(uint256 minPrioPerEth_, uint256 minImdPerEth_) external onlyOwner {
        minPrioPerEth = minPrioPerEth_;
        minImdPerEth = minImdPerEth_;
        emit PriceFloorsSet(minPrioPerEth_, minImdPerEth_);
    }

    /// @notice The Uniswap v4 pool where IMD trades against ETH (ETH must be currency0).
    function setImdPool(uint24 fee, int24 tickSpacing, address hooks) external onlyOwner {
        if (address(imd) == address(0)) revert NotConfigured("imd");
        _imdPoolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(imd)),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
        imdPoolSet = true;
        emit ImdPoolSet(address(0), address(imd), fee, tickSpacing, hooks);
    }

    function imdPoolKey() external view returns (PoolKey memory) {
        return _imdPoolKey;
    }

    /// @notice True once any purchase has filled (either line).
    function purchased() external view returns (bool) {
        return prioPurchased || imdPurchased;
    }

    // ------------------------------------------------------------------ allocation (permissionless)

    function allocate() external {
        uint256 amount = unallocated;
        if (amount == 0) return;
        unallocated = 0;
        uint256 toReserve = (amount * RESERVE_CAP_BPS) / BPS;
        uint256 room = reserve < reserveTarget ? reserveTarget - reserve : 0;
        if (toReserve > room) toReserve = room;
        uint256 rest = amount - toReserve;
        uint256 toImd = (rest * IMD_BPS) / BPS;
        uint256 toPrio = (rest * PRIO_BPS) / BPS;
        uint256 toOwner = rest - toImd - toPrio;
        reserve += toReserve;
        imdBudget += toImd;
        prioBudget += toPrio;
        ownerBudget += toOwner;
        emit Allocated(amount, toReserve, toImd, toPrio, toOwner);
    }

    // ------------------------------------------------------------------ withdrawals

    function withdrawOwner(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (amount > ownerBudget) revert ExceedsBudget();
        ownerBudget -= amount;
        _send(to, amount);
        emit OwnerWithdrawn(to, amount);
    }

    /// @notice Gas for the operator wallet, from the fee-funded reserve only. The owner may send it anywhere;
    /// the executor may draw it only to its own address and at most `reservePerWindow` per bucket, so a
    /// stolen executor key cannot empty the reserve.
    function withdrawReserve(address payable to, uint256 amount) external nonReentrant {
        if (msg.sender != owner()) {
            if (msg.sender != executor) revert NotExecutor();
            if (to != executor) revert WrongDestination();
            if (block.timestamp >= reserveWindowStart + SPEND_WINDOW) {
                reserveWindowStart = block.timestamp;
                reserveSpentInWindow = 0;
            }
            if (reserveSpentInWindow + amount > reservePerWindow) revert ExceedsWindow();
            reserveSpentInWindow += amount;
        }
        if (amount > reserve) revert ExceedsBudget();
        reserve -= amount;
        _send(to, amount);
        emit ReserveWithdrawn(to, amount);
    }

    // ------------------------------------------------------------------ purchases (executor)

    /// @notice Buys PRIO on the hooked pool with up to `ethIn` from the PRIO budget and splits it 50/50.
    /// @return out PRIO bought. Only the ETH the pool actually took leaves `prioBudget`.
    function buyPrio(uint256 ethIn, uint256 minPrioOut) external nonReentrant returns (uint256 out) {
        if (msg.sender != executor) revert NotExecutor();
        if (hook == address(0) || address(prio) == address(0)) revert NotConfigured("prio");
        if (stakingVault == address(0) || arena == address(0)) revert NotConfigured("sinks");
        if (minPrioPerEth == 0) revert NotConfigured("prio price floor");
        if (ethIn == 0 || ethIn > prioBudget) revert ExceedsBudget();
        prioBudget -= ethIn;
        uint256 spent;
        (out, spent) = _swapEthFor(IFeeHook(hook).poolKey(), ethIn, minPrioOut, minPrioPerEth);
        prioBudget += ethIn - spent;
        prioPurchased = true;
        uint256 toStaking = out / 2;
        uint256 toArena = out - toStaking;
        prio.forceApprove(stakingVault, toStaking);
        IRewardSink(stakingVault).notifyReward(toStaking);
        prio.forceApprove(arena, toArena);
        IPrizeSink(arena).fundPrizes(toArena);
        emit PrioBought(spent, out, toStaking, toArena);
    }

    /// @notice Buys IMD for agent work with up to `ethIn` from the IMD budget and hands it to the OracleAdapter.
    function buyImd(uint256 ethIn, uint256 minImdOut) external nonReentrant returns (uint256 out) {
        if (msg.sender != executor) revert NotExecutor();
        if (!imdPoolSet) revert NotConfigured("imd pool");
        if (Currency.unwrap(_imdPoolKey.currency1) != address(imd)) revert PoolMismatch();
        if (oracleAdapter == address(0)) revert NotConfigured("oracle adapter");
        if (minImdPerEth == 0) revert NotConfigured("imd price floor");
        if (ethIn == 0 || ethIn > imdBudget) revert ExceedsBudget();
        imdBudget -= ethIn;
        uint256 spent;
        (out, spent) = _swapEthFor(_imdPoolKey, ethIn, minImdOut, minImdPerEth);
        imdBudget += ethIn - spent;
        imdPurchased = true;
        imd.safeTransfer(oracleAdapter, out);
        emit ImdBought(spent, out);
    }

    // ------------------------------------------------------------------ swap plumbing

    /// @dev Bounds the spend per call and per `SPEND_WINDOW` bucket on what was actually spent, and checks both
    /// the executor's `minOut` and the owner's price floor (scaled to the ETH actually spent). A swap the pool
    /// cannot fill at all (no token to sell below the current price: the PoolManager walks to the price limit
    /// and returns a zero delta instead of reverting) is refused as `NoFill`, so it is never recorded as a
    /// purchase; the next call then reverts `PriceLimitAlreadyExceeded` in the PoolManager until liquidity
    /// returns, which the operator treats as a signal to back off.
    function _swapEthFor(PoolKey memory key, uint256 ethIn, uint256 minOut, uint256 floorPerEth)
        internal
        returns (uint256 out, uint256 spent)
    {
        if (ethIn > maxSpendPerSwap) revert ExceedsMaxSpend();
        if (block.timestamp >= windowStart + SPEND_WINDOW) {
            windowStart = block.timestamp;
            spentInWindow = 0;
        }
        if (spentInWindow + ethIn > spendPerWindow) revert ExceedsWindow();
        bytes memory result = poolManager.unlock(abi.encode(key, ethIn));
        (out, spent) = abi.decode(result, (uint256, uint256));
        if (spent == 0 || out == 0) revert NoFill();
        spentInWindow += spent;
        if (out < minOut || out < (spent * floorPerEth) / ONE) revert Slippage();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, uint256 ethIn) = abi.decode(data, (PoolKey, uint256));
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        uint256 owed = uint256(uint128(-delta.amount0()));
        uint256 out = uint256(uint128(delta.amount1()));
        // The hook's 0.5% is inside `owed`; a partial fill leaves `owed < ethIn`, credited back by the caller.
        if (owed > ethIn) revert ExceedsBudget();
        poolManager.settle{value: owed}();
        poolManager.take(key.currency1, address(this), out);
        return abi.encode(out, owed);
    }

    function _send(address payable to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
