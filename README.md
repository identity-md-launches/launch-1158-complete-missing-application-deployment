# PRISM RIOT (PRIO) — Uniswap v4 hook launch on Ethereum

Token **Prism Riot (PRIO)**, pair ETH/PRIO, chain id 1. The token, hook, distributor and pool went live
in launch 1153 (`univ4_hook`). This tree is the follow-up **contracts-only launch** (`evm_contracts`)
that deploys the four application contracts: `FeeTreasury`, `StakingVault`, `Arena`, `OracleAdapter`.
See `ADAPTATION.md` for every change made for it and `docs/DEPLOYMENT.md` for the verified live records,
the manifest arguments and the owner's ordered configuration transactions. No website.

| Contract (Solidity name) | Role |
| --- | --- |
| `PrismRiotToken` | the platform's standard fixed-supply token: 1,000,000,000 PRIO, 18 decimals, minted once to the deployer (the launch factory), plain transfers, no owner/mint/pause/fee/upgrade |
| `TreasuryFeeHook` | immutable extra 0.5% on the ETH leg of every buy and sell in the ETH/PRIO pool, settled in ETH and sent to `FeeTreasury` |
| `FeeTreasury` | receives fee ETH only; 10%-capped reserve, then 30% IMD / 30% PRIO / 40% owner; bounded swaps; PRIO split 50/50 between staking and games |
| `StakingVault` | `stake()`, `withdraw()`, `claim()`; funded rewards streamed pro rata by stake and time |
| `Arena` | Vault Raid, faction duels, boss challenges; commit-reveal; 100 PRIO escrow + 2 PRIO fee; pull claims by round |
| `OracleAdapter` | verifies IMD EIP-712 panel attestations and stores the result and evidence per round |

Everything is owned by the paying wallet through two-step ownership that cannot be renounced
(`TwoStepOwned`). Active rules, reserved payouts and the 0.5% fee cannot be changed by anyone.

## Status (2026-10-09)

- **Live on Ethereum mainnet** (launch 1153, tx `0x545df1ad…6dd7d`, block 26154170): PRIO
  `0xfd1c234972768c23bb21d655966e0b122dd67a2c`, `TreasuryFeeHook`
  `0x65a783cc6725a02ce349dc4d72577994df1760cc` (owner `0x13afb9b5780cd9ae79c61503adb69c57845d8eac`,
  `treasury()` still zero), distributor `0xd5873749535e5e558e3c2181ff8e9f43e4fc2927`, pool ETH/PRIO
  fee 12500 / tick spacing 60. Verified by direct reads; see `docs/DEPLOYMENT.md` §1.
- **Not yet deployed**: `FeeTreasury`, `StakingVault`, `Arena`, `OracleAdapter`. No application contract
  exists on chain (owner wallet history and launch list checked), so this launch creates no duplicate.
  Their addresses, receipts and `launch.json` come from the manifest and deployment steps; this
  repository holds no keys and broadcasts nothing.
- `forge build`, `forge test` (181 tests: unit, fuzz, invariant, deploy rehearsal, launch adaptation)
  and `forge fmt` pass with `solc = "0.8.26"`; the protected floor test for `evm_contracts` was rehearsed
  locally with the four built creation codes (1/1). `python3 operator/test_operator.py`: 11 tests.
- Independent review is required before release; the finding-to-fix tables are in `docs/REVIEW.md`
  (rounds 1-2) and `ADAPTATION.md` (the pre-launch audit of this tree).

## Build and test

```bash
forge build
forge test
forge fmt --check
python3 operator/test_operator.py
```

Dependencies are vendored as ordinary files under `lib/` (forge-std, Uniswap v4-core `src` +
`test/utils/CurrencySettler.sol`, OpenZeppelin Contracts v5.1.0, three solmate files v4-core needs).
No git submodules, no `ffi`, no filesystem permissions, no environment variables in tests.

## Deployment parameters (for the manifest step of the contracts-only launch)

Already live and **not** redeployed: `PrismRiotToken` (PRIO) and `TreasuryFeeHook` (addresses above).
The four application contracts take static addresses; the brief names the owner, so it is written as
that address rather than `$owner`.

