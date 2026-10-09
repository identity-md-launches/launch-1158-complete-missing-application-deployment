# Review record: prior findings, fixes and the self-review

## Prior attempt

Job `bbf45a6b` (explorer) built a first version, ended with "audit_judge exhausted its attempts" and
was blocked before any deployment ("No transactions were broadcast"). Its source repository
(`identity-md-launches/launch-1012-workflow-contract-stage-context`) contains only the empty
workspace commit, so the audit text itself is not retrievable; the brief for this job lists the
findings that must be fixed. Each is addressed below with the test that proves it.

| Finding named in the brief | Fix in this project | Evidence |
| --- | --- | --- |
| Reserve / withdrawal caps missing | `FeeTreasury.allocate` caps the reserve at 10% of each allocation and at a finite `reserveTarget` (≤ 2 ETH); `withdrawOwner` and `withdrawReserve` cannot exceed their budgets | `test_allocationSplitAndReserveCap`, `test_reserveStopsAtTarget`, `test_ownerAndReserveWithdrawalsAreCapped` |
| Old rounds not claimable | Arena state and claims are indexed by round; `claim`/`refund` work for any settled/cancelled round forever | `test_oldRoundStaysClaimableAfterNewRounds` |
| Penalties stacking | One penalty per entry: `payoutOf` returns 100 / 90 / 80 / 102, never less; `MAX_LOSS = 22` | `test_noWinnerReturnsPrizeToPool`, `test_constantsPublished` |
| Fee silently dropped / incompatible deployment | Hook validates its flags in the constructor; initialization refuses any pool but ETH/PRIO from the factory; fee is a constant and the claim path keeps it when ETH cannot move | `test_constructorRefusesMismatchedAddress`, `test_initializeOnFreshHookRefusesWrongPair`, claims suite |
| Owner advances / unfunded operations | `FeeTreasury.receive` accepts ETH from the hook only; `OracleAdapter.request` refuses until configured and funded | `test_onlyHookCanFund_noOwnerAdvances`, `test_paidRequestDisabledUntilConfigured` |
| Unfunded reward accrual | `StakingVault.notifyReward` refuses unless balance − principal covers all owed rewards; accrual stops at `periodFinish` | `test_noRewardsWithoutFunding`, `test_rewardsProRataByStakeAndTime_andStopAtPeriodEnd`, `invariant_vaultCoversPrincipalAndOwedRewards` |
| Oracle evidence missing / replay | Pinned question hash, chain, panel, quorum, `agreed >= quorum`, issued-at boundary, expiry, consumed request ids; evidence stored | `OracleAdapterTest` |
| Ownership renounceable / one-step | `TwoStepOwned`: `Ownable2Step`, `renounceOwnership` reverts | inherited everywhere |

## Round 2: the independent reviewer's findings on the accepted tree

Each was reproduced first (the reviewer's four proof tests failed on the starting tree, 6/6 failing
tests) and fixed at the cause; `.imd-responses.json` carries the per-finding answer.

