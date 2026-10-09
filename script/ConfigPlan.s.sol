// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {FeeTreasury} from "../src/FeeTreasury.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {Arena, IRoundOracle} from "../src/Arena.sol";
import {OracleAdapter, IIntake} from "../src/OracleAdapter.sol";
import {TreasuryFeeHook} from "../src/TreasuryFeeHook.sol";

/// @title The owner's post-launch configuration, as an ordered list of (target, calldata)
/// @notice Nothing here signs or broadcasts. `plan()` is pure and returns the exact transactions the project
/// owner reviews and signs after the four application contracts are live; `test/LaunchAdaptation.t.sol`
/// executes the same list against locally deployed copies to prove the order works and the state it leaves.
/// Print it for real addresses with
///   forge script script/ConfigPlan.s.sol --sig "show(address,address,address,address,address,uint256,uint256)" \
///     <treasury> <vault> <arena> <adapter> <executor> <minPrioPerEth> <minImdPerEth>
/// Phase A (steps A1-A7) binds the contracts and is safe to sign right after launch. Phase B (B1-B13) enables
/// paid operations and is signed only when reserves, prizes and the server operator are ready.
contract ConfigPlan is Script {
    // Live records, verified on Ethereum mainnet on 2026-10-09 (see docs/DEPLOYMENT.md).
    address public constant OWNER = 0x13AFB9b5780cd9Ae79c61503Adb69c57845d8EAc;
    address public constant PRIO = 0xfd1C234972768C23bb21D655966E0B122Dd67A2C;
    address public constant HOOK = 0x65a783CC6725a02Ce349Dc4d72577994Df1760cc;
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant INTAKE = 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56;
    address public constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    bytes32 public constant ACTION = bytes32("oracle.request@oracle-1");
    uint256 public constant ORACLE_PRICE = 0.5 ether; // Intake.priceOf(ACTION, IMD) on 2026-10-09
    // The ETH/IMD Uniswap v4 pool with liquidity on 2026-10-09 (id 0xb07d640f...; no hook). Re-check before signing.
    uint24 public constant IMD_POOL_FEE = 10_000;
    int24 public constant IMD_POOL_TICK_SPACING = 200;
    address public constant IMD_POOL_HOOKS = address(0);

    struct Apps {
        address treasury;
        address vault;
        address arena;
        address adapter;
    }

    struct Params {
        address executor;
        uint256 reserveTarget;
        uint256 maxSpendPerSwap;
        uint256 spendPerWindow;
        uint256 reservePerWindow;
        uint256 minPrioPerEth;
        uint256 minImdPerEth;
        uint256 oracleBudgetPerDay;
    }

    struct Step {
        string label;
        address target;
        bytes data;
    }

    /// @notice Conservative operating defaults; the owner changes them by signing the setter again.
    function defaults(address executor, uint256 minPrioPerEth, uint256 minImdPerEth)
        public
        pure
        returns (Params memory p)
    {
        p.executor = executor;
        p.reserveTarget = 0.5 ether; // hard cap 2 ETH in the contract
        p.maxSpendPerSwap = 0.25 ether;
        p.spendPerWindow = 0.5 ether; // at most 2x this in any 24h span (fixed bucket)
        p.reservePerWindow = 0.05 ether; // executor gas draw, to itself only
        p.minPrioPerEth = minPrioPerEth;
        p.minImdPerEth = minImdPerEth;
        p.oracleBudgetPerDay = 2 ether; // 4 panel answers a day at 0.5 IMD
    }

    function plan(Apps memory a, Params memory p) public pure returns (Step[] memory steps) {
        steps = new Step[](20);
        uint256 i;
        // Phase A: bindings. FeeTreasury first (hook.bindTreasury checks treasury.hook() == hook).
        steps[i++] = Step("A1 FeeTreasury.bindHook", a.treasury, abi.encodeCall(FeeTreasury.bindHook, (HOOK)));
        steps[i++] = Step("A2 FeeTreasury.setPrio", a.treasury, abi.encodeCall(FeeTreasury.setPrio, (PRIO)));
        steps[i++] = Step(
            "A3 FeeTreasury.setSinks", a.treasury, abi.encodeCall(FeeTreasury.setSinks, (a.vault, a.arena, a.adapter))
        );
        steps[i++] = Step(
            "A4 TreasuryFeeHook.bindTreasury (permanent after the first fee)",
            HOOK,
            abi.encodeCall(TreasuryFeeHook.bindTreasury, (payable(a.treasury)))
        );
        steps[i++] = Step(
            "A5 StakingVault.setRewardFunder", a.vault, abi.encodeCall(StakingVault.setRewardFunder, (a.treasury))
        );
        steps[i++] = Step("A6 Arena.setOracle", a.arena, abi.encodeCall(Arena.setOracle, (IRoundOracle(a.adapter))));
        steps[i++] = Step("A7 OracleAdapter.setArena", a.adapter, abi.encodeCall(OracleAdapter.setArena, (a.arena)));
        // Phase B: operating limits and paid-operation configuration.
        steps[i++] = Step(
            "B1 FeeTreasury.setReserveTarget",
            a.treasury,
            abi.encodeCall(FeeTreasury.setReserveTarget, (p.reserveTarget))
        );
        steps[i++] = Step(
            "B2 FeeTreasury.setMaxSpendPerSwap",
            a.treasury,
            abi.encodeCall(FeeTreasury.setMaxSpendPerSwap, (p.maxSpendPerSwap))
        );
        steps[i++] = Step(
            "B3 FeeTreasury.setSpendPerWindow",
            a.treasury,
            abi.encodeCall(FeeTreasury.setSpendPerWindow, (p.spendPerWindow))
        );
        steps[i++] = Step(
            "B4 FeeTreasury.setReservePerWindow",
            a.treasury,
            abi.encodeCall(FeeTreasury.setReservePerWindow, (p.reservePerWindow))
        );
        steps[i++] = Step(
            "B5 FeeTreasury.setPriceFloors (0 keeps purchases refused)",
            a.treasury,
            abi.encodeCall(FeeTreasury.setPriceFloors, (p.minPrioPerEth, p.minImdPerEth))
        );
        steps[i++] = Step("B6 FeeTreasury.setImd", a.treasury, abi.encodeCall(FeeTreasury.setImd, (IMD)));
        steps[i++] = Step(
            "B7 FeeTreasury.setImdPool (verify the ETH/IMD pool first)",
            a.treasury,
            abi.encodeCall(FeeTreasury.setImdPool, (IMD_POOL_FEE, IMD_POOL_TICK_SPACING, IMD_POOL_HOOKS))
        );
        steps[i++] =
            Step("B8 OracleAdapter.setIntake", a.adapter, abi.encodeCall(OracleAdapter.setIntake, (IIntake(INTAKE))));
        steps[i++] = Step("B9 OracleAdapter.setAction", a.adapter, abi.encodeCall(OracleAdapter.setAction, (ACTION)));
        steps[i++] = Step(
            "B10 OracleAdapter.setPayment", a.adapter, abi.encodeCall(OracleAdapter.setPayment, (IMD, ORACLE_PRICE))
        );
        steps[i++] = Step(
            "B11 OracleAdapter.setCallbackConfigured",
            a.adapter,
            abi.encodeCall(OracleAdapter.setCallbackConfigured, (true))
        );
        steps[i++] = Step(
            "B12 OracleAdapter.setBudget", a.adapter, abi.encodeCall(OracleAdapter.setBudget, (p.oracleBudgetPerDay))
        );
        // Executors last: nothing is spendable by the operator wallet before every limit above is in place.
        steps[i++] = Step(
            "B13 FeeTreasury.setExecutor + OracleAdapter.setExecutor (two calls; see docs/DEPLOYMENT.md)",
            a.treasury,
            abi.encodeCall(FeeTreasury.setExecutor, (p.executor))
        );
    }

    /// @notice The second executor call of step B13, kept separate so both targets appear explicitly.
    function executorStep(Apps memory a, Params memory p) public pure returns (Step memory) {
        return
            Step("B13b OracleAdapter.setExecutor", a.adapter, abi.encodeCall(OracleAdapter.setExecutor, (p.executor)));
    }

    /// @notice Prints every transaction for the owner wallet to review. Read-only.
    function show(
        address treasury,
        address vault,
        address arena,
        address adapter,
        address executor,
        uint256 minPrioPerEth,
        uint256 minImdPerEth
    ) external pure {
        Apps memory a = Apps(treasury, vault, arena, adapter);
        Params memory p = defaults(executor, minPrioPerEth, minImdPerEth);
        Step[] memory steps = plan(a, p);
        console.log("Owner wallet (signer of every step):", OWNER);
        for (uint256 i; i < steps.length; i++) {
            console.log(steps[i].label);
            console.log("  to:  ", steps[i].target);
            console.log("  data:", vm.toString(steps[i].data));
        }
        Step memory last = executorStep(a, p);
        console.log(last.label);
        console.log("  to:  ", last.target);
        console.log("  data:", vm.toString(last.data));
    }
}