| Contract | Constructor arguments |
| --- | --- |
| `FeeTreasury` | `IPoolManager poolManager` = `0x000000000004444c5dc75cb358380d2e3de08a90`, `address owner` = `0x13afb9b5780cd9ae79c61503adb69c57845d8eac` |
| `StakingVault` | `address owner` = `0x13afb9b5780cd9ae79c61503adb69c57845d8eac`, `address prio` = `0xfd1c234972768c23bb21d655966e0b122dd67a2c` |
| `Arena` | `address owner` = `0x13afb9b5780cd9ae79c61503adb69c57845d8eac`, `address prio` = `0xfd1c234972768c23bb21d655966e0b122dd67a2c` |
| `OracleAdapter` | `address owner` = `0x13afb9b5780cd9ae79c61503adb69c57845d8eac`, `address signer` = `0x5598aa9146215bc13eb26f2c692ad1461fd32982`, the IMD oracle signer on Ethereum (re-verified 2026-10-09 against `api.imd.fun/oracle/requests`); owner-rotatable with `setSigner` for future pins |

Hook address flags (mined by the deployer with CREATE2): `beforeInitialize | beforeSwap | afterSwap |
beforeSwapReturnDelta | afterSwapReturnDelta` = `0x20CC` (8396). The constructor calls
`Hooks.validateHookPermissions`, so a hook at an address without exactly these bits refuses to deploy.
No constructor calls another contract or needs an address to have code.

Pool: `currency0` = native ETH (address zero, which always sorts first), `currency1` = PRIO,
`fee` = 12500 (1.25%, the launch policy's tier; the hook accepts any static fee and refuses the
dynamic-fee flag), `tickSpacing` = 60. The deployer opens the pool at the policy's price. The token's
supply split (10% distributor, 87% pool, 3% payer) is the factory's; no contract here is allocated
any of it.

`script/Deploy.s.sol` is a reviewable rehearsal: `deployApplications(AppConfig)` deploys the four with the
live addresses as inputs (`test/LaunchAdaptation.t.sol`), `deployAll(Config)` the original six
(`test/Deploy.t.sol`). Its `run()` deliberately reverts: the launch deploys from the manifest.
`script/ConfigPlan.s.sol` lists the owner's post-launch transactions in order (`docs/DEPLOYMENT.md` §3).

## After launch (owner settings)

The project owner `0x13afb9b5780cd9ae79c61503adb69c57845d8eac` owns all six contracts. Do these in order;
each is an owner-only setter that emits an event, and every function that needs a value reverts with a
clear error until it is set. Calldata for every step, and the simulation that executes the whole list
against local copies of the live hook and PRIO, are in `docs/DEPLOYMENT.md` §3 and
`script/ConfigPlan.s.sol`.

