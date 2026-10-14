// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {L4Fixture} from "./L4Fixture.sol";
import {FeeRouter} from "src/FeeRouter.sol";
import {Params} from "src/Params.sol";
import {Civic} from "src/Civic.sol";
import {Billboards} from "src/Billboards.sol";
import "src/lib/Errors.sol";

contract L4FeeRecipient {
    FeeRouter private immutable fees;
    bool public reject = true;
    bool public reentered;

    constructor(FeeRouter f) {
        fees = f;
    }

    function accept() external {
        reject = false;
    }

    function withdraw() external {
        fees.withdraw();
    }

    receive() external payable {
        require(!reject, "recipient rejects ETH");
        (reentered,) = address(fees).call(abi.encodeCall(FeeRouter.withdraw, ()));
    }
}

contract L4FailurePathsTest is L4Fixture {
    function _sellTax(uint256 amount) private {
        vm.prank(address(exchange));
        fees.depositSellTax{value: amount}();
    }

    function _route(uint256 amount) private {
        asset.transfer(address(fees), amount);
        vm.prank(address(l3));
        fees.routeTokens(amount);
    }

    function test_billboardFailedOutbidCannotCreateRefundOrReplaceWinner() public {
        _enable(5);
        vm.prank(actors[0]);
        boards.bidBillboard(3, 1000 ether, "FIRST", "first");
        uint256 w = boards.week() + 1;
        bytes32 before_ = keccak256(abi.encode(boards.billboard(w, 3)));
        asset.setFail(true);
        vm.prank(actors[1]);
        vm.expectRevert("test transfer failure");
        boards.bidBillboard(3, 2000 ether, "SECOND", "second");
        assertEq(keccak256(abi.encode(boards.billboard(w, 3))), before_);
        assertEq(boards.refund(actors[0]), 0);
        assertEq(boards.escrow(), 1000 ether);
        assertEq(asset.balanceOf(address(boards)), 1000 ether);
        asset.setFail(false);
        vm.prank(actors[1]);
        boards.bidBillboard(3, 2000 ether, "SECOND", "second");
        assertEq(boards.refund(actors[0]), 1000 ether);
    }

    function test_billboardFailedRefundAndSettlementPreserveObligations() public {
        _enable(5);
        vm.startPrank(actors[0]);
        boards.bidBillboard(0, 1000 ether, "FIRST", "first");
        boards.bidBillboard(0, 1100 ether, "SELF OUTBID", "first");
        vm.stopPrank();
        asset.setFail(true);
        vm.prank(actors[0]);
        vm.expectRevert("test transfer failure");
        boards.withdrawRefund();
        assertEq(boards.refund(actors[0]), 1000 ether);
        vm.warp(launch + 7 days);
        vm.expectRevert("test transfer failure");
        boards.settleBillboard(1, 0);
        assertFalse(boards.billboard(1, 0).settled);
        assertEq(boards.escrow(), 2100 ether);
        assertEq(asset.allowance(address(boards), address(pool)), 0);
        asset.setFail(false);
        boards.settleBillboard(1, 0);
        vm.prank(actors[0]);
        boards.withdrawRefund();
        assertEq(boards.escrow(), 0);
        assertEq(asset.balanceOf(address(pool)), 1100 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_billboardRejectsEveryDisallowedTextByte(uint8 candidate, uint8 position) public {
        _enable(5);
        // Map directly into all invalid byte values; no discarded fuzz runs.
        bytes memory invalid = new bytes(256);
        uint256 length;
        for (uint256 i; i < 256; ++i) {
            bool allowed = (i >= 65 && i <= 90) || (i >= 97 && i <= 122) || (i >= 48 && i <= 57) || i == 32 || i == 33
                || i == 45 || i == 95;
            if (!allowed) invalid[length++] = bytes1(uint8(i));
        }
        bytes memory text = bytes("VALID BILLBOARD TEXT");
        text[position % text.length] = invalid[uint256(candidate) % length];
        vm.prank(actors[0]);
        vm.expectRevert(InvalidValue.selector);
        boards.bidBillboard(0, 1000 ether, string(text), "valid_handle");
        assertEq(boards.escrow(), 0);
        assertEq(asset.balanceOf(actors[0]), ACTOR_FUNDS);
    }

    function test_billboardTextLengthHandleAndMinimumBoundaries() public {
        _enable(5);
        vm.startPrank(actors[0]);
        vm.expectRevert(InvalidValue.selector);
        boards.bidBillboard(0, 750 ether, "", "ok");
        vm.expectRevert(InvalidValue.selector);
        boards.bidBillboard(0, 750 ether, "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567", "ok");
        vm.expectRevert(InvalidValue.selector);
        boards.bidBillboard(0, 750 ether, "ok", "1234567890123456");
        vm.expectRevert(InvalidValue.selector);
        boards.bidBillboard(0, 750 ether, "ok", "a-b");
        vm.expectRevert(InvalidValue.selector);
        boards.bidBillboard(8, 750 ether, "ok", "ok");
        vm.expectRevert(InvalidValue.selector);
        boards.bidBillboard(0, 750 ether - 1, "ok", "ok");
        boards.bidBillboard(0, 750 ether, "ABCDEFGHIJKLMNOPQRSTUVWXYZ123456", "123456789012345");
        vm.expectRevert(InvalidValue.selector);
        boards.bidBillboard(0, 787.5 ether, "ok", "ok");
        boards.bidBillboard(0, 787.5 ether + 1, "ok", "ok");
        vm.stopPrank();
        assertEq(boards.refund(actors[0]), 750 ether);
    }

    function test_lockFailedTransferDoesNotInsertOrIncreaseDistrictStake() public {
        _enable(4);
        address p = actors[0];
        uint256 district = economy.district(p);
        asset.setFail(true);
        vm.prank(p);
        vm.expectRevert("test transfer failure");
        economy.lock(15000 ether, 7);
        assertEq(economy.totalLocked(), 0);
        assertEq(economy.districtTotal(district), 0);
        assertEq(economy.head(district), address(0));
        (uint256 amount,,,) = economy.locks(p);
        assertEq(amount, 0);
        asset.setFail(false);
        vm.prank(p);
        economy.lock(15000 ether, 7);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        asset.setFail(true);
        vm.prank(p);
        vm.expectRevert("test transfer failure");
        economy.unlock();
        assertEq(economy.head(district), p);
        assertEq(economy.totalLocked(), 15000 ether);
        asset.setFail(false);
        l3.setLive(false);
        vm.prank(p);
        economy.unlock();
        assertEq(asset.balanceOf(p), ACTOR_FUNDS);
    }

    function test_lockRejectsZeroShortPrincipalBadTermDuplicateAndEarlyExit() public {
        _enable(4);
        vm.startPrank(actors[0]);
        vm.expectRevert(InvalidValue.selector);
        economy.lock(0, 7);
        vm.expectRevert(InvalidValue.selector);
        economy.lock(15000 ether - 1, 7);
        vm.expectRevert(InvalidValue.selector);
        economy.lock(15000 ether, 8);
        economy.lock(15000 ether, 7);
        vm.expectRevert(AlreadyDone.selector);
        economy.lock(15000 ether, 7);
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        vm.expectRevert(TooEarly.selector);
        economy.unlock();
        vm.warp(vm.getBlockTimestamp() + 1);
        economy.unlock();
        vm.expectRevert(TooEarly.selector);
        economy.unlock();
        vm.stopPrank();
        assertEq(asset.balanceOf(actors[0]), ACTOR_FUNDS);
    }

    function test_feeRejectedStreamsAndProducersCannotMoveFunds() public {
        vm.expectRevert(InvalidValue.selector);
        fees.depositBaseFee();
        vm.expectRevert(InvalidValue.selector);
        fees.depositPack{value: 1}();
        vm.expectRevert(InvalidValue.selector);
        fees.depositLobby{value: 1}();
        vm.expectRevert(Unauthorized.selector);
        fees.depositSellTax{value: 1}();
        vm.expectRevert(Unauthorized.selector);
        fees.depositLaunchTax{value: 1}();
        vm.expectRevert(Unauthorized.selector);
        fees.routeTokens(1);
        vm.expectRevert(Unauthorized.selector);
        fees.zapBuy{value: 1 ether}(1, address(l3));
        vm.expectRevert(Unauthorized.selector);
        fees.payBounty(actors[0]);
        vm.expectRevert(Unauthorized.selector);
        fees.payWork(actors[0], Params.Key.SeasonBounty, 1, 100_000);
        assertEq(address(fees).balance, 0);
        assertEq(fees.rewardETH(), 0);
        assertEq(fees.credit(actors[0]), 0);
    }

    function test_feeMeasuredBuyOutputRollsBackShortFillAndCadence() public {
        fees.depositBaseFee{value: 1 ether}();
        uint256 quote = exchange.quote(0.5 ether);
        uint256 minimum = quote * 9850 / 10000;
        exchange.setFill(9800);
        vm.expectRevert(InsufficientBalance.selector);
        fees.executeBuys(0.5 ether, minimum);
        assertEq(address(fees).balance, 1 ether);
        assertEq(fees.rewardETH(), 1 ether);
        assertEq(fees.lastBuy(), 0);
        assertEq(asset.balanceOf(address(pool)), 0);
        assertEq(pool.otherInflow(), 0);
        exchange.setFill(10000);
        assertEq(fees.executeBuys(0.5 ether, minimum), quote);
        assertEq(pool.otherInflow(), quote);
        vm.expectRevert(TooEarly.selector);
        fees.executeBuys(0.5 ether, minimum);
    }

    function test_feePotBuyFailureDoesNotDebitPotOrCreateSeasonLiability() public {
        _enable(6);
        _sellTax(1 ether);
        exchange.setFill(9800);
        uint256 minimum = exchange.quote(0.5 ether) * 9850 / 10000;
        vm.expectRevert(InsufficientBalance.selector);
        fees.executePotBuys(0.5 ether, minimum);
        assertEq(fees.potETH(), 0.5 ether);
        assertEq(fees.lastBuy(), 0);
        assertEq(season.potLiability(), 0);
        assertEq(asset.balanceOf(address(season)), 0);
        exchange.setFill(10000);
        fees.executePotBuys(0.5 ether, minimum);
        assertEq(fees.potETH(), 0);
        assertEq(season.potLiability(), asset.balanceOf(address(season)));
    }

    function test_feeFailedSellRestoresQueueApprovalAndSweepForRetry() public {
        _route(10_000 ether);
        _sellTax(50 ether); // Fill heartbeat cap after tokens have already queued.
        uint256 teamBefore = fees.teamTokens();
        uint256 heartbeatBefore = fees.heartbeatTokens();
        uint256 poolBefore = asset.balanceOf(address(pool));
        uint256 inflowBefore = pool.otherInflow();
        (, uint256 minimum) = fees.sellBatchQuote();
        exchange.setFailure(true);
        vm.expectRevert("market failure");
        fees.executeSells(type(uint256).max, minimum);
        assertEq(fees.teamTokens(), teamBefore);
        assertEq(fees.heartbeatTokens(), heartbeatBefore);
        assertEq(asset.balanceOf(address(pool)), poolBefore);
        assertEq(pool.otherInflow(), inflowBefore);
        assertEq(fees.lastSell(), 0);
        assertEq(asset.allowance(address(fees), address(exchange)), 0);
        exchange.setFailure(false);
        fees.executeSells(1, minimum);
        assertEq(fees.heartbeatTokens(), 0);
        assertEq(asset.balanceOf(address(pool)) - poolBefore, heartbeatBefore);
    }

    function test_feeRejectedRecipientCanRetryWithoutBlockingAnotherPayeeOrReentering() public {
        _sellTax(1 ether);
        L4FeeRecipient recipient = new L4FeeRecipient(fees);
        vm.prank(address(l3));
        fees.payBounty(address(recipient));
        uint256 due = fees.credit(address(recipient));
        assertGt(due, 0);
        vm.expectRevert(TransferFailed.selector);
        recipient.withdraw();
        assertEq(fees.credit(address(recipient)), due);
        vm.prank(fees.team());
        fees.withdraw();
        recipient.accept();
        recipient.withdraw();
        assertFalse(recipient.reentered());
        assertEq(address(recipient).balance, due);
        assertEq(fees.credit(address(recipient)), 0);
    }

    function test_civicNoticeExactBoundaryAndAuthority() public {
        vm.expectRevert(Unauthorized.selector);
        civic.announce(4, "notice");
        vm.prank(governor);
        civic.announce(4, "notice");
        uint256 deadline = civic.noticeAt(4);
        vm.warp(deadline - 1);
        vm.expectRevert(TooEarly.selector);
        civic.enable(4);
        vm.expectRevert(FeatureDisabled.selector);
        economy.lock(15000 ether, 7);
        vm.warp(deadline);
        civic.enable(4);
        assertTrue(civic.enabled(4));
        vm.expectRevert(TooEarly.selector);
        civic.enable(4);
        vm.prank(governor);
        vm.expectRevert(InvalidValue.selector);
        civic.announce(4, "second notice");
    }

    function test_civicFailedWarDepositAndClaimRollback() public {
        _enable(0);
        vm.prank(governor);
        civic.startWar(0, 1);
        address p = actors[0];
        asset.setFail(true);
        vm.prank(p);
        vm.expectRevert("test transfer failure");
        civic.fundWar(1000 ether);
        assertEq(civic.escrow(), 0);
        assertEq(civic.contribution(1, p), 0);
        asset.setFail(false);
        vm.prank(p);
        civic.fundWar(1000 ether);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        civic.finishWar();
        asset.setFail(true);
        vm.prank(p);
        vm.expectRevert("test transfer failure");
        civic.claimWar(1);
        assertFalse(civic.warClaimed(1, p));
        assertEq(civic.escrow(), 1000 ether);
        asset.setFail(false);
        vm.prank(p);
        assertEq(civic.claimWar(1), 1000 ether);
        assertEq(asset.balanceOf(p), ACTOR_FUNDS);
    }

    function test_civicCollapseZeroFundingAndPoolFailureCannotCountContribution() public {
        _enable(1);
        vm.prank(governor);
        civic.startCollapse(3000 ether);
        vm.prank(actors[0]);
        vm.expectRevert(InvalidValue.selector);
        civic.fundCollapse(0);
        // Let the inbound transfer complete, then fail the transfer from Civic to RewardPool.
        asset.setCallback(address(asset), abi.encodeWithSignature("setFail(bool)", true));
        vm.prank(actors[0]);
        vm.expectRevert("test transfer failure");
        civic.fundCollapse(3000 ether);
        assertEq(civic.collapseRaised(), 0);
        assertEq(civic.escrow(), 0);
        assertEq(asset.balanceOf(actors[0]), ACTOR_FUNDS);
        assertEq(asset.allowance(address(civic), address(pool)), 0);
        assertFalse(asset.failTransfers(), "callback state also rolls back");
        asset.setCallback(address(0), "");
        vm.prank(actors[0]);
        civic.fundCollapse(3000 ether);
        assertEq(asset.balanceOf(address(pool)), 3000 ether);
        assertEq(civic.escrow(), 0);
        vm.warp(civic.collapseEnd());
        vm.prank(actors[1]);
        vm.expectRevert(TooEarly.selector);
        civic.fundCollapse(1);
        civic.finishCollapse();
        vm.expectRevert(Unauthorized.selector);
        civic.consumeCityEvent();
        vm.prank(registry.module(7));
        assertEq(civic.consumeCityEvent(), 1);
    }
}
