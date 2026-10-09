// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PrismRiotToken} from "../../src/PrismRiotToken.sol";
import {TreasuryFeeHook} from "../../src/TreasuryFeeHook.sol";
import {FeeTreasury} from "../../src/FeeTreasury.sol";
import {StakingVault} from "../../src/StakingVault.sol";
import {Arena} from "../../src/Arena.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";
import {ConfigPlan} from "../../script/ConfigPlan.s.sol";
import {MockIntake} from "./MockIntake.sol";

/// @dev A local replica of the mainnet records the contracts-only launch builds on, at their real addresses:
/// the PoolManager, PRIO (minted to the launch factory), the TreasuryFeeHook (constructor run in place, so its
/// immutables and the flag check are the real ones), the ETH/PRIO pool opened by the factory at the launch
/// price with PRIO-only liquidity as on mainnet, IMD and an Intake stand-in at their addresses, and the IMD
/// pool the plan names. The four application contracts are then created from their creation code with the
/// manifest's static arguments, exactly as the factory does, and the owner's plan can be executed step by step.
contract Replica is Test {
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address constant FACTORY = 0x12C63b581d07093F6126bc02263c58f7EadaA96F;
    uint24 constant POOL_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    /// @dev sqrt(1e8) * 2^96: 1e8 PRIO per ETH, the launch price recorded in docs/DEPLOYMENT.md.
    uint160 constant SQRT_PRICE_1E8 = uint160(10_000) << 96;
    /// @dev The usable tick at or below the launch price (log_1.0001(1e8) = 184206.6).
    int24 constant LAUNCH_TICK = 184_200;
    int24 constant IMD_TICK = 55_800; // near the mainnet tick (55887), aligned to the pool's spacing of 200
    /// @dev Floors a little below the launch prices, as the README instructs the owner.
    uint256 constant MIN_PRIO_PER_ETH = 9e7 ether;
    uint256 constant MIN_IMD_PER_ETH = 200 ether;

    ConfigPlan planner;
    address OWNER;
    address PRIO;
    address HOOK;
    address POOL_MANAGER;
    address IMD;
    address INTAKE;
    address ORACLE_SIGNER;

    PoolManager manager;
    PrismRiotToken prio;
    TreasuryFeeHook hook;
    FeeTreasury treasury;
    StakingVault vault;
    Arena arena;
    OracleAdapter adapter;
    PrismRiotToken imd;
    MockIntake intake;
    PoolSwapTest router;
    PoolModifyLiquidityTest lpRouter;
    PoolKey key;
    PoolKey imdKey;

    address executor = makeAddr("operator");
    address imdWhale = makeAddr("imdWhale");
    address trader = makeAddr("trader");

    function setUpReplica() internal {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        planner = new ConfigPlan();
        OWNER = planner.OWNER();
        PRIO = planner.PRIO();
        HOOK = planner.HOOK();
        POOL_MANAGER = planner.POOL_MANAGER();
        IMD = planner.IMD();
        INTAKE = planner.INTAKE();
        ORACLE_SIGNER = planner.ORACLE_SIGNER();

        // Live infrastructure, created in place so immutables carry the real addresses.
        runCreationAt(
            POOL_MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this))), address(this)
        );
        manager = PoolManager(POOL_MANAGER);
        runCreationAt(PRIO, type(PrismRiotToken).creationCode, FACTORY);
        prio = PrismRiotToken(PRIO);
        runCreationAt(
            HOOK,
            abi.encodePacked(
                type(TreasuryFeeHook).creationCode, abi.encode(IPoolManager(POOL_MANAGER), PRIO, FACTORY, OWNER)
            ),
            address(this)
        );
        hook = TreasuryFeeHook(payable(HOOK));
        runCreationAt(IMD, type(PrismRiotToken).creationCode, imdWhale);
        imd = PrismRiotToken(IMD);
        vm.etch(INTAKE, address(new MockIntake()).code);
        intake = MockIntake(INTAKE);

        router = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(PRIO),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
        vm.prank(FACTORY);
        manager.initialize(key, SQRT_PRICE_1E8);
        imdKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(IMD),
            fee: planner.IMD_POOL_FEE(),
            tickSpacing: planner.IMD_POOL_TICK_SPACING(),
            hooks: IHooks(planner.IMD_POOL_HOOKS())
        });
        manager.initialize(imdKey, TickMath.getSqrtPriceAtTick(IMD_TICK));
        vm.prank(FACTORY);
        prio.approve(address(lpRouter), type(uint256).max);
        vm.prank(imdWhale);
        imd.approve(address(lpRouter), type(uint256).max);
    }

    /// @dev Runs `creation` as the code of `at` with `sender` as msg.sender and installs what it returns, so a
    /// contract lands on a chosen address with its constructor really executed there.
    function runCreationAt(address at, bytes memory creation, address sender) internal {
        vm.etch(at, creation);
        vm.prank(sender);
        (bool ok, bytes memory runtime) = at.call("");
        require(ok, "constructor reverted");
        vm.etch(at, runtime);
    }

    /// @dev The manifest: creation code + abi-encoded static arguments, created by the factory address.
    function deployApplications() internal {
        treasury =
            FeeTreasury(payable(createFrom(FACTORY, type(FeeTreasury).creationCode, abi.encode(POOL_MANAGER, OWNER))));
        vault = StakingVault(createFrom(FACTORY, type(StakingVault).creationCode, abi.encode(OWNER, PRIO)));
        arena = Arena(createFrom(FACTORY, type(Arena).creationCode, abi.encode(OWNER, PRIO)));
        adapter = OracleAdapter(createFrom(FACTORY, type(OracleAdapter).creationCode, abi.encode(OWNER, ORACLE_SIGNER)));
    }

    function createFrom(address deployer, bytes memory creation, bytes memory args) internal returns (address at) {
        bytes memory code = bytes.concat(creation, args);
        vm.prank(deployer);
        assembly ("memory-safe") {
            at := create(0, add(code, 32), mload(code))
        }
        require(at != address(0) && at.code.length > 0, "constructor failed");
    }

    function apps() internal view returns (ConfigPlan.Apps memory) {
        return ConfigPlan.Apps(address(treasury), address(vault), address(arena), address(adapter));
    }

    function params() internal view returns (ConfigPlan.Params memory) {
        return planner.defaults(executor, MIN_PRIO_PER_ETH, MIN_IMD_PER_ETH);
    }

    /// @dev Executes the whole plan from the owner wallet: A1-A7, B1-B12, B13 and B13b.
    function runPlan() internal {
        ConfigPlan.Step[] memory steps = planner.plan(apps(), params());
        for (uint256 i; i < steps.length; i++) {
            execStep(steps[i]);
        }
        execStep(planner.executorStep(apps(), params()));
    }

    function execStep(ConfigPlan.Step memory s) internal {
        vm.prank(OWNER);
        (bool ok, bytes memory ret) = s.target.call(s.data);
        require(ok, string.concat("plan step failed: ", s.label, " ", vm.toString(ret)));
    }

    // ------------------------------------------------------------------ liquidity

    /// @dev The launch seed: PRIO only, in a range at or below the launch price, from the factory's balance.
    function seedPrioOnly(int256 liquidity) internal {
        vm.prank(FACTORY);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(TickMath.minUsableTick(TICK_SPACING), LAUNCH_TICK, liquidity, 0), ""
        );
    }

    /// @dev Full-range liquidity with ETH alongside, so sells can be paid.
    function seedBothSides(int256 liquidity, uint256 ethValue) internal {
        vm.deal(FACTORY, FACTORY.balance + ethValue);
        vm.prank(FACTORY);
        lpRouter.modifyLiquidity{value: ethValue}(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), liquidity, 0
            ),
            ""
        );
    }

    function seedImdPool(int256 liquidity, uint256 ethValue) internal {
        vm.deal(imdWhale, imdWhale.balance + ethValue);
        int24 spacing = planner.IMD_POOL_TICK_SPACING();
        vm.prank(imdWhale);
        lpRouter.modifyLiquidity{value: ethValue}(
            imdKey,
            ModifyLiquidityParams(TickMath.minUsableTick(spacing), TickMath.maxUsableTick(spacing), liquidity, 0),
            ""
        );
    }

    // ------------------------------------------------------------------ swaps

    function swapPrio(address who, bool zeroForOne, int256 amountSpecified, uint256 value)
        internal
        returns (BalanceDelta)
    {
        vm.startPrank(who);
        prio.approve(address(router), type(uint256).max);
        BalanceDelta d = router.swap{value: value}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        return d;
    }

    /// @dev A buy of `ethIn` by a trader, then the claim path the launch pool takes (no ETH in the manager
    /// before the first buy settles), so the fee reaches the treasury.
    function earnFees(uint256 ethIn) internal {
        vm.deal(trader, trader.balance + ethIn);
        swapPrio(trader, true, -int256(ethIn), ethIn);
        uint256 claims = hook.pendingClaims();
        if (claims != 0 && hook.treasury() != address(0)) hook.redeemClaims(claims);
        if (hook.pendingEth() != 0 && hook.treasury() != address(0)) hook.flush();
    }

    // ------------------------------------------------------------------ attestations

    function attestation(bytes32 requestId, bytes32 questionHash, uint256 answer, uint64 issuedAt)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        a = OracleAttestation.Attestation({
            requestId: requestId,
            chainId: 1,
            questionHash: questionHash,
            answerType: OracleAttestation.ANSWER_UINT256,
            answer: abi.encode(answer),
            figure: 0,
            fromBlock: 1,
            toBlock: 2,
            blockHash: bytes32(uint256(1)),
            panelJobId: bytes32(uint256(2)),
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: issuedAt,
            expiresAt: uint64(block.timestamp + 1 days)
        });
    }

    function sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, adapter.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function treasuryBuckets() internal view returns (uint256) {
        return treasury.unallocated() + treasury.reserve() + treasury.imdBudget() + treasury.prioBudget()
            + treasury.ownerBudget();
    }
}
