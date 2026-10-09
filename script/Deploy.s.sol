// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PrismRiotToken} from "../src/PrismRiotToken.sol";
import {TreasuryFeeHook} from "../src/TreasuryFeeHook.sol";
import {FeeTreasury} from "../src/FeeTreasury.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {Arena, IRoundOracle} from "../src/Arena.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";

/// @title Reviewable deployment logic for PRISM RIOT
/// @notice On an IMD launch the manifest step deploys every contract from its bytecode (the hook through
/// CREATE2 with a mined salt), so this script is a rehearsal and a reference for the post-launch wiring,
/// not the launch itself. `run()` reads nothing from the environment; tests call `deployAll` directly.
contract DeployScript is Script {
    struct Config {
        IPoolManager poolManager;
        address factory;
        address owner;
        address oracleSigner;
    }

    struct Deployed {
        PrismRiotToken token;
        TreasuryFeeHook hook;
        FeeTreasury treasury;
        StakingVault vault;
        Arena arena;
        OracleAdapter adapter;
    }

    /// @notice The contracts-only launch (2026-10-09): the token, hook and pool are already live; only these
    /// four are deployed, each with two static constructor arguments (see docs/DEPLOYMENT.md).
    struct AppConfig {
        IPoolManager poolManager; // live PoolManager
        address owner; // live project owner
        address prio; // live PRIO
        address oracleSigner; // current IMD oracle signer
    }

    struct Applications {
        FeeTreasury treasury;
        StakingVault vault;
        Arena arena;
        OracleAdapter adapter;
    }

    uint160 public constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    /// @dev Mines a CREATE2 salt for `deployer` so the hook lands on an address carrying `HOOK_FLAGS`.
    function mineSalt(address deployer, bytes memory creationCode) public pure returns (bytes32 salt, address at) {
        bytes32 h = keccak256(creationCode);
        for (uint256 i = 0; i < 500_000; i++) {
            at = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), h)))));
            if (uint160(at) & 0x3FFF == HOOK_FLAGS) return (bytes32(i), at);
        }
        revert("no salt");
    }

    /// @notice Deploys everything with `deployer` as the CREATE2 deployer of the hook and wires what the
    /// owner would wire after launch. Called by tests; `run()` is only a thin wrapper.
    function deployAll(Config memory c) public returns (Deployed memory d) {
        d.token = new PrismRiotToken();
        bytes memory creation = abi.encodePacked(
            type(TreasuryFeeHook).creationCode, abi.encode(c.poolManager, address(d.token), c.factory, c.owner)
        );
        (bytes32 salt,) = mineSalt(address(this), creation);
        d.hook = new TreasuryFeeHook{salt: salt}(c.poolManager, address(d.token), c.factory, c.owner);
        d.treasury = new FeeTreasury(c.poolManager, c.owner);
        d.vault = new StakingVault(c.owner, address(d.token));
        d.arena = new Arena(c.owner, address(d.token));
        d.adapter = new OracleAdapter(c.owner, c.oracleSigner);
    }

    /// @notice Deploys only the four application contracts, exactly as the contracts-only factory does: plain
    /// constructors, static arguments, no call to any other contract.
    function deployApplications(AppConfig memory c) public returns (Applications memory d) {
        d.treasury = new FeeTreasury(c.poolManager, c.owner);
        d.vault = new StakingVault(c.owner, c.prio);
        d.arena = new Arena(c.owner, c.prio);
        d.adapter = new OracleAdapter(c.owner, c.oracleSigner);
    }

    function run() external {
        revert("fill a Config and call deployAll from a wrapper; the IMD launch deploys from the manifest");
    }
}
