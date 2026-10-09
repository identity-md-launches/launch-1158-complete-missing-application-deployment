# Adaptation for the contracts-only launch (2026-10-09)

Source: `identity-md-launches/launch-1153-build-test-independently-review` at `34e992ab`. Launch kind
`evm_contracts` on Ethereum (chain id 1). It deploys **FeeTreasury, StakingVault, Arena, OracleAdapter**
only. PRIO, the TreasuryFeeHook, the distributor and the ETH/PRIO pool are live from launch 1153 and are
not touched. No token, hook, distributor or pool is added. `launch.json` is written by the manifest step,
not here.

## Live records verified before changing anything

Checked on mainnet at block 26154434 through `ethereum-rpc.publicnode.com`, Blockscout and
`api.imd.fun` (details and the exact reads in `docs/DEPLOYMENT.md`):

| Record | Result |
| --- | --- |
| tx `0x545df1ad…6dd7d` | success, block 26154170, to factory `0x12C63b58…A96F`; created PRIO, the hook and the distributor |
| PRIO `0xfd1c2349…7a2c` | `symbol() = PRIO`, supply 1e27, code present |
| hook `0x65a783cc…60cc` | `owner()` = project owner, `pendingOwner()` = 0, `token()` = PRIO, `poolManager()` = `0x0000…8a90`, `initialized()` = true, `FEE_BPS()` = 50, **`treasury()` = 0**, `pendingEth()` = 0 |
| project owner `0x13afb9b5…8eac` | last transaction block 26154147 (before the launch), no contract created since: **no FeeTreasury / StakingVault / Arena / OracleAdapter exists**, so deploying the four is not a duplicate |
| launch 1153 (`api.imd.fun/launches`) | kind `univ4_hook`, 3 artifacts (token, hook, distributor); no `evm_contracts` launch for this project |
| IMD `0xd34a99bc…63b7`, Intake `0x1397434c…ea56` | code present; `Intake.priceOf(oracle.request@oracle-1, IMD)` = 0.5 IMD |
| oracle signer | `api.imd.fun/oracle/requests` top-level `attester` and every attested request: `0x5598aa9146215bc13eb26f2c692ad1461fd32982` (matches README) |

No companion address was invented: the hook's `treasury()` is zero and stays zero until the owner signs
step A4 of the plan.

## Constructor arguments the manifest step will carry

All four constructors take two static `address` arguments, call no other contract, and were rehearsed on
an empty chain (`test/LaunchAdaptation.t.sol`, and the protected floor test run locally with the built
creation code: 1/1 pass, runtimes 10822 / 3788 / 9276 / 11648 bytes after the revision below, no
DELEGATECALL/CALLCODE/SELFDESTRUCT).
The brief names the owner, so it is written as that static address rather than `$owner`.

| Contract | constructorArgs |
| --- | --- |
| `FeeTreasury` | `0x000000000004444c5dc75cb358380d2e3de08a90` (PoolManager), `0x13afb9b5780cd9ae79c61503adb69c57845d8eac` (owner) |
| `StakingVault` | `0x13afb9b5780cd9ae79c61503adb69c57845d8eac` (owner), `0xfd1c234972768c23bb21d655966e0b122dd67a2c` (PRIO) |
| `Arena` | `0x13afb9b5780cd9ae79c61503adb69c57845d8eac` (owner), `0xfd1c234972768c23bb21d655966e0b122dd67a2c` (PRIO) |
| `OracleAdapter` | `0x13afb9b5780cd9ae79c61503adb69c57845d8eac` (owner), `0x5598aa9146215bc13eb26f2c692ad1461fd32982` (oracle signer) |

## Changes, file by file