| Step | Call | Value |
| --- | --- | --- |
| A1-A2 | `FeeTreasury.bindHook(0x65a783cc…60cc)` / `setPrio(0xfd1c2349…7a2c)` | the live hook and PRIO. Correctable until used (the hook until the first fee arrives, PRIO until the first PRIO purchase), immutable afterwards |
| A3 | `FeeTreasury.setSinks(vault, arena, adapter)` | the three launched contracts. The vault and the arena must report PRIO as their token (`SinkMismatch` otherwise). The vault and the arena are correctable until the first PRIO purchase, the adapter until the first IMD purchase; from then on that allocation cannot be redirected |
| A4 | `TreasuryFeeHook.bindTreasury(treasury)` | the launched `FeeTreasury`, after A1-A3 (a treasury bound to another hook is refused). Correctable by the owner until the first fee has been delivered, **permanent afterwards**. **The live hook already holds fee ETH** (`pendingEth()` = 390361348266782 wei at block 26154735) and `flush()` is permissionless, so A4 is effectively permanent the moment it is mined: before signing, confirm `cast call <treasury> "hook()(address)"` returns the hook (A1 mined) and `cast code <treasury>` is the FeeTreasury runtime. An EOA would pass the hook's check and lose every fee for ever |
| A5 | `StakingVault.setRewardFunder(treasury)` | the treasury, so `buyPrio` can stream rewards |
| A6 | `Arena.setOracle(adapter)` | the launched `OracleAdapter` (applies to rounds created afterwards; a round keeps the adapter it was created with) |
| A7 | `OracleAdapter.setArena(arena)` | the launched `Arena`. **One-shot**: verify the address first. With it set, a mistaken pin for a round the Arena has not created yet can be replaced, and no result or paid request is accepted for such a round. Sign it before the first `pinQuestion` |
| B1-B4 | `FeeTreasury.setReserveTarget(x)`, `setMaxSpendPerSwap(y)`, `setSpendPerWindow(z)`, `setReservePerWindow(r)` | reserve target default 0.5 ETH, hard cap 2 ETH; per-purchase cap default 1 ETH; per-24h-bucket cap across both purchases, default 1 ETH (**fixed bucket**: at most 2× in any 24h span); executor gas draw per bucket, to the executor only, default 0.05 ETH |
| B5 | `FeeTreasury.setPriceFloors(minPrioPerEth, minImdPerEth)` | **required before any purchase**: the minimum PRIO (resp. IMD) units per ETH a purchase must return, 18 decimals, e.g. 10% below the current pool price. The owner re-sets them when prices move; a floor above the market makes purchases revert, never overpay |
| B6-B7 | `FeeTreasury.setImd(0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7)` then `setImdPool(fee, tickSpacing, hooks)` | IMD on Ethereum and the Uniswap v4 pool key where IMD trades against ETH (ETH must be `currency0`; the pool with liquidity on 2026-10-09 was fee 10000 / tick spacing 200 / no hook, see `docs/DEPLOYMENT.md` §4). Calling `setImd` again unsets the pool key; `setImd` is frozen by the first IMD purchase, `setImdPool` stays movable so the venue can follow liquidity (every fill is still bounded by the floor). Without it IMD purchases wait; PRIO purchases do not depend on it |
| B8-B12 | `OracleAdapter.setIntake(0x1397434cd35e8a9c8ac312a61d3a285eb31dea56)`, `setAction(bytes32("oracle.request@oracle-1"))`, `setPayment(IMD, 500000000000000000)`, `setCallbackConfigured(true)`, `setBudget(imdPerDay)` | the live Intake, action id, 0.5 IMD list price (read `Intake.priceOf`), the explicit callback switch, the executor's daily IMD budget |
| B13 | `FeeTreasury.setExecutor(wallet)` / `OracleAdapter.setExecutor(wallet)` | the server operator's wallet, last: nothing is spendable by it before every limit is in place |
| per round | `OracleAdapter.pinQuestion(Arena.roundCount() + 1, questionHash, chainId, minPanel, minQuorum, commitDeadline, body)` **then** `Arena.createRound(...)` with the same `commitDeadline` | the question's canonical hash and compact body (oracle-consumer skill "The body"), chain the question is about, minimum panel/quorum, and the round's commit deadline as the clock boundary. `createRound` refuses a round whose question is not pinned at exactly that boundary, refuses a `resultDeadline` more than 30 days after `commitDeadline` (so a cancel path is always reachable), and records the adapter, the question hash and the signer pinned with it |

## The hook

Configuration record (OpenZeppelin Wizard shape, implemented by hand on v4-core interfaces):

```json
{"hook":"BaseHook","name":"TreasuryFeeHook","pausable":false,"currencySettler":false,"safeCast":false,
 "transientStorage":false,"shares":{"options":false},
 "permissions":{"beforeInitialize":true,"afterInitialize":false,"beforeAddLiquidity":false,
 "beforeRemoveLiquidity":false,"afterAddLiquidity":false,"afterRemoveLiquidity":false,"beforeSwap":true,
 "afterSwap":true,"beforeDonate":false,"afterDonate":false,"beforeSwapReturnDelta":true,
 "afterSwapReturnDelta":true,"afterAddLiquidityReturnDelta":false,"afterRemoveLiquidityReturnDelta":false},
 "access":"ownable","info":{"license":"MIT"}}
```

**Fee definition.** `FEE_BPS = 50` (0.5%), a constant with no setter. The base is the *ETH leg*: the
ETH amount the pool itself exchanges in the swap, before the hook's fee is added, so the hook fee
never compounds with itself nor with the pool's 1.25% LP fee or the protocol fee, which the
PoolManager accounts separately. Rounded up to the next wei. Per swap shape, for a swap the pool fills
completely:

| Swap | Where | Fee | Swapper's view |
| --- | --- | --- | --- |
| buy, exact ETH in `G` | `beforeSwap` | `ceil(G·50/10050)`; pool swaps `G − fee` | pays exactly `G` |
| buy, exact PRIO out | `afterSwap` | `ceil(P·50/10000)` on the pool's ETH charge `P` | pays `P + fee` |
| sell, exact PRIO in | `afterSwap` | `ceil(P·50/10000)` on the pool's ETH payout `P` | receives `P − fee` |
| sell, exact ETH out `E` | `beforeSwap` | `ceil(E·50/9950)`; pool pays `E + fee` | receives exactly `E` |

**Partial fills (ETH-specified shapes).** A before-swap delta can only touch the specified currency
and the fee must be 0.5% of what the pool *really* exchanges, which is unknown until the pool has run.
So for the two ETH-specified shapes `beforeSwap` runs the pool leg itself: a nested `swap` by the hook
(the PoolManager skips hook callbacks when the hook is the caller), with the swapper's own
`sqrtPriceLimitX96` less one sqrt-price unit. It reads the ETH the pool actually took or paid, charges
0.5% of that (the full-fill quote above when the leg filled completely, so a full fill costs exactly
the specified amount), and passes the PRIO side of the leg to the swapper through the before-swap
delta. On a full fill the outer swap has an amount of zero and does nothing. On a partial fill (price
limit reached or liquidity exhausted) the swapper pays `filled + ceil(filled·50/10000)` on a buy and
receives `filled − ceil(filled·50/10000)` on a sell, keeps or is owed nothing else, and the outer swap
only covers the last sqrt-price unit, which exchanges nothing or a few wei (fee-free). A seller never
pays ETH. Two `Swap` events appear per such swap (the hook's leg and the router's remainder). Tested in
`TreasuryFeeHookPartialFillTest` for both directions, with a liquidity-exhausted thin pool and with a
router price limit 0.5% from spot, plus a fuzz over amounts.

Views for quoting a full fill: `feeOnLeg`, `quoteBuyExactInput`, `quoteSellExactOutput`. Wei level: a
1-wei buy is refused (`SwapTooSmall`: the whole wei would be fee and nothing would be left to swap);
from 2 wei up the fee is `max(1, ceil(leg·0.005))` wei, so inputs of 2–201 wei pay a 1-wei fee.

**Settlement in ETH.** The fee is always ETH, taken inside the swap that paid it. When the PoolManager
holds at least the fee in ETH, the hook `take`s it to itself and forwards it to the bound treasury in
the same transaction. When it does not (the launch pool is seeded with PRIO only, so the first buys
see no ETH in the manager), the hook mints itself an ERC-6909 ETH claim; anyone may later call
`redeemClaims(amount)`, which unlocks the manager, burns the claim and forwards ETH to the treasury.
Both paths are tested (`TreasuryFeeHookTest`, `TreasuryFeeHookClaimsTest`). If the treasury ever
refused ETH the hook keeps the ETH in `pendingEth` and `flush()` retries later; a swap is never
reverted because of fee delivery, and the fee is never dropped. `FeeTreasury.receive` only accepts
ETH from the hook, and the hook's `receive` only accepts ETH from the PoolManager, so every wei the hook
holds is fee ETH mirrored in `pendingEth`.

**Pool binding.** `beforeInitialize` accepts one pool only, from the factory: ETH as `currency0`,
PRIO (the `$token` constructor argument) as `currency1`, this hook, any static LP fee. The
`PoolKey` is recorded; swaps on any other key revert, and a second initialization reverts.
Ordinary PRIO transfers and other pools carry no fee.

**Quote tick limits.** The hook does not override the LP fee. Routers quote with the hook (the v4
Quoter simulates hook deltas, nested swap included) and set their own price limit; the pool stops at
exactly that limit, and the ETH leg used for the fee is whatever the pool exchanged within it, so a
partially filled swap pays 0.5% of the partial leg (see "Partial fills"). A limit within one
sqrt-price unit of spot exchanges at most a few wei and pays no fee. The treasury's own buys use the
full range limit, a `minOut` and the owner's price floor, and credit any unfilled ETH back to the
budget.

**Compatibility.** Tested against v4-core's `PoolManager`, `PoolSwapTest` and
`PoolModifyLiquidityTest` routers (the production manager and its reference routers), with the pool
opened by a factory address through `PoolManager.initialize`, and against the IMD protected floor
tests (mined flags, callback refusal, initialization from the factory probe, no escape hatches).

## FeeTreasury

