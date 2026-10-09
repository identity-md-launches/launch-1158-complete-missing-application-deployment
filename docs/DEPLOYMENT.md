# Deployment and configuration checklist: PRISM RIOT application contracts

Ethereum mainnet (chain id 1), launch kind `evm_contracts`. This document is the hand-off for the manifest
step, the deployer and the project owner. Nothing in this repository signs or broadcasts; "prepared"
below never means "executed".

## 1. What is live already (verified 2026-10-09, block 26154434)

| Item | Address / value | How verified |
| --- | --- | --- |
| Original deployment tx | `0x545df1adb27c4a2ad6de57dd3d4d28005306f1471c0002381d5518fbc1c6dd7d` | `cast receipt`: status 1, block 26154170, from `0xcecc29b0…a551`, to factory `0x12C63b581d07093F6126bc02263c58f7EadaA96F`, 12 logs from PoolManager, factory, hook, PRIO, distributor |
| PRIO (`PrismRiotToken`) | `0xfd1c234972768c23bb21d655966e0b122dd67a2c` | `symbol()` = `PRIO`, `totalSupply()` = 1e27, code 1739 bytes = `out/PrismRiotToken` runtime |
| TreasuryFeeHook | `0x65a783cc6725a02ce349dc4d72577994df1760cc` | `owner()` = `0x13AFB9b5…8EAc`, `pendingOwner()` = 0, `token()` = PRIO, `poolManager()` = `0x0000…8a90`, `factory()` = `0x12C63b58…A96F`, `initialized()` = true, `FEE_BPS()` = 50, `treasury()` = **0**, `pendingEth()` = 0 |
| MerkleDistributor (launch 1153) | `0xd5873749535e5e558e3c2181ff8e9f43e4fc2927` | launch record; not touched |
| ETH/PRIO pool | `PoolKey(ETH, PRIO, 12500, 60, hook)`, id `0xe5394ebb…d971` | `StateView.getSlot0`: sqrtPriceX96 = 10000·2^96 (1e8 PRIO per ETH), lpFee 12500; PRIO-only liquidity below spot (buys fill, in-range liquidity at spot is 0) |
| PoolManager | `0x000000000004444c5dc75cb358380d2e3de08a90` | code 48021 bytes |
| Project owner | `0x13afb9b5780cd9ae79c61503adb69c57845d8eac` | owns the hook; nonce 163; last tx block 26154147 (`execute` on a router), no contract created since |
| Existing application deployments | **none** | owner's outgoing tx list (Blockscout) and launch list (`api.imd.fun/launches`): launch 1153 has exactly 3 artifacts; no `evm_contracts` launch for this project |
| IMD token | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` | `symbol()` = `IMD`, 18 decimals |
| Intake | `0x1397434cd35e8a9c8ac312a61d3a285eb31dea56` | code 13139 bytes; `priceOf(bytes32("oracle.request@oracle-1"), IMD)` = `500000000000000000` (0.5 IMD) |
| Oracle signer | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` | `api.imd.fun/oracle/requests`: top-level `attester` and `signer` of every attested request (100 listed) |
| StateView (read-only helper) | `0x7ffe42c4a5deea5b0fec41c94c136cf115597227` | used for pool reads only |

The hook's `treasury()` is zero: no companion address exists yet and none was invented.

## 2. The launch: four contracts, static constructor arguments

The manifest step writes `launch.json` (`kind` `evm_contracts`, `contracts`, `notes`) from this table.
The brief states the owner, so it is a static address, not `$owner`. No `$contract:` reference is needed:
every argument is a live address.

| Order | `contract` | `constructorArgs` |
| --- | --- | --- |
| 1 | `FeeTreasury` | `["0x000000000004444c5dc75cb358380d2e3de08a90", "0x13afb9b5780cd9ae79c61503adb69c57845d8eac"]` |
| 2 | `StakingVault` | `["0x13afb9b5780cd9ae79c61503adb69c57845d8eac", "0xfd1c234972768c23bb21d655966e0b122dd67a2c"]` |
| 3 | `Arena` | `["0x13afb9b5780cd9ae79c61503adb69c57845d8eac", "0xfd1c234972768c23bb21d655966e0b122dd67a2c"]` |
| 4 | `OracleAdapter` | `["0x13afb9b5780cd9ae79c61503adb69c57845d8eac", "0x5598aa9146215bc13eb26f2c692ad1461fd32982"]` |

Rehearsed: `test/LaunchAdaptation.t.sol` (creation code + arguments on an empty chain, EIP-170 and opcode
scan, deploy script parity) and the protected floor test with the built creation codes (1/1). Runtime
sizes: FeeTreasury 10521, StakingVault 3788, Arena 8922, OracleAdapter 11321 bytes. Init code sizes 11040 /
4267 / 9380 / 12675 bytes. No constructor calls another contract.