| # | Change | File(s) | Why |
| --- | --- | --- | --- |
| 1 | **Removed `launch.json`** (the previous `univ4_hook` manifest with `$poolManager`/`$token`/`$factory`). | `launch.json` (deleted) | Audit finding `5c7be0db` (medium): a `launch.json` in the tree is checked as an `evm_contracts` manifest and refused. The manifest step writes the new one from the table above. |
| 2 | **OracleAdapter: an attestation settles a round from any relayer only if it answers this adapter's own request** (`a.requestId` registered by `request()`); any other attestation may be relayed only by the executor or the owner (`NotRelayer`). `request()` refuses a second request while one is open for the round (`RequestPending`, `openRequest`), and refuses a zero or reused intake id. | `src/OracleAdapter.sol` | Finding `d260feaf` (medium), reproduced: the question body is public and the oracle sells answers to anyone, so whoever relayed a second panel answer first fixed the result, and duplicate requests spent budget. Tests: `test_competingAttestationCannotBeRelayedByAStranger_ownRequestCanBeRelayedByAnyone`, `test_ownRequestIdForAnotherRoundIsNotAFreePass`, `test_secondRequestForAnOpenRoundIsRefusedUntilAnsweredOrCleared`. Existing relay tests now relay as the owner. The Intake callback path is unchanged. |
| 3 | **OracleAdapter: a pin can be replaced until the Arena has created the round.** New owner setter `setArena`; `pinQuestion` overwrites an existing pin only when `arena` is set, `Arena.roundCount() < roundId`, no result is stored and no request is open. Without `setArena` pins stay immutable. | `src/OracleAdapter.sol` | Finding `0fb49e68` (low), reproduced: one pin with a past `notBefore` for `roundCount + 1` blocked every future round. Test: `test_mistakenPinCanBeReplacedUntilTheArenaCreatesTheRound`. The "frozen result source" property of open rounds is kept: once `createRound` consumed the id the pin cannot change. |
| 4 | **FeeTreasury: `setSinks` checks `StakingVault.prio()` and `Arena.prio()` against the configured PRIO** (`SinkMismatch`, requires `setPrio` first) and **`bindHook`/`setPrio`/`setSinks` are correctable until used**: the hook until the first fee arrives (`totalIncome != 0`), PRIO and the sinks until the first successful purchase (`purchased`). Afterwards they are immutable as before. | `src/FeeTreasury.sol` | Finding `0cd78a87` (low), reproduced: swapped or foreign sinks froze the 30% PRIO budget forever. Mirrors `TreasuryFeeHook.bindTreasury`. The reviewed economics are unchanged: once money has flowed nothing can be redirected. Tests: `test_sinksAreCheckedAndCorrectableUntilFirstPurchase_thenFrozen`, `test_hookBindingIsCorrectableUntilFirstIncome`; `test_configurationIsOwnerOnlyAndOneShotWhereStated` updated to the new rule. |
| 5 | **FeeTreasury: the executor may draw the reserve only to its own address and at most `reservePerWindow` per `SPEND_WINDOW` bucket** (default 0.05 ETH, owner setter `setReservePerWindow`, errors `WrongDestination` / `ExceedsWindow`). The owner path is unchanged. | `src/FeeTreasury.sol` | Finding `aac12d4e` (low), reproduced: a stolen executor key could send the whole reserve anywhere. The brief asks for a bounded executor. Tests: `test_ownerAndReserveWithdrawalsAreCapped` (rewritten), invariant handler now draws to itself within the cap. |
| 6 | **Spend window documented as a fixed bucket**, not a rolling window: at most 2 × `spendPerWindow` can leave in any 24-hour span. NatSpec, README and OPERATOR.md corrected; a test pins the bound. | `src/FeeTreasury.sol` (comments), `README.md`, `docs/OPERATOR.md` | Finding `e06da50e` (low), reproduced. The code is unchanged (the audit's "document the bucket semantics" option); the owner sizes `spendPerWindow` knowing the 2× bound. Test: `test_spendWindowIsAFixedBucket_atMostTwiceThePerWindowCapInAnyDay`. |
| 7 | **`script/Deploy.s.sol`: `deployApplications(AppConfig)`** deploys only the four with the live addresses as inputs; `deployAll` is kept for the existing six-contract rehearsal test. | `script/Deploy.s.sol` | The launch deploys four contracts, not six; the script is the reviewable mirror of the manifest. Test: `test_deployScriptMatchesTheManifestArguments`. |
| 8 | **`script/ConfigPlan.s.sol`**: the owner's post-launch transactions as an ordered, pure list of (target, calldata); `show(...)` prints them for the live addresses. **`test/LaunchAdaptation.t.sol`** deploys the four from creation code with the static arguments on an empty chain, checks size and opcodes, and executes the whole plan against local copies of the live hook and PRIO at their mainnet addresses. | `script/ConfigPlan.s.sol`, `test/LaunchAdaptation.t.sol` | The brief asks for the configuration transactions to be prepared and simulated, in order, for the owner to review and sign. Preparation is not execution: nothing here signs or broadcasts. |
| 9 | **Operator: `buy-prio` / `buy-imd` commands**, simulate-first; on `PriceLimitAlreadyExceeded` (selector `0x7c9c6e8f`) a persistent, doubling backoff (1h → 24h cap) blocks further attempts until it expires; any other revert sends nothing and arms nothing; a filled purchase resets it. | `operator/operator.py`, `operator/test_operator.py`, `operator/operator.example.json` | The brief: handle `PriceLimitAlreadyExceeded` by backing off until pool liquidity returns rather than wasting gas. Tests: `PurchaseBackoffTests` (3). |
| 10 | README status, deployment table and after-launch steps updated; `docs/DEPLOYMENT.md` added (verification record, manifest arguments, ordered owner transactions with calldata, IMD pool/Intake configuration, operator budgets, checklist); ABIs in `docs/abi/` regenerated. | `README.md`, `docs/DEPLOYMENT.md`, `docs/OPERATOR.md`, `docs/REVIEW.md`, `docs/abi/*.json` | Finding `1e9a22a3` (info): the README said nothing was deployed; the token and hook are live. |

### Revision after independent review (2026-10-09)

Every reviewer finding below was reproduced first (the four with proofs by running the proof under
`test/scratch/`: all four failed on the starting tree and pass now). Answers per id are in
`.imd-responses.json`.

| # | Change | File(s) | Why |
| --- | --- | --- | --- |
| 11 | **`OracleAdapter.setArena` is one-shot** (`ArenaAlreadySet`). | `src/OracleAdapter.sol` | Finding `04dbc34c` (medium), reproduced with the proof: the owner could re-point `arena` at a contract reporting `roundCount() == 0`, re-pin an open round's question and signer and settle it on a self-signed answer. The Arena that decides which pins are consumed can no longer be swapped. Test: `test_setArenaIsOneShot`. |
| 12 | **`Arena.settle` / `resolved` check that the round's adapter still pins the question hash the round was created with** (`QuestionChanged`; `resolved()` is false, so the round falls back to cancel/refund). | `src/Arena.sol` | Same finding, Arena side ("have the Result carry the question hash so Arena.settle can compare it"): the Arena enforces its own "frozen result source" promise even against a misconfigured adapter. Test: `test_settleRefusesARoundWhosePinnedQuestionChanged`. |
| 13 | **OracleAdapter refuses a result (`_accept`, both the relay and the Intake callback) and a paid `request()` for a round id the configured Arena has not created** (`RoundNotCreated`). Without `setArena` the behaviour is unchanged (pins immutable, as before). | `src/OracleAdapter.sol` | Finding `615b6c64` (medium), reproduced with the proof: a result stored for a pinned-but-uncreated round made the pin non-replaceable and the id (hence every later round) impossible to create. Tests: `test_noResultForARoundTheArenaHasNotCreated_pinStaysReplaceable`, `test_intakeCallbackForAnUncreatedRoundIsRefused`; `test_mistakenPinCanBeReplaced…` updated (a request now needs the round to exist). README/DEPLOYMENT: sign A7 before the first pin. |
| 14 | **`OracleAdapter.withdrawToken` refuses every token ever configured as the payment asset** (`wasAsset`, set by `setPayment`). | `src/OracleAdapter.sol` | Finding `02cf1770` (medium), reproduced with the proof: three owner calls (rename asset, withdraw, rename back) moved the IMD bought from the 30% agent-work line to the owner. Test: `test_withdrawTokenRefusesEveryFormerAsset`. |
| 15 | **`FeeTreasury._swapEthFor` reverts `NoFill` when the pool filled nothing** (`spent == 0 \|\| out == 0`), so a zero fill is never a purchase. | `src/FeeTreasury.sol` | Finding `95221d55` (medium), reproduced with the proof: against an exhausted or empty pool the PoolManager returns a zero delta without reverting; with the operator's `minOut = 0` the call "succeeded", set `purchased`, emitted `ImdBought(0,0)`, parked the pool at the limit and cleared the operator backoff. Test: `test_zeroFillIsNotAPurchase`. |
| 16 | **Purchase freeze split per line**: `prioPurchased` (set by `buyPrio`) freezes `setPrio` and the vault/arena sinks; `imdPurchased` (set by `buyImd`) freezes `setImd` and the OracleAdapter sink. `purchased()` stays as a view (`prioPurchased \|\| imdPurchased`). `setImdPool` stays movable (documented: the venue follows liquidity, bounded by the floor). | `src/FeeTreasury.sol` | Findings `d6110259` (low): `setImd` stayed mutable after purchases while the contract notice said the IMD line could not be redirected; and `f3a579d3` (low): a PRIO-only purchase froze the OracleAdapter sink before any IMD had flowed, so a typo in A3's third argument was permanent. Tests: `test_sinksAreCheckedAndCorrectableUntilFirstPurchase_thenFrozen` and `test_setImdPoolRequiresImdFirst_thenBuyImdDeliversToAdapter` (both updated to the per-line rule). No interface check of the adapter was added: nothing an adapter exposes distinguishes it from a look-alike, and the correctability window is the real protection. |
| 17 | **`Arena.MAX_ROUND_LENGTH = 30 days`**: `createRound` refuses `resultDeadline > commitDeadline + 30 days`. | `src/Arena.sol` | Finding `064e2296` (low): nothing capped `resultDeadline`, so escrow could sit in a round whose cancel path was unreachable. Test: `test_roundLengthIsCapped`. |
| 18 | **Operator sends `minOut` = simulated fill × `min_out_bps_of_quote` / 10000** (default 9700), never 0; a simulation that returns no decodable fill sends nothing; `NoFill` (`0x87a41aac`) arms the same backoff as `PriceLimitAlreadyExceeded`. The unused `min_out_bps_of_floor` key was replaced. | `operator/operator.py`, `operator/test_operator.py`, `operator/operator.example.json`, `docs/OPERATOR.md` | Finding `0329d154` (low): with `minOut = 0` the owner's floor (~10% under market) was the only sandwich bound. Tests: `test_min_out_is_taken_from_the_simulated_fill`, `test_no_fill_revert_arms_backoff_like_the_price_limit`. The test file also drops its own directory from `sys.path` so `python3 operator/test_operator.py` works on Python 3.13 (where `operator.py` shadowed the standard-library `operator`). |
| 19 | **Deployment record refreshed**: the live hook holds pending fee ETH (`pendingEth()` = 390361348266782 wei at block 26154735, `treasury()` = 0, `totalFeeDelivered()` = 0, owner nonce 163 unchanged), so A4 is effectively permanent as soon as it is mined; the pre-A4 reads (treasury runtime, `hook()`, `owner()`) are now a required checklist step; A7 marked one-shot. | `docs/DEPLOYMENT.md`, `README.md`, `script/ConfigPlan.s.sol` (step label) | Finding `a4402408` (low): the record said `pendingEth() = 0` and presented A1/A4 as correctable. Docs only; the live hook cannot change. |
| 20 | README "Trust assumptions" extended with the two design assumptions the review recorded: who can settle when no paid request is open, and the reserve top-up's effect on the 30/30/40 split. | `README.md` | Findings `d7fc7801`, `f1556b41` (info). No code change: both are the reviewed design. |
| 21 | ABIs regenerated for the four contracts; test/size counts updated. | `docs/abi/*.json`, `README.md`, `docs/DEPLOYMENT.md` | New errors/getters (`NoFill`, `prioPurchased`, `imdPurchased`, `wasAsset`, `ArenaAlreadySet`, `RoundNotCreated`, `QuestionChanged`, `MAX_ROUND_LENGTH`). |

## Findings that did not change code

- `1e9a22a3` (info) is a documentation finding; the records it lists were re-verified (table above) and
  the documents updated. No contract change.
- `d7fc7801` and `f1556b41` (info) describe the reviewed design (relay rights without an open request;
  reserve top-ups before the 30/30/40 split). Documented as trust assumptions in README; no code change.
- `a4402408` (low) concerns the live hook and the deployment record; the record and checklist were
  corrected, the contracts are unchanged.

## What was preserved

The 0.5% hook fee (live, immutable), the allocation (10%-capped reserve, then 30% IMD / 30% PRIO / 40%
owner, PRIO split 50/50 between staking and games), the Arena scoring and commit-reveal rules, the
funded-only reward stream, player principal/escrow/refund isolation, `TwoStepOwned` ownership, and
every round-2 security fix. No owner advance, no minting, no guaranteed return was added. Paid game and
oracle operations remain disabled until the owner signs phase B of the plan, fees have funded the
reserve, prizes are funded and the operator wallet is set. Build configuration and dependencies are
untouched.

## Checks run

- `forge build` (solc 0.8.26, as configured) and `forge test`: 181 tests pass (20 suites: unit, fuzz,
  invariant, deploy rehearsal, launch adaptation). The four reviewer proofs, copied under
  `test/scratch/`, failed on the starting tree and pass on this one (4/4).
- `forge fmt` applied.
- `python3 operator/test_operator.py`: 11 tests pass.
- Protected floor test (`Contracts.protected.t.sol`) re-run locally with the four rebuilt creation codes,
  the live factory address and chain id 1: 1/1 pass.
- Slither/Mythril were not available offline and did not run.

## Open items for the owner and the launch

- Live addresses, receipts and the `launch.json` come from the manifest and deployment steps; this
  repository cannot broadcast. `docs/DEPLOYMENT.md` says exactly what to record once they exist.
- Step A4 (`TreasuryFeeHook.bindTreasury`) becomes permanent after the first fee delivery, and the hook
  already holds fee ETH that anyone can flush in the next block: run the pre-A4 reads in
  `docs/DEPLOYMENT.md` §3 and verify the FeeTreasury address against the launch record before signing.
  Step A7 (`OracleAdapter.setArena`) is one-shot: verify the Arena address the same way.
- The ETH/IMD pool proposed for `setImdPool` (fee 10000, tick spacing 200, no hook) was the only one with
  liquidity on 2026-10-09; re-check before signing step B7.
