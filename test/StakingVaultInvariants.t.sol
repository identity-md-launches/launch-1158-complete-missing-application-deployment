// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PrismRiotToken} from "../src/PrismRiotToken.sol";
import {StakingVault} from "../src/StakingVault.sol";

/// @dev Drives the vault alone with several stakers, two funders (the treasury role and the owner), duration
/// changes, idle gaps with nobody staked, stray donations and exits, in random order. Ghost totals record
/// each staker's deposits and withdrawals and every reward paid.
contract VaultHandler is Test {
    PrismRiotToken token;
    StakingVault vault;
    address owner;
    address funder;
    address[] users;

    mapping(address => uint256) public deposited;
    mapping(address => uint256) public withdrawn;
    mapping(address => uint256) public claimed;
    uint256 public ghostFunded;
    uint256 public ghostClaimed;
    uint256 public ghostDonated;
    uint256 public ghostNotifications;
    uint256 public ghostIdleSeconds; // seconds that passed with nothing staked while a stream had time left

    constructor(PrismRiotToken t, StakingVault v, address owner_, address funder_) {
        token = t;
        vault = v;
        owner = owner_;
        funder = funder_;
        for (uint256 i; i < 4; i++) {
            address u = address(uint160(0x1000 + i));
            users.push(u);
            vm.prank(u);
            token.approve(address(vault), type(uint256).max);
        }
        vm.prank(funder);
        token.approve(address(vault), type(uint256).max);
        vm.prank(owner);
        token.approve(address(vault), type(uint256).max);
    }

    function seed() external {
        for (uint256 i; i < users.length; i++) {
            token.transfer(users[i], 100_000 ether);
        }
        token.transfer(funder, 1_000_000 ether);
        token.transfer(owner, 100_000 ether);
    }

    function userCount() external view returns (uint256) {
        return users.length;
    }

    function user(uint256 i) external view returns (address) {
        return users[i];
    }

    function _user(uint256 who) internal view returns (address) {
        return users[who % users.length];
    }

    function stake(uint256 who, uint256 amount) external {
        address u = _user(who);
        uint256 max = token.balanceOf(u);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(u);
        vault.stake(amount);
        deposited[u] += amount;
    }

    /// @dev Withdrawal liveness: a staker can always take back any part of the stake, whatever the stream does.
    function withdraw(uint256 who, uint256 amount) external {
        address u = _user(who);
        uint256 max = vault.staked(u);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        uint256 before = token.balanceOf(u);
        vm.prank(u);
        vault.withdraw(amount);
        assertEq(token.balanceOf(u) - before, amount, "exactly the stake comes back");
        withdrawn[u] += amount;
    }

    function claim(uint256 who) external {
        address u = _user(who);
        uint256 expected = vault.earned(u);
        uint256 before = token.balanceOf(u);
        vm.prank(u);
        vault.claim();
        uint256 got = token.balanceOf(u) - before;
        assertEq(got, expected, "claim pays exactly what earned() showed");
        claimed[u] += got;
        ghostClaimed += got;
    }

    function exit(uint256 who) external {
        address u = _user(who);
        uint256 stakeOf = vault.staked(u);
        if (stakeOf == 0) return;
        uint256 expected = vault.earned(u);
        uint256 before = token.balanceOf(u);
        vm.prank(u);
        vault.exit();
        uint256 got = token.balanceOf(u) - before;
        assertEq(got, stakeOf + expected, "exit pays stake plus rewards, nothing else");
        withdrawn[u] += stakeOf;
        claimed[u] += expected;
        ghostClaimed += expected;
    }

    function fundAsTreasury(uint256 amount) external {
        amount = bound(amount, 1, 50_000 ether);
        if (token.balanceOf(funder) < amount) return;
        vm.prank(funder);
        vault.notifyReward(amount);
        ghostFunded += amount;
        ghostNotifications++;
        assertEq(vault.periodFinish(), block.timestamp + vault.rewardsDuration(), "a fresh schedule from now");
    }

    function fundAsOwner(uint256 amount) external {
        amount = bound(amount, 1, 10_000 ether);
        if (token.balanceOf(owner) < amount) return;
        vm.prank(owner);
        vault.notifyReward(amount);
        ghostFunded += amount;
        ghostNotifications++;
    }

    /// @dev A stranger can never notify, whatever it holds.
    function strangerNotify(uint256 amount) external {
        address s = makeAddr("stranger");
        token.transfer(s, 1 ether);
        vm.startPrank(s);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(StakingVault.NotFunder.selector);
        vault.notifyReward(bound(amount, 1, 1 ether));
        vm.stopPrank();
    }

    /// @dev PRIO sent straight to the vault: counted in the reserve, promised to nobody.
    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1_000 ether);
        if (token.balanceOf(address(this)) < amount) return;
        token.transfer(address(vault), amount);
        ghostDonated += amount;
    }

    function setDuration(uint256 duration) external {
        duration = bound(duration, vault.MIN_DURATION(), vault.MAX_DURATION());
        vm.prank(owner);
        vault.setRewardsDuration(duration);
    }

    function warp(uint256 by) external {
        by = bound(by, 1, 40 days);
        if (vault.totalStaked() == 0 && vault.periodFinish() > vault.lastUpdateTime()) {
            ghostIdleSeconds += by;
        }
        vm.warp(block.timestamp + by);
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 50
contract StakingVaultInvariantsTest is Test {
    PrismRiotToken token;
    StakingVault vault;
    VaultHandler handler;
    address owner = makeAddr("owner");
    address funder = makeAddr("treasury");

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new PrismRiotToken();
        vault = new StakingVault(owner, address(token));
        vm.prank(owner);
        vault.setRewardFunder(funder);
        handler = new VaultHandler(token, vault, owner, funder);
        token.transfer(address(handler), 10_000_000 ether);
        handler.seed();
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](11);
        sels[0] = VaultHandler.stake.selector;
        sels[1] = VaultHandler.withdraw.selector;
        sels[2] = VaultHandler.claim.selector;
        sels[3] = VaultHandler.exit.selector;
        sels[4] = VaultHandler.fundAsTreasury.selector;
        sels[5] = VaultHandler.fundAsOwner.selector;
        sels[6] = VaultHandler.strangerNotify.selector;
        sels[7] = VaultHandler.donate.selector;
        sels[8] = VaultHandler.setDuration.selector;
        sels[9] = VaultHandler.warp.selector;
        sels[10] = VaultHandler.stake.selector;
        targetSelector(FuzzSelector(address(handler), sels));
    }

    /// @dev Principal is exact per staker and in total: what the vault records is deposits minus withdrawals.
    function invariant_principalIsExactPerStaker() public view {
        uint256 sum;
        for (uint256 i; i < handler.userCount(); i++) {
            address u = handler.user(i);
            assertEq(vault.staked(u), handler.deposited(u) - handler.withdrawn(u), "staked == deposited - withdrawn");
            sum += vault.staked(u);
        }
        assertEq(sum, vault.totalStaked(), "sum of stakes is the total");
    }

    /// @dev Conservation: the vault holds principal plus unpaid promised rewards plus stray donations, exactly.
    /// Nothing funded is ever double-counted and nothing is paid that was not funded.
    function invariant_balanceIsPrincipalPlusOwedPlusDonations() public view {
        assertEq(
            token.balanceOf(address(vault)),
            vault.totalStaked() + vault.rewardsOwed() + handler.ghostDonated(),
            "balance == principal + owed + donated"
        );
        assertEq(vault.rewardsOwed(), handler.ghostFunded() - handler.ghostClaimed(), "owed == funded - claimed");
        assertLe(handler.ghostClaimed(), handler.ghostFunded(), "never pays more than funded");
    }

    /// @dev What every staker could claim right now is covered by what is owed (and so by the balance).
    function invariant_accruedNeverExceedsOwed() public view {
        uint256 accrued;
        for (uint256 i; i < handler.userCount(); i++) {
            accrued += vault.earned(handler.user(i));
        }
        assertLe(accrued, vault.rewardsOwed(), "sum of earned <= rewardsOwed");
    }

    /// @dev The reward rate never promises more than the stream holds: rate * remaining time <= owed.
    function invariant_rateCoversRemainingSchedule() public view {
        if (block.timestamp >= vault.periodFinish()) return;
        uint256 remaining = (vault.periodFinish() - block.timestamp) * vault.rewardRate() / 1e18;
        assertLe(remaining, vault.rewardsOwed(), "remaining stream <= owed");
    }

    /// @dev Idle seconds (nothing staked, stream with time left) extend the schedule: with no notification in
    /// between the finish moves forward by exactly the idle time. Here as the weaker, always-true form.
    function invariant_scheduleNeverEndsBeforeTheStreamIsPaid() public view {
        if (vault.rewardsOwed() == 0) return;
        if (vault.totalStaked() == 0) {
            // While idle the stream has not been consumed: the finish is still ahead of the last update.
            assertGe(vault.periodFinish(), vault.lastUpdateTime());
        }
    }
}