After the launch, record here: the four addresses, the launch transaction hash and block, and the
`launch.json` as accepted. ABIs: `docs/abi/{FeeTreasury,StakingVault,Arena,OracleAdapter}.json`.

## 3. Owner transactions, in order

Signer for every step: the project owner `0x13afb9b5780cd9ae79c61503adb69c57845d8eac`. Print the full list
with the live addresses filled in (read-only, no key):

```bash
forge script script/ConfigPlan.s.sol \
  --sig "show(address,address,address,address,address,uint256,uint256)" \
  <FeeTreasury> <StakingVault> <Arena> <OracleAdapter> <operatorWallet> <minPrioPerEth> <minImdPerEth>
```

`test/LaunchAdaptation.t.sol::test_configurationPlanRunsInOrderAndLeavesTheDocumentedState` executes the
same list against local copies of the hook and PRIO at their mainnet addresses and checks the resulting
state and that every call is owner-only. Before signing, simulate each against mainnet with
`cast call --from 0x13afb9b5780cd9ae79c61503adb69c57845d8eac <to> <data>`.

### Phase A: bindings (sign right after launch)

| Step | Target | Function | Calldata | Permanence |
| --- | --- | --- | --- | --- |
| A1 | FeeTreasury | `bindHook(0x65a783cc…60cc)` | `0x10202c5400000000000000000000000065a783cc6725a02ce349dc4d72577994df1760cc` | correctable until the first fee arrives |
| A2 | FeeTreasury | `setPrio(0xfd1c2349…7a2c)` | `0x567a8315000000000000000000000000fd1c234972768c23bb21d655966e0b122dd67a2c` | correctable until the first purchase |
| A3 | FeeTreasury | `setSinks(StakingVault, Arena, OracleAdapter)` | `cast calldata "setSinks(address,address,address)" <vault> <arena> <adapter>` | refused unless vault and arena report PRIO; correctable until the first purchase |
| A4 | **TreasuryFeeHook `0x65a783cc…60cc`** | `bindTreasury(FeeTreasury)` | `cast calldata "bindTreasury(address)" <treasury>` | **permanent after the first fee delivery.** The hook refuses a treasury bound to another hook; do A1 first so the treasury accepts fee ETH immediately |
| A5 | StakingVault | `setRewardFunder(FeeTreasury)` | `cast calldata "setRewardFunder(address)" <treasury>` | re-settable |
| A6 | Arena | `setOracle(OracleAdapter)` | `cast calldata "setOracle(address)" <adapter>` | applies to rounds created afterwards |
| A7 | OracleAdapter | `setArena(Arena)` | `cast calldata "setArena(address)" <arena>` | re-settable; enables correcting a pin the Arena has not consumed |

Verify A3 and A4 destinations against the launch record character by character: A4 cannot be undone once a
fee has been delivered, and A2/A3 cannot be undone once a purchase has happened.

### Phase B: operating limits and paid operations (sign when reserves, prizes and the operator are ready)