- Income: ETH from the hook only (`totalIncome`). No owner advance is possible; without income nothing
  is paid.
- `allocate()` (anyone): reserve takes `min(10% of the allocation, reserveTarget − reserve)`, then the
  rest goes 30% `imdBudget`, 30% `prioBudget`, 40% `ownerBudget`. Reserve target default 0.5 ETH, hard
  cap `MAX_RESERVE_TARGET = 2 ETH`: a finite, documented reserve.
- `withdrawReserve` (owner or executor) pays the operator wallet's gas from the reserve only: the
  fee-funded gas bootstrap. The executor may draw it only to its own address and at most
  `reservePerWindow` per 24h bucket; the owner is unrestricted. `withdrawOwner` is capped by `ownerBudget`.
- `buyPrio(ethIn, minOut)` (executor): bounded by `prioBudget`, `maxSpendPerSwap` per call and
  `spendPerWindow` per 24h bucket (shared with `buyImd`; a fixed bucket, so at most 2× `spendPerWindow`
  in any 24h span), swaps ETH→PRIO on the hooked pool through
  the PoolManager (paying the 0.5% back to itself), checks `minOut` **and** the owner's `minPrioPerEth`
  floor on the ETH actually spent, then sends half to `StakingVault.notifyReward` and half to
  `Arena.fundPrizes`. Works with no IMD configuration. If the pool fills only part of `ethIn`, only the
  filled ETH leaves the budget: `balance == unallocated + reserve + imdBudget + prioBudget + ownerBudget`
  holds after every call (tested).
- `buyImd(ethIn, minOut)` (executor): same bounds on `imdBudget` and the `minImdPerEth` floor, on the
  owner-set IMD pool (whose `currency1` must be the configured IMD), output to the `OracleAdapter`.
- A swap the pool cannot fill at all (nothing to sell below the current price: the PoolManager walks to
  the price limit and returns a zero delta without reverting) is not a purchase: both functions revert
  `NoFill`, so a zero fill never freezes a binding, never emits a `…Bought(0, 0)` event and never parks
  the pool at the limit. The operator treats `NoFill` like `PriceLimitAlreadyExceeded` and backs off.
- Swaps are executor-gated because a permissionless swap with a caller-chosen `minOut` would be a
  sandwich target; the window cap and price floors bound what a stolen executor key can do (at most
  2 × `spendPerWindow` in any 24h span, never below the floor, reserve draws only to itself within
  `reservePerWindow`); allocation, flushing and claims are permissionless.

## StakingVault

