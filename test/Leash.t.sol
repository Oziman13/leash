// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Leash} from "../src/Leash.sol";

contract Reenter {
    Leash leash;
    uint256 id;

    constructor(Leash l) {
        leash = l;
    }

    function arm(uint256 id_) external {
        id = id_;
    }

    receive() external payable {
        // try to grab the same request twice
        try leash.approve(id, false) {} catch {}
    }
}

contract Rejecter {
    receive() external payable {
        revert("no");
    }
}

contract LeashTest is Test {
    Leash leash;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address shop = makeAddr("shop");
    address scam = makeAddr("scam");
    address stranger = makeAddr("stranger");

    uint128 constant USDC = 1e18; // native USDC on Arc has 18 decimals

    function setUp() public {
        leash = new Leash();
        vm.deal(owner, 1000 * USDC);
        vm.deal(stranger, 100 * USDC);
        vm.prank(owner);
        leash.registerAgent{value: 100 * USDC}(agent, "shopper", 20 * USDC, 5 * USDC, false, 1 * USDC, new address[](0));
    }

    function _agent() internal view returns (Leash.Agent memory a, uint256 rem) {
        return leash.getAgent(agent);
    }

    // ---------------------------------------------------------------- registration

    function test_registerSeedsGasAndCountsIt() public view {
        (Leash.Agent memory a, uint256 rem) = _agent();
        assertEq(a.owner, owner);
        assertEq(a.balance, 99 * USDC);
        assertEq(agent.balance, 1 * USDC, "agent got gas seed");
        assertEq(a.spentInWindow, 1 * USDC, "gas seed counts as spend");
        assertEq(a.totalGas, 1 * USDC);
        assertEq(rem, 19 * USDC);
        assertEq(leash.agentsOf(owner)[0], agent);
    }

    function test_registerRejectsBadInputs() public {
        vm.startPrank(owner);
        vm.expectRevert(Leash.AgentExists.selector);
        leash.registerAgent(agent, "x", 10, 5, false, 0, new address[](0));
        vm.expectRevert(Leash.BadLimits.selector);
        leash.registerAgent(makeAddr("a2"), "x", 10, 11, false, 0, new address[](0));
        vm.expectRevert(Leash.BadLimits.selector);
        leash.registerAgent(makeAddr("a3"), "x", 10, 0, false, 0, new address[](0));
        vm.expectRevert(Leash.BadLimits.selector);
        leash.registerAgent{value: 1}(makeAddr("a4"), "x", 10, 5, false, 2, new address[](0));
        vm.expectRevert(Leash.BadAddress.selector);
        leash.registerAgent(owner, "x", 10, 5, false, 0, new address[](0));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- auto payments

    function test_payWithinRulesSettlesInstantly() public {
        vm.prank(agent);
        (bool settled,) = leash.pay(shop, 4 * USDC, "api credits");
        assertTrue(settled);
        assertEq(shop.balance, 4 * USDC);
        (Leash.Agent memory a, uint256 rem) = _agent();
        assertEq(a.balance, 95 * USDC);
        assertEq(rem, 15 * USDC);
        assertEq(a.totalPayments, 1);
    }

    function test_overPerTxQueues() public {
        vm.prank(agent);
        (bool settled, uint256 id) = leash.pay(shop, 6 * USDC, "big order");
        assertFalse(settled);
        assertEq(shop.balance, 0);
        Leash.Request memory r = leash.getRequest(id);
        assertEq(uint8(r.status), uint8(Leash.Status.Pending));
        assertEq(r.amount, 6 * USDC);
        assertEq(r.memo, "big order");
        (Leash.Agent memory a,) = _agent();
        assertEq(a.balance, 99 * USDC, "queued payment does not move money");
    }

    function test_overDailyQueues() public {
        vm.startPrank(agent);
        leash.pay(shop, 5 * USDC, "1");
        leash.pay(shop, 5 * USDC, "2");
        leash.pay(shop, 5 * USDC, "3");
        // 1 (gas seed) + 15 spent, 4 left
        (bool settled,) = leash.pay(shop, 5 * USDC, "4");
        vm.stopPrank();
        assertFalse(settled);
        assertEq(shop.balance, 15 * USDC);
    }

    function test_windowResetsAfter24h() public {
        vm.startPrank(agent);
        leash.pay(shop, 5 * USDC, "1");
        leash.pay(shop, 5 * USDC, "2");
        leash.pay(shop, 5 * USDC, "3");
        vm.warp(block.timestamp + 1 days);
        (bool settled,) = leash.pay(shop, 5 * USDC, "next day");
        vm.stopPrank();
        assertTrue(settled);
        (Leash.Agent memory a,) = _agent();
        assertEq(a.spentInWindow, 5 * USDC);
    }

    function test_allowlistOnlyQueuesUnknownRecipient() public {
        vm.prank(owner);
        leash.setLimits(agent, 20 * USDC, 5 * USDC, true);
        vm.prank(owner);
        leash.setAllowed(agent, shop, true);

        vm.startPrank(agent);
        (bool ok1,) = leash.pay(shop, 1 * USDC, "known");
        (bool ok2,) = leash.pay(scam, 1 * USDC, "unknown");
        vm.stopPrank();
        assertTrue(ok1);
        assertFalse(ok2);
        assertEq(scam.balance, 0);
    }

    function test_payMoreThanBudgetReverts() public {
        vm.prank(owner);
        leash.withdraw(agent, 98 * USDC);
        vm.prank(agent);
        vm.expectRevert(Leash.InsufficientBudget.selector);
        leash.pay(shop, 2 * USDC, "x");
    }

    function test_onlyAgentsCanPay() public {
        vm.prank(stranger);
        vm.expectRevert(Leash.NotAgent.selector);
        leash.pay(shop, 1, "x");
    }

    // ---------------------------------------------------------------- approvals

    function test_ownerApprovesQueuedPaymentAndTrustsRecipient() public {
        vm.prank(owner);
        leash.setLimits(agent, 20 * USDC, 5 * USDC, true);
        vm.prank(agent);
        (, uint256 id) = leash.pay(shop, 30 * USDC, "laptop");

        vm.prank(owner);
        leash.approve(id, true);
        assertEq(shop.balance, 30 * USDC);
        assertTrue(leash.allowed(agent, shop));
        assertEq(uint8(leash.getRequest(id).status), uint8(Leash.Status.Approved));
        (Leash.Agent memory a,) = _agent();
        assertEq(a.balance, 69 * USDC);
        assertEq(a.spentInWindow, 1 * USDC, "approved spend does not eat the auto window");

        // now trusted, small payment goes straight through
        vm.prank(agent);
        (bool settled,) = leash.pay(shop, 1 * USDC, "case");
        assertTrue(settled);
    }

    function test_onlyOwnerCanApproveOrReject() public {
        vm.prank(agent);
        (, uint256 id) = leash.pay(shop, 6 * USDC, "x");
        vm.prank(stranger);
        vm.expectRevert(Leash.NotOwner.selector);
        leash.approve(id, false);
        vm.prank(agent);
        vm.expectRevert(Leash.NotOwner.selector);
        leash.approve(id, false);
        vm.prank(stranger);
        vm.expectRevert(Leash.NotOwner.selector);
        leash.reject(id);
    }

    function test_rejectAndCancelAreFinal() public {
        vm.startPrank(agent);
        (, uint256 id1) = leash.pay(shop, 6 * USDC, "a");
        (, uint256 id2) = leash.pay(shop, 7 * USDC, "b");
        leash.cancel(id2);
        vm.stopPrank();

        vm.startPrank(owner);
        leash.reject(id1);
        vm.expectRevert(Leash.NotPending.selector);
        leash.approve(id1, false);
        vm.expectRevert(Leash.NotPending.selector);
        leash.approve(id2, false);
        vm.stopPrank();
        assertEq(shop.balance, 0);
    }

    function test_approveNeedsBudget() public {
        vm.prank(agent);
        (, uint256 id) = leash.pay(shop, 50 * USDC, "x");
        vm.startPrank(owner);
        leash.withdraw(agent, 60 * USDC);
        vm.expectRevert(Leash.InsufficientBudget.selector);
        leash.approve(id, false);
        vm.stopPrank();
    }

    function test_approveCannotBeReentered() public {
        Reenter evil = new Reenter(leash);
        // evil is both the recipient and tries to approve again while receiving;
        // it is not the owner, but even the lock alone must stop a second payout.
        vm.prank(agent);
        (, uint256 id) = leash.pay(address(evil), 6 * USDC, "x");
        evil.arm(id);
        vm.prank(owner);
        leash.approve(id, false);
        assertEq(address(evil).balance, 6 * USDC);
    }

    function test_failedTransferRevertsWholePayment() public {
        Rejecter r = new Rejecter();
        vm.prank(agent);
        vm.expectRevert(Leash.TransferFailed.selector);
        leash.pay(address(r), 1 * USDC, "x");
        (Leash.Agent memory a,) = _agent();
        assertEq(a.balance, 99 * USDC);
    }

    // ---------------------------------------------------------------- kill switch

    function test_freezeStopsEverything() public {
        vm.prank(owner);
        leash.setFrozen(agent, true);
        vm.startPrank(agent);
        vm.expectRevert(Leash.IsFrozen.selector);
        leash.pay(shop, 1 * USDC, "x");
        vm.expectRevert(Leash.IsFrozen.selector);
        leash.refuel(1);
        vm.stopPrank();
        assertEq(leash.check(agent, shop, 1), "frozen");

        vm.prank(owner);
        leash.setFrozen(agent, false);
        vm.prank(agent);
        (bool settled,) = leash.pay(shop, 1 * USDC, "x");
        assertTrue(settled);
    }

    function test_onlyOwnerCanFreezeWithdrawConfigure() public {
        vm.startPrank(agent);
        vm.expectRevert(Leash.NotOwner.selector);
        leash.setFrozen(agent, false);
        vm.expectRevert(Leash.NotOwner.selector);
        leash.withdraw(agent, 1);
        vm.expectRevert(Leash.NotOwner.selector);
        leash.setLimits(agent, 1000 * USDC, 1000 * USDC, false);
        vm.expectRevert(Leash.NotOwner.selector);
        leash.setAllowed(agent, scam, true);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- gas = dollars

    function test_refuelComesFromSameDollarBudget() public {
        vm.startPrank(agent);
        leash.pay(shop, 5 * USDC, "1");
        leash.pay(shop, 5 * USDC, "2");
        leash.pay(shop, 5 * USDC, "3");
        leash.refuel(2 * USDC); // 1 + 15 + 2 = 18
        vm.expectRevert(Leash.OverLimit.selector);
        leash.refuel(3 * USDC); // would be 21 > 20
        vm.stopPrank();
        (Leash.Agent memory a,) = _agent();
        assertEq(a.totalGas, 3 * USDC);
        assertEq(a.totalSpent, 18 * USDC);
        assertEq(agent.balance, 3 * USDC);
    }

    /// @notice The core guarantee: whatever the agent tries, the dollars that leave the
    ///         budget without a human approval never exceed the daily limit.
    function testFuzz_autoSpendNeverExceedsDailyLimit(uint128[12] memory amounts, bool[12] memory isGas) public {
        uint256 before = 99 * USDC;
        for (uint256 i; i < amounts.length; i++) {
            uint128 amt = uint128(bound(amounts[i], 1, 30 * USDC));
            vm.prank(agent);
            if (isGas[i]) {
                try leash.refuel(amt) {} catch {}
            } else {
                try leash.pay(shop, amt, "f") {} catch {}
            }
        }
        (Leash.Agent memory a,) = _agent();
        uint256 left = before - a.balance; // money that left the vault, all automatic
        assertLe(left + 1 * USDC, 20 * USDC, "gas seed + auto spend <= daily limit");
        assertEq(shop.balance + (agent.balance - 1 * USDC), left);
    }

    // ---------------------------------------------------------------- dry run

    function test_checkExplainsDecision() public view {
        assertEq(leash.check(agent, shop, 1 * USDC), "");
        assertEq(leash.check(agent, shop, 6 * USDC), "over per-payment limit");
        assertEq(leash.check(agent, shop, 500 * USDC), "insufficient budget");
        assertEq(leash.check(stranger, shop, 1), "not an agent");
    }

    function test_registerWithTrustedList() public {
        address a2 = makeAddr("a2");
        address[] memory t = new address[](2);
        t[0] = shop;
        t[1] = owner;
        vm.prank(owner);
        leash.registerAgent{value: 10 * USDC}(a2, "trusted", 5 * USDC, 1 * USDC, true, 0, t);
        assertTrue(leash.allowed(a2, shop));
        assertTrue(leash.allowed(a2, owner));
        assertFalse(leash.allowed(a2, scam));
        assertEq(leash.check(a2, shop, 1 * USDC), "");
        assertEq(leash.check(a2, scam, 1 * USDC), "recipient not on allowlist");
        assertEq(leash.agentsOf(owner).length, 2);
    }

    function test_anyoneCanFund() public {
        vm.prank(stranger);
        leash.fund{value: 10 * USDC}(agent);
        (Leash.Agent memory a,) = _agent();
        assertEq(a.balance, 109 * USDC);
    }
}