| Step | Target | Function | Calldata (defaults) |
| --- | --- | --- | --- |
| B1 | FeeTreasury | `setReserveTarget(0.5 ETH)` (cap 2 ETH) | `0xaa4b3e4b00000000000000000000000000000000000000000000000006f05b59d3b20000` |
| B2 | FeeTreasury | `setMaxSpendPerSwap(0.25 ETH)` | `0x732a391900000000000000000000000000000000000000000000000003782dace9d90000` |
| B3 | FeeTreasury | `setSpendPerWindow(0.5 ETH)` per 24h bucket (at most 2× in any 24h span) | `0xd752bd4c00000000000000000000000000000000000000000000000006f05b59d3b20000` |
| B4 | FeeTreasury | `setReservePerWindow(0.05 ETH)` executor gas draw, to itself only | `0x4aef771900000000000000000000000000000000000000000000000000b1a2bc2ec50000` |
| B5 | FeeTreasury | `setPriceFloors(minPrioPerEth, minImdPerEth)` | `cast calldata "setPriceFloors(uint256,uint256)" <prio> <imd>`; 0 keeps purchases refused. Set ~10% below the market just before enabling; re-set when prices move |
| B6 | FeeTreasury | `setImd(0xd34a99bc…63b7)` | `0xe3144873000000000000000000000000d34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| B7 | FeeTreasury | `setImdPool(10000, 200, 0x0)` | `0x20e38e74000000000000000000000000000000000000000000000000000000000000271000000000000000000000000000000000000000000000000000000000000000c80000000000000000000000000000000000000000000000000000000000000000` (see §4; re-check first) |
| B8 | OracleAdapter | `setIntake(0x1397434c…ea56)` | `0xca86ad480000000000000000000000001397434cd35e8a9c8ac312a61d3a285eb31dea56` |
| B9 | OracleAdapter | `setAction(bytes32("oracle.request@oracle-1"))` | `0x9b9a65146f7261636c652e72657175657374406f7261636c652d31000000000000000000` |
| B10 | OracleAdapter | `setPayment(IMD, 0.5 IMD)` | `0x841e48e7000000000000000000000000d34a99bc0f67ae1bbd63c660e6d0b0dd03e263b700000000000000000000000000000000000000000000000006f05b59d3b20000` |
| B11 | OracleAdapter | `setCallbackConfigured(true)` | `0x0697108e0000000000000000000000000000000000000000000000000000000000000001` |
| B12 | OracleAdapter | `setBudget(2 IMD per day)` (4 answers) | `0xbc8523fc0000000000000000000000000000000000000000000000001bc16d674ec80000` |
| B13 | FeeTreasury, then OracleAdapter | `setExecutor(operatorWallet)` on both | `cast calldata "setExecutor(address)" <operator>` (last: nothing is spendable by the operator before every limit above is in place) |

Per round, later: `OracleAdapter.pinQuestion(Arena.roundCount() + 1, questionHash, chainId, minPanel,
minQuorum, commitDeadline, body)` then `Arena.createRound(...)` with the same `commitDeadline` (README).

## 4. IMD pool and Intake configuration (as found on 2026-10-09)

Uniswap v4 pools where IMD is `currency1` (PoolManager `Initialize` logs via Blockscout, liquidity via
StateView at block 26154434):

| currency0 | fee | tickSpacing | hooks | in-range liquidity | note |
| --- | --- | --- | --- | --- | --- |
| ETH | 10000 (1%) | 200 | none | 1.058e22 | **proposed for B7**; tick 55887 |
| ETH | 690000 / 500000 / 9999 / 10001 / 9998 / 300000 | various | none | 0 | empty |
| USDC | 900000 / 10000 / 9999 | various | none | not usable: `buyImd` needs ETH as currency0 | |

`FeeTreasury.buyImd` swaps ETH→IMD on the configured key with a full-range price limit and the owner's
`minImdPerEth` floor; when the pool's liquidity on the sell side is exhausted the PoolManager reverts
`PriceLimitAlreadyExceeded` (`0x7c9c6e8f`). The operator simulates every purchase first and backs off
(1h, doubling to 24h) instead of re-sending (`operator/operator.py`, `buy-prio` / `buy-imd`).

Intake: `0x1397434cd35e8a9c8ac312a61d3a285eb31dea56`, action `oracle.request@oracle-1`, price 0.5 IMD,
callback `onOracleResult(bytes32,(…),bytes)` under the 200 000 gas stipend (tested). The adapter spends
only IMD it holds; the treasury's `buyImd` is the only intended source. The owner wallet itself holds
0.5 IMD, which is not used by the contracts.

## 5. Operator budgets (defaults in `operator/operator.example.json`)

| Budget | Where enforced | Default |
| --- | --- | --- |
| IMD per day | `OracleAdapter.setBudget` (on chain) and `budget.imd_per_day` (operator) | 2 IMD on chain, 1 IMD operator |
| Purchases | `maxSpendPerSwap` 0.25 ETH, `spendPerWindow` 0.5 ETH per bucket (≤ 1 ETH in any 24h), price floors | contract |
| Executor gas | `reservePerWindow` 0.05 ETH per bucket, to the executor only; operator `gas_eth_per_day` 0.02 ETH | contract + operator |
| Requests per day | `budget.requests_per_day` | 4 |
| Purchase size | `purchases.eth_per_buy` | 0.1 ETH |
| Price-limit backoff | `purchases.price_limit_backoff_seconds` / `_max_seconds` | 3600 / 86400 |
| Master switch | `paid_operations_enabled` | `false` until phase B is signed, fees have funded the reserve, prizes are funded and the operator wallet is set |

## 6. Checklist

- [ ] Manifest step: `launch.json` with exactly the four entries of §2; nothing else.
- [ ] Deployment: one contracts-only launch transaction; record addresses, tx hash, block here and in README.
- [ ] Owner: `cast call --from <owner>` each phase-A step, then sign A1 → A7 in order.
- [ ] Owner: confirm `TreasuryFeeHook.treasury()` returns the new FeeTreasury and `FeeTreasury.hook()` the hook.
- [ ] Wait for fee income (`FeeTreasury.totalIncome()`), call `allocate()` (anyone).
- [ ] Owner: set price floors from the current pool prices; sign phase B; fund prizes
      (`FeeTreasury.buyPrio` by the executor, or `Arena.fundPrizes` directly).
- [ ] Operator: fill `operator.json`, keep `paid_operations_enabled=false` until `OracleAdapter.paidRequestsEnabled()`
      is true **and** the adapter holds IMD; then enable.
- [ ] First round: `pinQuestion(roundCount + 1, …, commitDeadline, body)` then `createRound` with the same deadline.