Synthetix-style streaming: `notifyReward(amount)` (treasury or owner) pulls PRIO and streams it
linearly over `rewardsDuration` (default 30 days, owner-settable 1–365 days for *future*
notifications; an active stream keeps its schedule, and leftover rolls into the next). Rewards accrue
pro rata to `staked[user] × time`. When `periodFinish` passes accrual stops until the next funding.
**The stream pauses while nothing is staked**: seconds with `totalStaked == 0` are not consumed,
`periodFinish` moves forward by exactly the idle time, and the whole funded amount is still paid to
whoever stakes later (the treasury's first purchase typically arrives before the first staker). A
notification is refused unless `balance − totalStaked ≥ rewardsOwed`, so no unfunded accrual, no
APY, no minting, and nothing funded is streamed to nobody. Principal is isolated: `totalStaked` is
never spent, `withdraw` returns exactly the stake, and the invariant test checks
`balance ≥ totalStaked + rewardsOwed` under random actions.

## Arena

Published, fixed scoring for every mode (constants in the contract):

| Outcome | Returned per entry | Loss |
| --- | --- | --- |
| correct choice | 100 PRIO + equal share of the round's prize | 2 (fee) |
| wrong choice | 90 PRIO | 12 |
| missed reveal | 80 PRIO | 22 (`MAX_LOSS`) |
| cancelled round | 102 PRIO | 0 |

Penalties never stack. Entry pulls exactly 102 PRIO from the player's approval and never more; the
Arena never touches staking principal (a separate contract).

- **Modes.** Vault Raid: `choiceCount` vaults, pick the one the panel finds. Faction duel: two
  factions. Boss challenge: cooperative; the prize is paid only if at least `bossThreshold` players
  chose correctly, otherwise correct players keep 100 PRIO and the prize returns to the game pool.
- **Winning choice** = `(oracle answer mod choiceCount) + 1`, from the `OracleAdapter` result for the
  round's pinned question. No result, no settlement.
- **Frozen before entry.** `createRound` locks the prize from the funded game pool and fixes mode,
  choices, deadlines, threshold, `rulesHash` (hash of the published rules text), **and the result
  source**: the adapter address and the question hash pinned there for this round id, whose
  `notBefore` must equal the round's commit deadline (`QuestionNotPinned` otherwise). `settle` and
  `cancel` read the round's own adapter, so `Arena.setOracle` only affects later rounds; the adapter
  keeps a pinned question and the signer pinned with it immutable, so `setSigner` only affects later
  pins. There is no edit.
- **Commit-reveal.** `enter(roundId, keccak256(abi.encode(roundId, player, choice, salt)))` before
  `commitDeadline`; `reveal(roundId, choice, salt)` between `commitDeadline` and `revealDeadline`.
  Players must back up their salt; a lost salt is a missed reveal (80 back).
- **Settlement** (`settle`, anyone, after `revealDeadline`, no upper bound) is O(1): tallies are counted
  at reveal. The result's `issuedAt + 5 minutes` must be ≥ `commitDeadline`, the same tolerance the
  adapter uses (and the adapter stores nothing before `commitDeadline` on the chain clock). The Arena
  also checks for itself that the adapter still pins the question hash the round was created against
  (`QuestionChanged` otherwise): a result for any other question never settles the round.
- **Cancellation** (`cancel`, anyone) 72 hours after `resultDeadline` **only while the round is
  unresolved** (`resolved(roundId)` is false: no valid result on file at the round's adapter for the
  round's own question): prize back to the pool, every entry refundable at 102 PRIO. A round with a
  result on file can only be settled, so the two outcomes never compete; a result relayed after a
  cancellation changes nothing. `resultDeadline` is at most 30 days after `commitDeadline`
  (`MAX_ROUND_LENGTH`), so escrow is never held in a round whose cancel path is out of reach.
- **Pull claims by round:** `claim(roundId)` / `refund(roundId)`; old rounds stay claimable forever.
- **Game-pool allocations.** Entry fees, penalties and prize dust go to `unallocatedPrizePool`, which
  funds future prizes together with the treasury's PRIO purchases. Prizes of rounds with no correct
  player (or a failed boss) return to it.
- **Ties.** Every correct player receives the same share (`prize / correct`); there is no ranking, so
  no tie-break is needed.
- **Multi-wallet risk.** Nothing on chain stops one person entering from several wallets to cover
  more choices; the owner should size prizes so that covering all choices (`choiceCount × 12 PRIO`
  loss) is not profitable, and the boss threshold adds a group requirement. No guaranteed profit
  exists for anyone.

## OracleAdapter

Inherits the protocol's `OracleAttestationConsumer` (copied from the oracle-consumer skill; the
conformance vector test passes). Per round the owner pins the question hash, the chain the question
is about, minimum panel and quorum, the body and `notBefore` (the commit deadline); the trusted signer
at that moment is recorded with the pin. An attestation is accepted only if `block.timestamp ≥
notBefore` (nothing is on chain while the Arena still accepts commitments), it is signed by the
**pinned** signer in **this contract's** EIP-712 domain, not expired, `issuedAt ≤ now + 5 min`,
`issuedAt + 5 min ≥ notBefore` (signer clock-skew tolerance, consistent with the Arena's settle
check), question hash and chain match, `panelSize ≥ minPanel`, `quorum ≥ minQuorum`,
`agreed ≥ quorum`, the answer is a `uint256`, and `requestId` was not consumed. The stored `Result`
carries the answer and the evidence reference (request id, panel job id, block window and hash).

Two paths in: the Intake's callback `onOracleResult` (only from the configured intake, only for a
request this contract made, under the 200 000 gas stipend, tested) and the manual relay
`submitAttestation`. Because the pinned question is public and the oracle sells answers to anyone, a
relay from an arbitrary address is accepted only when the attestation answers this adapter's own request
(`requestId` registered by `request()`); any other attestation may be relayed only by the executor or
the owner, so nobody can buy competing answers and front-run the operator. One paid request per round
is open at a time (`RequestPending`). Paid requests (`request(roundId)`, executor only) are disabled
until intake, action, asset+price, callback switch, executor and budget are set and the contract holds
IMD, and refused before the round's `notBefore` (an answer bought while commitments are open could leak
or be wasted); `clearStale` forgets a request after 2 days (a refused or non-agreeing panel never calls
back and the price is spent). A pin can be replaced only while the Arena named with `setArena` has not
created the round, nothing is settled and no request is open; afterwards it is immutable. `setArena` is
one-shot, so the Arena whose `roundCount` decides that can never be swapped for one reporting fewer
rounds; and while an Arena is set, no result is stored and no paid request is made for a round id it
has not created (`RoundNotCreated`), so a lapsed pin stays replaceable instead of being bricked by a
stray answer. `withdrawToken` returns stray tokens but never the payment asset nor any token that has
ever been the payment asset (`wasAsset`): the IMD bought for agent work stays for panel answers, and
renaming the asset with `setPayment` does not release it.

