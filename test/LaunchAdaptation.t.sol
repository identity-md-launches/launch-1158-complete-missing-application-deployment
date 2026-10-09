// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FeeTreasury} from "../src/FeeTreasury.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {Arena} from "../src/Arena.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {PrismRiotToken} from "../src/PrismRiotToken.sol";
import {TreasuryFeeHook} from "../src/TreasuryFeeHook.sol";
import {ConfigPlan} from "../script/ConfigPlan.s.sol";
import {DeployScript} from "../script/Deploy.s.sol";

/// @dev The contracts-only launch: the four application contracts are deployed from their creation code with
/// the static constructor arguments the manifest will carry, on a chain where nothing else exists (as the
/// protected floor does), then the owner's configuration plan is executed in order against local copies of
/// the live hook and token to prove the sequence and the state it leaves.
contract LaunchAdaptationTest is Test {
    ConfigPlan planner;
    FeeTreasury treasury;
    StakingVault vault;
    Arena arena;
    OracleAdapter adapter;
    address executor = makeAddr("operator");

    function setUp() public {
        vm.chainId(1);
        planner = new ConfigPlan();
    }

    /// @dev Exactly what the factory does: creation code + abi-encoded static arguments, no other contract present.
    function deployApplications() internal {
        treasury = FeeTreasury(
            payable(create(type(FeeTreasury).creationCode, abi.encode(planner.POOL_MANAGER(), planner.OWNER())))
        );
        vault = StakingVault(create(type(StakingVault).creationCode, abi.encode(planner.OWNER(), planner.PRIO())));
        arena = Arena(create(type(Arena).creationCode, abi.encode(planner.OWNER(), planner.PRIO())));
        adapter = OracleAdapter(
            create(type(OracleAdapter).creationCode, abi.encode(planner.OWNER(), planner.ORACLE_SIGNER()))
        );
    }

    function create(bytes memory creation, bytes memory args) internal returns (address at) {
        bytes memory code = bytes.concat(creation, args);
        assembly ("memory-safe") {
            at := create(0, add(code, 32), mload(code))
        }
        require(at != address(0) && at.code.length > 0, "constructor failed");
    }

    function test_constructorsRunOnAnEmptyChainWithStaticArguments() public {
        assertEq(planner.POOL_MANAGER().code.length, 0, "the launch check chain holds no PoolManager");
        assertEq(planner.PRIO().code.length, 0, "nor the token");
        deployApplications();
        assertEq(treasury.owner(), planner.OWNER());
        assertEq(address(treasury.poolManager()), planner.POOL_MANAGER());
        assertEq(vault.owner(), planner.OWNER());
        assertEq(address(vault.prio()), planner.PRIO());
        assertEq(arena.owner(), planner.OWNER());
        assertEq(address(arena.prio()), planner.PRIO());
        assertEq(adapter.owner(), planner.OWNER());
        assertEq(adapter.oracleSigner(), planner.ORACLE_SIGNER());
        // Nothing is operable before the owner configures it.
        assertEq(treasury.hook(), address(0));
        assertEq(address(arena.oracle()), address(0));
        assertFalse(adapter.paidRequestsEnabled());
    }

    function test_runtimesAreBoundedAndFreeOfEscapeOpcodes() public {
        deployApplications();
        address[4] memory apps = [address(treasury), address(vault), address(arena), address(adapter)];
        for (uint256 i; i < apps.length; ++i) {
            bytes memory code = apps[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24_576, "runtime exceeds EIP-170");
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            }
        }
    }

    function test_deployScriptMatchesTheManifestArguments() public {
        DeployScript s = new DeployScript();
        DeployScript.Applications memory d = s.deployApplications(
            DeployScript.AppConfig(
                IPoolManager(planner.POOL_MANAGER()), planner.OWNER(), planner.PRIO(), planner.ORACLE_SIGNER()
            )
        );
        assertEq(d.treasury.owner(), planner.OWNER());
        assertEq(address(d.vault.prio()), planner.PRIO());
        assertEq(address(d.arena.prio()), planner.PRIO());
        assertEq(d.adapter.oracleSigner(), planner.ORACLE_SIGNER());
    }

    /// @dev Local stand-ins for the live hook and token at their mainnet addresses, then the whole plan.
    function test_configurationPlanRunsInOrderAndLeavesTheDocumentedState() public {
        deployApplications();
        vm.etch(planner.PRIO(), address(new PrismRiotToken()).code);
        bytes memory hookCreation = abi.encodePacked(
            type(TreasuryFeeHook).creationCode,
            abi.encode(IPoolManager(planner.POOL_MANAGER()), planner.PRIO(), makeAddr("factory"), planner.OWNER())
        );
        vm.etch(planner.HOOK(), hookCreation);
        (bool ok, bytes memory runtime) = planner.HOOK().call("");
        require(ok, "hook constructor reverted: flags mismatch");
        vm.etch(planner.HOOK(), runtime);
        TreasuryFeeHook hook = TreasuryFeeHook(payable(planner.HOOK()));
        assertEq(hook.treasury(), address(0), "unbound, as on mainnet");

        ConfigPlan.Apps memory apps =
            ConfigPlan.Apps(address(treasury), address(vault), address(arena), address(adapter));
        ConfigPlan.Params memory p = planner.defaults(executor, 9e7 ether, 1e3 ether);
        ConfigPlan.Step[] memory steps = planner.plan(apps, p);
        // The order matters: before A1 the treasury refuses the hook's ETH, so a fee delivered to a bound but
        // unconfigured treasury would wait in the hook's pendingEth. A1-A3 first, then A4.
        vm.deal(planner.HOOK(), 1 ether);
        vm.prank(planner.HOOK());
        (bool early,) = address(treasury).call{value: 1}("");
        assertFalse(early, "unbound treasury refuses fee ETH");
        for (uint256 i; i < steps.length; i++) {
            vm.prank(planner.OWNER());
            (bool stepOk, bytes memory ret) = steps[i].target.call(steps[i].data);
            assertTrue(stepOk, string.concat("step failed: ", steps[i].label, " ", vm.toString(ret)));
        }
        ConfigPlan.Step memory last = planner.executorStep(apps, p);
        vm.prank(planner.OWNER());
        (ok,) = last.target.call(last.data);
        assertTrue(ok);

        assertEq(treasury.hook(), planner.HOOK());
        assertEq(address(treasury.prio()), planner.PRIO());
        assertEq(treasury.stakingVault(), address(vault));
        assertEq(treasury.arena(), address(arena));
        assertEq(treasury.oracleAdapter(), address(adapter));
        assertEq(hook.treasury(), address(treasury));
        assertEq(vault.rewardFunder(), address(treasury));
        assertEq(address(arena.oracle()), address(adapter));
        assertEq(adapter.arena(), address(arena));
        assertEq(treasury.executor(), executor);
        assertEq(adapter.executor(), executor);
        assertEq(treasury.reserveTarget(), 0.5 ether);
        assertEq(treasury.maxSpendPerSwap(), 0.25 ether);
        assertEq(treasury.spendPerWindow(), 0.5 ether);
        assertEq(treasury.reservePerWindow(), 0.05 ether);
        assertEq(treasury.minPrioPerEth(), 9e7 ether);
        assertEq(address(treasury.imd()), planner.IMD());
        assertTrue(treasury.imdPoolSet());
        assertEq(address(adapter.intake()), planner.INTAKE());
        assertEq(adapter.action(), planner.ACTION());
        assertEq(adapter.asset(), planner.IMD());
        assertEq(adapter.price(), 0.5 ether);
        assertTrue(adapter.paidRequestsEnabled(), "configured, but still unfunded");
        // Every step is owner-only: the same calldata from anyone else is refused.
        for (uint256 i; i < steps.length; i++) {
            vm.prank(makeAddr("stranger"));
            (bool strangerOk,) = steps[i].target.call(steps[i].data);
            assertFalse(strangerOk, steps[i].label);
        }
        // Still nothing paid can happen: no fee income has arrived and the adapter holds no IMD.
        assertEq(treasury.totalIncome(), 0);
        assertEq(treasury.prioBudget(), 0);
        vm.prank(executor);
        vm.expectRevert(FeeTreasury.ExceedsBudget.selector);
        treasury.buyPrio(1, 0);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.QuestionNotPinned.selector, 1));
        adapter.request(1);
    }
}
