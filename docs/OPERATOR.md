# PRISM RIOT operator

The operator is `operator/operator.py`, a Python 3.10+ script with no third-party dependencies. It
drives the two IMD paid flows the project uses and relays results to the contracts. It holds no
authority: it can only spend what the owner budgeted on chain (`OracleAdapter.setBudget`) and what
`operator.json` allows, and nothing it produces can change an active round or move player funds.

## Setup

1. Copy `operator/operator.example.json` to `operator.json` and fill `contracts.*` with the launched
   addresses (README "Deployment").
2. Export the operator wallet's key **on the server only**: `export OPERATOR_PRIVATE_KEY=0x...`.
   The key is passed to `cast send` as a subprocess argument and never written to disk or logs.
   Fund the wallet's gas from the treasury's reserve (`FeeTreasury.withdrawReserve`, owner or executor)
   after fees have accrued; there is no other gas source.
3. Set the same wallet as executor on chain: `FeeTreasury.setExecutor` and `OracleAdapter.setExecutor`.
   What that wallet can do is bounded on chain whatever happens to the key: `FeeTreasury` allows at most
   `maxSpendPerSwap` per purchase and `spendPerWindow` per 24-hour bucket (a fixed bucket, so at most
   twice that in any 24-hour span), never below the owner's price floors (`setPriceFloors`), and reserve
   draws only to the executor itself within `reservePerWindow`; `OracleAdapter` allows `budgetPerWindow`
   IMD per day. The owner should keep
   the price floors a little below the market price and re-set them when PRIO or IMD move a lot: a floor
   above the market makes purchases revert (safe), never overpay.
4. Leave `paid_operations_enabled` at `false` until the owner has done the "After launch" steps in
   the README and `OracleAdapter.paidRequestsEnabled()` returns true, and the adapter holds IMD that
   the treasury bought (`FeeTreasury.buyImd`). Then flip it to `true`.

## Commands

| Command | What it does | Paid? |
| --- | --- | --- |
| `capabilities` | GET the door's capabilities | no |
| `quote <action> <body-json>` | `check` then `quote` an action body | no |
| `request-round <roundId> [--dry-run]` | `OracleAdapter.request(roundId)`: pays 0.5 IMD from the adapter's balance via the Intake. Refused (locally and by the adapter) before the round's commit deadline, so an answer never exists while entries are open | yes |
| `poll <requestId>` | polls the request status with the configured interval and attempt cap | no |
| `relay <roundId> <attestation.json> [--dry-run]` | manual result delivery: `OracleAdapter.submitAttestation` | gas only |
| `propose "<brief>" [--dry-run]` | `job.open` for challenge text / artwork; stores the proposal under `proposals/` | yes |
| `buy-prio` / `buy-imd [--dry-run]` | `FeeTreasury.buyPrio` / `buyImd` with `purchases.eth_per_buy`, simulated first with `cast call`. A `PriceLimitAlreadyExceeded` revert (no liquidity on the buy side) arms a persistent backoff (`price_limit_backoff_seconds`, doubling up to `_max_seconds`) and nothing is sent until it expires; other reverts send nothing and arm nothing; a filled purchase resets the backoff | gas only (ETH comes from the treasury's budgets) |

Every paid command passes the daily ledger (`operator-state.json`): IMD per day, gas per day and
request count per day. A refused step prints the reason and exits 1. Retries use linear backoff and
a fixed attempt cap; polling stops on the first terminal status.

## Result delivery and claims

The Intake calls `OracleAdapter.onOracleResult` itself when the panel settles (status 0). If that
callback is missed (out of gas, status 1/2, or a relayer outage) the same signed attestation can be
submitted with `relay`: by anyone when it answers the adapter's own request (its `requestId` was
registered by `request(roundId)`), otherwise only by the executor or the owner, so a third party cannot
settle a round with an answer they bought themselves. After the
result is stored, `Arena.settle(roundId)` is permissionless, and so are `claim`, `refund` and
`cancel`. Players can always claim themselves; the operator may call these for convenience.

## What agent output is

`propose` returns text and image references. They are **proposals** for the owner to read and, if
accepted, to turn into a *future* round: first `OracleAdapter.pinQuestion(roundCount + 1, ...)` with
`notBefore` equal to the round's commit deadline, then `Arena.createRound(...)`, which refuses a round
whose question is not pinned at that boundary. An active round's rules, deadlines, prize, scoring,
oracle and question are frozen at creation and no contract call can change them.