## Server operator

See `docs/OPERATOR.md`. `operator/operator.py` (stdlib only) does capabilities / check / quote /
payment / polling / retries / result relay / proposals / treasury purchases, with daily IMD, gas and
request caps, a simulate-first purchase path that backs off on `PriceLimitAlreadyExceeded` instead of
re-sending, and a `paid_operations_enabled` switch that stays off until configuration and fee funding
are done. Keys stay server-side. Agent outputs are proposals only.

## What the brief asked that the token does not do

Nothing extra was asked of the token itself; the fee lives in the hook as the launch requires. The
launch also fixes the supply split, so no contract here receives tokens at launch; the vault, arena and
treasury hold only what users and purchases put in afterwards.

## Trust assumptions (owner powers that remain)

The paying wallet owns the project. Beyond the immutable parts (the 0.5% fee, an open round's rules,
oracle, question and reserved payouts, the hook/prio/sink/IMD bindings once used, the one-shot
`setArena`, the funded-only reward stream, the IMD ever configured as payment asset), the owner still
decides: the reserve target and purchase caps, the price floors (a floor above the market pauses
purchases), the IMD venue (`setImdPool`, bounded by the `minImdPerEth` floor), the oracle payment asset
and price (`setPayment`; a former asset stays non-withdrawable), the signer and adapter for *future*
rounds, the operator wallet and its budgets, and the 40% owner budget. None of these can reach staking
principal, Arena escrow, locked prizes or an open round.

Two further assumptions are by design and worth knowing:

- **Who can settle.** A stranger may relay only an attestation answering a paid request this adapter
  made. With no open request (paid operations disabled, or a cleared stale request) only the executor or
  the owner can store a result, so they choose between settlement and the permissionless cancel 72 hours
  after `resultDeadline` (winners then get 102 PRIO back instead of 100 plus a prize share). This is what
  stops players from buying competing answers; the owner may also be a player, so a public operator log
  of every relay is the mitigation.
- **Reserve top-ups and the 30/30/40 split.** `allocate()` sends up to 10% of each allocation to the
  reserve while it is below `reserveTarget`, and the owner's `withdrawReserve` is not rate-limited. An
  owner who empties the reserve before every allocation receives 46% of fees (10% + 40% of 90%) and
  IMD/PRIO 27% each. The 30/30/40 split applies after the reserve top-up; the reserve is meant for
  operator gas (`reservePerWindow` bounds the executor), and the target is capped at 2 ETH.

## Assumptions

- "0.5% on the ETH leg, excluding fees" is read as 0.5% of the ETH amount exchanged with the pool,
  charged on top of (not inside) the LP and protocol fees.
- The IMD trading venue for `buyImd` is a Uniswap v4 ETH/IMD pool the owner names; if IMD trades
  elsewhere, the IMD budget simply accumulates until a venue is configured.
- The HTTP door paths in `operator.example.json` are configurable; the on-chain Intake flow is the
  authoritative one and is what the contracts test.

## Layout

```
src/            contracts            test/      Foundry tests (+ utils/Fixture.sol, utils/MockIntake.sol)
script/         Deploy.s.sol, ConfigPlan.s.sol    docs/abi/  ABIs    docs/DEPLOYMENT.md  docs/OPERATOR.md  docs/REVIEW.md
ADAPTATION.md   every change made for the contracts-only launch and why
operator/       operator.py, test_operator.py, operator.example.json
lib/            vendored dependencies
```
