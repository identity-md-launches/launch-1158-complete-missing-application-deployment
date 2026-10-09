// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Replica} from "./utils/Replica.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FeeTreasury} from "../src/FeeTreasury.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {Arena, IRoundOracle} from "../src/Arena.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {TreasuryFeeHook} from "../src/TreasuryFeeHook.sol";
import {ConfigPlan} from "../script/ConfigPlan.s.sol";

interface ConsumerErrors {
    error ZeroSigner();
}

/// @dev The contracts-only launch rehearsed against local copies of the live records at their mainnet
/// addresses: the manifest's constructor arguments, the ordered owner plan (and what goes wrong out of
/// order), the exact calldata the deployment document hands the owner, and the whole fee-funded economy
/// end to end once the plan has run: fees, allocation, purchases, staking rewards, a game round settled
/// through a paid oracle answer, and the executor's bounds.
contract LaunchRehearsalTest is Replica {
    bytes32 constant QUESTION = keccak256("which vault did the panel find");

    function setUp() public {
        setUpReplica();
    }

    // ------------------------------------------------------------------ the manifest

    /// @dev The factory is msg.sender of every constructor; ownership must still land on the stated owner.
    function test_manifestDeploysFromTheFactoryWithTheStatedOwner_notTheDeployer() public {
        deployApplications();
        assertEq(treasury.owner(), OWNER);
        assertEq(vault.owner(), OWNER);
        assertEq(arena.owner(), OWNER);
        assertEq(adapter.owner(), OWNER);
        assertTrue(OWNER != FACTORY, "ownership never traps at the factory");
        assertEq(address(treasury.poolManager()), POOL_MANAGER);
        assertEq(address(vault.prio()), PRIO);
        assertEq(address(arena.prio()), PRIO);
        assertEq(adapter.oracleSigner(), ORACLE_SIGNER);
        assertEq(hook.token(), PRIO, "the live hook serves the same PRIO the vault and arena take");
        assertEq(hook.owner(), OWNER, "the live hook is owned by the same wallet");
        assertEq(hook.treasury(), address(0), "treasury() was zero at the last check");
        assertEq(treasury.pendingOwner(), address(0));
        assertEq(adapter.arena(), address(0));
        assertEq(vault.rewardFunder(), address(0));
    }

    function test_constructorsRefuseZeroArguments() public {
        vm.expectRevert(FeeTreasury.ZeroAddress.selector);
        new FeeTreasury(IPoolManager(address(0)), OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new FeeTreasury(IPoolManager(POOL_MANAGER), address(0));
        vm.expectRevert(StakingVault.ZeroAddress.selector);
        new StakingVault(OWNER, address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new StakingVault(address(0), PRIO);
        vm.expectRevert(Arena.ZeroAddress.selector);
        new Arena(OWNER, address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Arena(address(0), PRIO);
        vm.expectRevert(ConsumerErrors.ZeroSigner.selector);
        new OracleAdapter(OWNER, address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new OracleAdapter(address(0), ORACLE_SIGNER);
    }

    /// @dev Swapping two address arguments in the manifest does not fail deployment (every argument is a
    /// plain address), so the plan must be what catches it, before any binding is permanent.
    function test_swappedManifestArgumentsAreCaughtByPhaseA() public {
        // StakingVault with (prio, owner) instead of (owner, prio): owned by the token, staking the owner.
        StakingVault swapped =
            StakingVault(createFrom(FACTORY, type(StakingVault).creationCode, abi.encode(PRIO, OWNER)));
        assertEq(swapped.owner(), PRIO);
        assertEq(address(swapped.prio()), OWNER);
        deployApplications();
        ConfigPlan.Step[] memory steps = planner.plan(
            ConfigPlan.Apps(address(treasury), address(swapped), address(arena), address(adapter)), params()
        );
        execStep(steps[0]); // A1
        execStep(steps[1]); // A2
        vm.prank(OWNER);
        (bool ok, bytes memory ret) = steps[2].target.call(steps[2].data); // A3
        assertFalse(ok, "A3 refuses the swapped vault");
        assertEq(bytes4(ret), FeeTreasury.SinkMismatch.selector);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        swapped.setRewardFunder(address(treasury)); // A5 is refused too: the owner is not its owner
        // FeeTreasury with (owner, poolManager): owned by the PoolManager. The very first step is refused.
        FeeTreasury swappedTreasury =
            FeeTreasury(payable(createFrom(FACTORY, type(FeeTreasury).creationCode, abi.encode(OWNER, POOL_MANAGER))));
        assertEq(swappedTreasury.owner(), POOL_MANAGER);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        swappedTreasury.bindHook(HOOK);
        // OracleAdapter with (signer, owner): the owner wallet is the signer and the signer is the owner.
        OracleAdapter swappedAdapter =
            OracleAdapter(createFrom(FACTORY, type(OracleAdapter).creationCode, abi.encode(ORACLE_SIGNER, OWNER)));
        assertEq(swappedAdapter.owner(), ORACLE_SIGNER);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        swappedAdapter.setArena(address(arena));
    }

    // ------------------------------------------------------------------ the plan as documented

    /// @dev The calldata printed in docs/DEPLOYMENT.md section 3 is what the plan encodes, step for step, and
    /// every step targets one of the four launched contracts or the live hook (A4 only).
    function test_planCalldataAndTargetsMatchTheDeploymentDocument() public {
        deployApplications();
        ConfigPlan.Step[] memory steps = planner.plan(apps(), params());
        assertEq(steps.length, 20);
        assertEq(steps[0].data, hex"10202c5400000000000000000000000065a783cc6725a02ce349dc4d72577994df1760cc", "A1");
        assertEq(steps[1].data, hex"567a8315000000000000000000000000fd1c234972768c23bb21d655966e0b122dd67a2c", "A2");
        assertEq(
            steps[2].data,
            abi.encodeCall(FeeTreasury.setSinks, (address(vault), address(arena), address(adapter))),
            "A3"
        );
        assertEq(steps[3].data, abi.encodeCall(TreasuryFeeHook.bindTreasury, (payable(address(treasury)))), "A4");
        assertEq(steps[3].target, HOOK, "A4 is the only step signed against the live hook");
        assertEq(steps[4].data, abi.encodeCall(StakingVault.setRewardFunder, (address(treasury))), "A5");
        assertEq(steps[5].data, abi.encodeCall(Arena.setOracle, (IRoundOracle(address(adapter)))), "A6");
        assertEq(steps[6].data, abi.encodeCall(OracleAdapter.setArena, (address(arena))), "A7");
        assertEq(
            steps[7].data, hex"aa4b3e4b00000000000000000000000000000000000000000000000006f05b59d3b20000", "B1 0.5 ETH"
        );
        assertEq(
            steps[8].data, hex"732a391900000000000000000000000000000000000000000000000003782dace9d90000", "B2 0.25 ETH"
        );
        assertEq(
            steps[9].data, hex"d752bd4c00000000000000000000000000000000000000000000000006f05b59d3b20000", "B3 0.5 ETH"
        );
        assertEq(
            steps[10].data, hex"4aef771900000000000000000000000000000000000000000000000000b1a2bc2ec50000", "B4 0.05 ETH"
        );
        assertEq(steps[11].data, abi.encodeCall(FeeTreasury.setPriceFloors, (MIN_PRIO_PER_ETH, MIN_IMD_PER_ETH)), "B5");
        assertEq(steps[12].data, hex"e3144873000000000000000000000000d34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "B6");
        assertEq(
            steps[13].data,
            hex"20e38e74000000000000000000000000000000000000000000000000000000000000271000000000000000000000000000000000000000000000000000000000000000c80000000000000000000000000000000000000000000000000000000000000000",
            "B7 fee 10000, spacing 200, no hook"
        );
        assertEq(steps[14].data, hex"ca86ad480000000000000000000000001397434cd35e8a9c8ac312a61d3a285eb31dea56", "B8");
        assertEq(steps[15].data, hex"9b9a65146f7261636c652e72657175657374406f7261636c652d31000000000000000000", "B9");
        assertEq(
            steps[16].data,
            hex"841e48e7000000000000000000000000d34a99bc0f67ae1bbd63c660e6d0b0dd03e263b700000000000000000000000000000000000000000000000006f05b59d3b20000",
            "B10 IMD, 0.5 IMD"
        );
        assertEq(steps[17].data, hex"0697108e0000000000000000000000000000000000000000000000000000000000000001", "B11");
        assertEq(
            steps[18].data, hex"bc8523fc0000000000000000000000000000000000000000000000001bc16d674ec80000", "B12 2 IMD"
        );
        assertEq(steps[19].data, abi.encodeCall(FeeTreasury.setExecutor, (executor)), "B13");
        assertEq(
            planner.executorStep(apps(), params()).data, abi.encodeCall(OracleAdapter.setExecutor, (executor)), "B13b"
        );
        for (uint256 i; i < steps.length; i++) {
            address t = steps[i].target;
            bool known = t == address(treasury) || t == address(vault) || t == address(arena) || t == address(adapter)
                || (i == 3 && t == HOOK);
            assertTrue(known, string.concat("unexpected target in ", steps[i].label));
            assertTrue(t != PRIO && t != POOL_MANAGER && t != IMD && t != INTAKE, "no step touches a live asset");
        }
    }

    /// @dev A4 signed before A1 is accepted by the hook (the treasury reports no hook yet), but the treasury
    /// then refuses fee ETH: the fee waits in the hook, nothing is lost, and A1 unblocks delivery. A3 before A2
    /// is refused outright.
    function test_phaseAOutOfOrder_feesWaitInTheHookAndNothingIsLost() public {
        deployApplications();
        seedPrioOnly(8.7e22);
        ConfigPlan.Step[] memory steps = planner.plan(apps(), params());
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(FeeTreasury.NotConfigured.selector, "prio"));
        treasury.setSinks(address(vault), address(arena), address(adapter));
        execStep(steps[3]); // A4 first
        assertEq(hook.treasury(), address(treasury));
        vm.deal(trader, 1 ether);
        swapPrio(trader, true, -0.2 ether, 0.2 ether);
        uint256 charged = hook.totalFeeCharged();
        assertGt(charged, 0);
        assertEq(hook.pendingClaims(), charged, "a PRIO-only pool: the first fee is a claim");
        hook.redeemClaims(charged);
        assertEq(hook.pendingEth(), charged, "redeemed, but the unbound treasury refused it");
        assertEq(hook.totalFeeDelivered(), 0);
        assertEq(treasury.totalIncome(), 0);
        hook.flush();
        assertEq(hook.pendingEth(), charged, "flush retried and failed again, fee kept");
        execStep(steps[0]); // A1 is still correctable: no income has arrived
        hook.flush();
        assertEq(hook.pendingEth(), 0);
        assertEq(treasury.totalIncome(), charged, "the whole fee arrived once A1 was signed");
        assertEq(hook.totalFeeDelivered(), charged);
        vm.prank(OWNER);
        vm.expectRevert(TreasuryFeeHook.TreasuryAlreadyBound.selector);
        hook.bindTreasury(payable(address(0xBEEF)));
    }

    function test_A4RefusesATreasuryBoundElsewhere_andIsCorrectableUntilDelivery() public {
        deployApplications();
        vm.startPrank(OWNER);
        treasury.bindHook(address(0xBEEF));
        vm.expectRevert(TreasuryFeeHook.TreasuryMismatch.selector);
        hook.bindTreasury(payable(address(treasury)));
        FeeTreasury decoy = new FeeTreasury(IPoolManager(POOL_MANAGER), OWNER);
        hook.bindTreasury(payable(address(decoy))); // a mistake: unbound decoy accepted
        treasury.bindHook(HOOK);
        hook.bindTreasury(payable(address(treasury))); // corrected before any delivery
        vm.expectRevert(TreasuryFeeHook.ZeroAddress.selector);
        hook.bindTreasury(payable(address(0)));
        vm.stopPrank();
        assertEq(hook.treasury(), address(treasury));
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, executor));
        hook.bindTreasury(payable(address(decoy)));
    }

    /// @dev Signing phase A twice before any money moved changes nothing; after income and a purchase the
    /// permanent bindings refuse to move, and the re-settable ones still accept the same value.
    function test_planIsIdempotentBeforeMoneyMovesAndFrozenAfter() public {
        deployApplications();
        seedPrioOnly(8.7e22);
        seedImdPool(8e20, 50 ether);
        runPlan();
        runPlan();
        assertEq(treasury.hook(), HOOK);
        assertEq(hook.treasury(), address(treasury));
        earnFees(0.5 ether);
        assertGt(treasury.totalIncome(), 0);
        treasury.allocate();
        vm.prank(OWNER);
        treasury.setPriceFloors(1e7 ether, 50 ether); // B5 re-signed from the market after the trade above
        uint256 half = treasury.prioBudget() / 2;
        vm.prank(executor);
        treasury.buyPrio(half, 1);
        assertTrue(treasury.purchased());
        ConfigPlan.Step[] memory steps = planner.plan(apps(), params());
        bytes4[20] memory expected;
        expected[0] = FeeTreasury.HookAlreadyBound.selector;
        expected[1] = FeeTreasury.AlreadySet.selector;
        expected[2] = FeeTreasury.AlreadySet.selector;
        expected[3] = TreasuryFeeHook.TreasuryAlreadyBound.selector;
        for (uint256 i; i < steps.length; i++) {
            vm.prank(OWNER);
            (bool ok, bytes memory ret) = steps[i].target.call(steps[i].data);
            if (i < 4) {
                assertFalse(ok, string.concat("permanent: ", steps[i].label));
                assertEq(bytes4(ret), expected[i], steps[i].label);
            } else {
                assertTrue(ok, string.concat("re-settable: ", steps[i].label));
            }
        }
    }

    // ------------------------------------------------------------------ nothing paid before funding

    function test_paidOperationsStayOffAfterThePlanUntilFeesFundThem() public {
        deployApplications();
        runPlan();
        assertTrue(adapter.paidRequestsEnabled(), "configured");
        assertEq(imd.balanceOf(address(adapter)), 0, "but unfunded");
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.QuestionNotPinned.selector, 1));
        adapter.request(1);
        vm.prank(OWNER);
        adapter.pinQuestion(1, QUESTION, 1, 5, 4, uint64(block.timestamp), "");
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(adapter), 0, 0.5 ether)
        );
        adapter.request(1);
        assertEq(adapter.spentInWindow(), 0);
        vm.startPrank(executor);
        vm.expectRevert(FeeTreasury.ExceedsBudget.selector);
        treasury.buyPrio(1, 0);
        vm.expectRevert(FeeTreasury.ExceedsBudget.selector);
        treasury.buyImd(1, 0);
        vm.expectRevert(FeeTreasury.ExceedsBudget.selector);
        treasury.withdrawReserve(payable(executor), 1);
        vm.stopPrank();
        vm.prank(OWNER);
        vm.expectRevert(FeeTreasury.ExceedsBudget.selector);
        treasury.withdrawOwner(payable(OWNER), 1);
        // No prize can be promised that the game pool does not hold, and no reward stream without PRIO.
        vm.prank(OWNER);
        vm.expectRevert(Arena.PrizeNotFunded.selector);
        arena.createRound(
            Arena.Mode.VaultRaid,
            4,
            uint64(block.timestamp + 1),
            uint64(block.timestamp + 2),
            uint64(block.timestamp + 3),
            1,
            0,
            0
        );
        vm.prank(address(treasury));
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        vault.notifyReward(0);
        vm.prank(address(treasury));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, 1));
        vault.notifyReward(1);
        // The owner cannot advance ETH into the treasury either.
        vm.deal(OWNER, 1 ether);
        vm.prank(OWNER);
        (bool ok,) = address(treasury).call{value: 1 ether}("");
        assertFalse(ok, "no owner operating advances");
    }

    // ------------------------------------------------------------------ the economy, end to end

    // Lifecycle state shared by the step helpers below (keeps each step's stack small).
    uint256 lcIncome;
    uint256 lcPrioSpend;
    uint256 lcPrioOut;
    uint256 lcImdSpend;
    uint256 lcImdOut;
    uint256 lcPrize;
    uint256 lcReserveOut;
    uint256 lcOwnerOut;

    /// @dev Trades on the live pool fund everything: the reserve, the PRIO stream to stakers, the game pool,
    /// the IMD that buys a panel answer, and the owner's 40%. A round is played and settled on the bought
    /// answer; every balance is reconciled at the end.
    function test_fullLifecycleOnTheReplica() public {
        deployApplications();
        seedPrioOnly(8.7e22);
        seedImdPool(8e20, 50 ether);
        runPlan();
        // The owner rotates the signer to a key this test holds (future pins only; the manifest signer stays
        // on record for nothing pinned yet).
        vm.prank(OWNER);
        adapter.setSigner(vm.addr(SIGNER_KEY));
        assertEq(adapter.oracleSigner(), vm.addr(SIGNER_KEY));
        lcFeesAndAllocation();
        lcPurchases();
        lcStaking();
        lcRound();
        lcWithdrawalsAndReconciliation();
    }

    /// @dev 1-2. Fees: ten buys of 0.2 ETH on a PRIO-only pool; the claim path delivers them. Allocation: 10%
    /// reserve (under the target), then 30/30/40.
    function lcFeesAndAllocation() internal {
        for (uint256 i; i < 10; i++) {
            earnFees(0.2 ether);
        }
        lcIncome = treasury.totalIncome();
        assertGt(lcIncome, 0.009 ether, "about 0.5% of 2 ETH");
        assertLt(lcIncome, 0.011 ether);
        assertEq(hook.totalFeeDelivered(), lcIncome);
        assertEq(hook.pendingClaims() + hook.pendingEth(), 0);
        treasury.allocate();
        uint256 toReserve = lcIncome / 10;
        uint256 rest = lcIncome - toReserve;
        assertEq(treasury.reserve(), toReserve);
        assertEq(treasury.imdBudget(), rest * 3 / 10);
        assertEq(treasury.prioBudget(), rest * 3 / 10);
        assertEq(treasury.ownerBudget(), rest - 2 * (rest * 3 / 10));
        assertEq(address(treasury).balance, treasuryBuckets());
    }

    /// @dev 3. The executor buys PRIO for rewards and games, and IMD for the oracle. The ten buys moved the
    /// small launch pool (the whole supply is worth about 10 ETH at the launch price) well below the floor set
    /// for the launch price, so the owner re-signs B5 from the current market first, as the checklist says.
    function lcPurchases() internal {
        vm.prank(OWNER);
        treasury.setPriceFloors(5e7 ether, MIN_IMD_PER_ETH);
        lcPrioSpend = treasury.prioBudget();
        vm.prank(executor);
        lcPrioOut = treasury.buyPrio(lcPrioSpend, 1);
        assertGe(lcPrioOut, lcPrioSpend * 5e7 ether / 1e18, "never below the owner's floor");
        assertEq(prio.balanceOf(address(vault)), lcPrioOut / 2);
        assertEq(vault.rewardsOwed(), lcPrioOut / 2);
        assertEq(arena.unallocatedPrizePool(), lcPrioOut - lcPrioOut / 2);
        assertEq(prio.balanceOf(address(treasury)), 0);
        lcImdSpend = treasury.imdBudget();
        vm.prank(executor);
        lcImdOut = treasury.buyImd(lcImdSpend, 1);
        assertGe(lcImdOut, lcImdSpend * MIN_IMD_PER_ETH / 1e18);
        assertGe(lcImdOut, 0.5 ether, "enough for one panel answer");
        assertEq(imd.balanceOf(address(adapter)), lcImdOut);
        assertEq(imd.balanceOf(address(treasury)), 0);
        assertEq(address(treasury).balance, treasuryBuckets(), "the 0.5% on the treasury's own buy came back as income");
    }

    /// @dev 4. A staker earns the whole stream; principal comes back exactly.
    function lcStaking() internal {
        address staker = makeAddr("staker");
        vm.prank(trader);
        prio.transfer(staker, 1_000 ether);
        vm.startPrank(staker);
        prio.approve(address(vault), 1_000 ether);
        vault.stake(1_000 ether);
        vm.stopPrank();
        skip(30 days);
        vm.prank(staker);
        vault.exit();
        assertApproxEqAbs(prio.balanceOf(staker), 1_000 ether + lcPrioOut / 2, 1e6, "stake back plus the whole stream");
        assertLe(vault.rewardsOwed(), 1e6, "nothing of the stream is stranded");
    }

    /// @dev 5. A round: pinned, created, entered, revealed, answered through a paid request, settled, claimed.
    function lcRound() internal {
        uint64 commitDeadline = uint64(block.timestamp + 1 hours);
        vm.startPrank(OWNER);
        adapter.pinQuestion(1, QUESTION, 1, 5, 4, commitDeadline, "vault raid, 4 vaults");
        lcPrize = arena.unallocatedPrizePool();
        uint256 roundId = arena.createRound(
            Arena.Mode.VaultRaid,
            4,
            commitDeadline,
            commitDeadline + 1 hours,
            commitDeadline + 2 hours,
            lcPrize,
            0,
            keccak256("rules")
        );
        vm.stopPrank();
        assertEq(roundId, 1);
        assertEq(arena.lockedPrizes(), lcPrize);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        vm.startPrank(trader);
        prio.transfer(alice, 102 ether);
        prio.transfer(bob, 102 ether);
        vm.stopPrank();
        lcEnter(alice, 3);
        lcEnter(bob, 1);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.BeforeBoundary.selector, commitDeadline));
        adapter.request(1);
        vm.warp(commitDeadline);
        vm.prank(alice);
        arena.reveal(1, 3, keccak256(abi.encode(alice)));
        vm.prank(bob);
        arena.reveal(1, 1, keccak256(abi.encode(bob)));
        lcAnswer();
        vm.warp(commitDeadline + 1 hours);
        arena.settle(1);
        assertEq(arena.rounds(1).winningChoice, 3);
        assertEq(arena.payoutOf(1, alice), 100 ether + lcPrize);
        assertEq(arena.payoutOf(1, bob), 90 ether);
        vm.prank(alice);
        arena.claim(1);
        vm.prank(bob);
        arena.claim(1);
        assertEq(prio.balanceOf(alice), 100 ether + lcPrize);
        assertEq(prio.balanceOf(bob), 90 ether);
        assertEq(arena.unallocatedPrizePool(), 2 ether + 12 ether, "fees and bob's penalty fund the next round");
        assertEq(
            prio.balanceOf(address(arena)), arena.totalEscrowed() + arena.lockedPrizes() + arena.unallocatedPrizePool()
        );
    }

    function lcEnter(address who, uint8 choice) internal {
        bytes32 c = arena.commitmentOf(1, who, choice, keccak256(abi.encode(who)));
        vm.startPrank(who);
        prio.approve(address(arena), 102 ether);
        arena.enter(1, c);
        vm.stopPrank();
    }

    /// @dev The executor buys the panel answer with the adapter's IMD; the Intake calls back.
    function lcAnswer() internal {
        vm.prank(executor);
        bytes32 intakeId = adapter.request(1);
        assertEq(imd.balanceOf(address(adapter)), lcImdOut - 0.5 ether, "the list price left for the Intake");
        assertEq(imd.balanceOf(INTAKE), 0.5 ether);
        assertEq(intake.lastAction(), planner.ACTION());
        OracleAttestation.Attestation memory a = attestation(intakeId, QUESTION, 6, uint64(block.timestamp)); // 6 % 4 + 1 = 3
        assertTrue(intake.deliver(abi.encode(intakeId, a, sign(a))), "the Intake's callback lands under its stipend");
        assertTrue(adapter.resultOf(1).settled);
        assertEq(adapter.openRequest(1), bytes32(0));
    }

    /// @dev 6. Gas for the operator from the reserve, the owner's 40%, and nothing else leaves.
    function lcWithdrawalsAndReconciliation() internal {
        lcReserveOut = treasury.reserve();
        vm.prank(executor);
        treasury.withdrawReserve(payable(executor), lcReserveOut);
        assertEq(executor.balance, lcReserveOut);
        lcOwnerOut = treasury.ownerBudget();
        vm.prank(OWNER);
        treasury.withdrawOwner(payable(OWNER), lcOwnerOut);
        assertEq(address(treasury).balance, treasuryBuckets());
        assertEq(
            treasury.totalIncome(),
            address(treasury).balance + lcReserveOut + lcOwnerOut + lcPrioSpend + lcImdSpend,
            "every wei of income is held or went out one of the four documented doors"
        );
    }

    /// @dev With the plan's defaults in force, a compromised operator key is bounded: it cannot redirect the
    /// reserve, cannot exceed the per-call, per-bucket or reserve caps, cannot take the owner's budget, cannot
    /// buy below the floor whatever `minOut` it passes, and cannot change any setting.
    function test_executorIsBoundedByThePlanDefaults() public {
        deployApplications();
        seedPrioOnly(8.7e22);
        runPlan();
        // Fee income simulated as the hook delivering 4 ETH (the only door into the treasury).
        vm.deal(HOOK, 4 ether);
        vm.prank(HOOK);
        (bool ok,) = address(treasury).call{value: 4 ether}("");
        assertTrue(ok);
        treasury.allocate();
        assertEq(treasury.reserve(), 0.4 ether);
        assertEq(treasury.prioBudget(), 1.08 ether);
        vm.startPrank(executor);
        vm.expectRevert(FeeTreasury.WrongDestination.selector);
        treasury.withdrawReserve(payable(makeAddr("mule")), 0.01 ether);
        vm.expectRevert(FeeTreasury.ExceedsWindow.selector);
        treasury.withdrawReserve(payable(executor), 0.05 ether + 1);
        treasury.withdrawReserve(payable(executor), 0.05 ether);
        vm.expectRevert(FeeTreasury.ExceedsWindow.selector);
        treasury.withdrawReserve(payable(executor), 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, executor));
        treasury.withdrawOwner(payable(executor), 1);
        vm.expectRevert(FeeTreasury.ExceedsMaxSpend.selector);
        treasury.buyPrio(0.25 ether + 1, 0);
        // At the launch price a small buy clears the floor set for it.
        uint256 out = treasury.buyPrio(0.02 ether, 0);
        assertGe(out, 0.02 ether * MIN_PRIO_PER_ETH / 1e18);
        vm.stopPrank();
        // The executor pushes the price down with its own 1.5 ETH buy on the ~9 ETH launch pool, then tries
        // to buy for the treasury at the manipulated price with minOut = 0: the owner's floor refuses it.
        vm.deal(executor, 1.5 ether);
        swapPrio(executor, true, -1.5 ether, 1.5 ether);
        vm.prank(executor);
        vm.expectRevert(FeeTreasury.Slippage.selector);
        treasury.buyPrio(0.02 ether, 0);
        // The bucket: the owner lowers the floor to let the executor fill it, and the cap still holds.
        vm.prank(OWNER);
        treasury.setPriceFloors(1, 1);
        vm.startPrank(executor);
        treasury.buyPrio(0.25 ether, 0);
        treasury.buyPrio(0.23 ether, 0);
        assertEq(treasury.spentInWindow(), 0.5 ether);
        vm.expectRevert(FeeTreasury.ExceedsWindow.selector);
        treasury.buyPrio(1, 0); // over the 0.5 ETH bucket
        vm.warp(treasury.windowStart() + 1 days);
        treasury.buyPrio(0.01 ether, 0); // the next bucket
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, executor));
        treasury.setSpendPerWindow(100 ether);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, executor));
        treasury.setPriceFloors(1, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, executor));
        treasury.setExecutor(makeAddr("mule"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, executor));
        adapter.setBudget(100 ether);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, executor));
        adapter.withdrawToken(IMD, executor, 1);
        vm.stopPrank();
        assertEq(address(treasury).balance, treasuryBuckets());
        // The owner can revoke the key at any time.
        vm.prank(OWNER);
        treasury.setExecutor(address(0));
        vm.prank(executor);
        vm.expectRevert(FeeTreasury.NotExecutor.selector);
        treasury.buyPrio(0.01 ether, 0);
    }
}