| Finding | Fix | Evidence |
| --- | --- | --- |
| [high] ETH-specified swaps charged 0.5% of the *requested* amount; partial fills overcharged, an exact-output sell could make the seller pay ETH | `beforeSwap` runs the pool leg itself (nested swap by the hook, swapper's limit less one unit), charges 0.5% of the ETH actually exchanged, passes the PRIO side via the before-swap delta | proof passes; `TreasuryFeeHookPartialFillTest` (7 tests incl. fuzz) |
| [high] StakingVault streamed to nobody while `totalStaked == 0`; that PRIO was locked forever | idle seconds extend `periodFinish`; the stream pauses and resumes in full | proof passes; `test_streamPausesWhileNothingIsStaked_nothingStranded`, `test_streamPausesAgainWhenEveryoneLeaves`, `test_notifyWhileIdleKeepsRemainderAndRestartsSchedule` |
| [medium] OracleAdapter stored an answer up to 5 min before the commit deadline while entries were open | `_accept` and `request` revert `BeforeBoundary` while `block.timestamp < notBefore`; operator refuses early too | proof passes; `test_nothingIsStoredOrRequestedBeforeTheBoundary`, operator `test_request_waits_for_the_commit_boundary` |
| [medium] FeeTreasury debited `ethIn` but settled only the filled part; the rest left every budget line | `unlockCallback` returns `(out, owed)`; unspent ETH is credited back | proof passes; `test_partialFillCreditsUnspentEthBackToTheBudget` |
| [medium] A round's result source was not frozen (oracle swap, signer rotation, late pin) | round snapshots adapter + question hash, requires the pin at its commit boundary; adapter pins the signer with the question | `test_createRoundNeedsPinnedQuestionAtTheCommitBoundary`, `test_ownerCannotSwapOracleForAnOpenRound`, `test_signerRotationDoesNotReachPinnedRounds`, `test_pinnedSignerOutlivesRotation` |
| [medium] After the grace, `cancel` and `settle` were both live on a round with a result | `cancel` reverts `RoundResolved` when a valid result is on file (`resolved()` view) | `test_resolvedRoundCannotBeCancelled_onlySettled`, `test_unresolvedRoundCancelsAndALateResultCannotSettleIt` |
| [low] executor bounded per call only, `minOut` executor-chosen | rolling `spendPerWindow` cap and owner price floors (`setPriceFloors`, required) | `test_rollingWindowAndPriceFloorBoundTheExecutor` |
| [low] `setImd` / `setImdPool` uncoupled | `setImd` unsets the pool; `buyImd` checks `currency1 == imd` | `test_setImdUnsetsThePoolKey` |
| [low] `bindTreasury` one-shot and unverified | refuses a treasury bound to another hook; correctable until the first delivery | `test_treasuryBindingIsCorrectableUntilFirstDelivery_thenImmutable` |
| [low] hook `receive()` open to anyone | `onlyPoolManager` | `test_receiveRefusesEveryoneButThePoolManager` |
| [low] re-settable sinks / `withdrawToken` as owner powers | sinks one-shot and non-zero; `withdrawToken` refuses the payment asset; the rest documented under "Trust assumptions" | `test_sinksAreSetOnceAndNonZero`, `test_withdrawTokenRefusesTheConfiguredAsset` |
| [info] README wrong about a 1-wei buy | 1-wei buy reverts `SwapTooSmall`; README corrected | `test_oneWeiBuyIsRefusedNotSwallowed` |

Design note on the hook fix: a before-swap delta can only move the specified currency, and
`afterSwap` can only move the unspecified one, so for ETH-specified shapes the only way to charge
exactly 0.5% of the *filled* leg without reverting partial fills or refunding out of band is for the
hook to execute the leg itself and learn the fill. v4's `Hooks` library skips callbacks when the hook
is the caller, the outer swap with amount zero is a no-op, and the one-unit limit offset keeps the
outer remainder swap legal on a partial fill. Delta accounting stays zero for the hook on every path
(`testFuzz_feeChargedMatchesTreasuryIncome`, `testFuzz_partialFillFeeIsAlwaysOnTheFilledLeg`).

## Self-review against the uniswap-v4-security checklist

| # | Check | Result |
| --- | --- | --- |
| 1 | callbacks verify `msg.sender == poolManager` | `onlyPoolManager` on every implemented callback and `unlockCallback`; protected floor test passes |
| 2 | router allowlisting | not needed: the fee is charged whoever routes; `sender` is not trusted for anything |
| 3 | unbounded loops | none in any callback; Arena settlement is O(1) |
| 4 | reentrancy | hook's only external calls are to the PoolManager and the treasury's `receive()`; treasury, vault, arena use `ReentrancyGuard`; CEI in `flush` |
| 5 | delta accounting | PRIO-specified shapes: the hook returns exactly the amount it `take`s/`mint`s. ETH-specified shapes: the hook's nested-swap delta (−leg ETH, +PRIO) plus its before-swap return (+leg+fee ETH, −PRIO) minus the fee it `take`s/`mint`s is zero in both currencies. Fuzzed: `testFuzz_feeChargedMatchesTreasuryIncome`, `testFuzz_partialFillFeeIsAlwaysOnTheFilledLeg` |
| 6 | fee-on-transfer | PRIO is standard; ETH side only |
| 7 | hardcoded addresses | none: PoolManager, token, factory, owner are constructor args; intake, signer and venues are owner-set |
| 8 | slippage | treasury swaps take `minOut`; routers set their own limits (see README "Quote tick limits") |
| 9 | sensitive data | none on chain |
| 10 | upgrade mechanisms | none; no delegatecall, no selfdestruct (floor test) |
| 11 | `beforeSwapReturnDelta` justified | only on ETH-specified swaps; the specified side carries the filled ETH leg plus 0.5% of it and the unspecified side passes the pool's PRIO leg to the swapper. The outer swap is a no-op only because the hook executed the identical leg itself at the swapper's limit (not a NoOp that withholds the trade); `HookDeltaExceedsSwapAmount` bounds it to the specified amount |
| 12 | fuzz | quote identity and fee conservation fuzzed |
| 13 | invariants | vault and arena accounting invariants run under a handler |

## Round 3: the pre-launch audit of this tree (contracts-only launch)

Seven findings (one medium manifest finding, one medium adapter finding, four low, one info). Each was
reproduced before it was fixed; the change list, tests and the verified live records are in
`ADAPTATION.md` and `docs/DEPLOYMENT.md`.

## Known limitations and open items

- **Independent review before deployment** is required by the brief and is not something this job
  can perform on itself. This document is the hand-off for that reviewer.
- **Mainnet deployment and receipts**: the token, hook and distributor are live (launch 1153); the four
  application contracts are deployed by the contracts-only launch from the manifest, which records the
  addresses. No application contract exists yet (checked 2026-10-09), so nothing is duplicated.
- **Slither/Mythril** were not available offline; `forge build`'s lints were reviewed (all are
  informational: timestamp comparisons that the design needs, events after the external calls that
  produce them).
- **IMD venue**: where IMD trades against ETH on mainnet was not given; `FeeTreasury.setImdPool`
  is the owner's setting and PRIO purchases do not depend on it.
