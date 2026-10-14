// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {L4Fixture, L4Dependencies} from "./L4Fixture.sol";
import {Test} from "forge-std/Test.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {Billboards} from "src/Billboards.sol";
import {Civic} from "src/Civic.sol";
import {Economy} from "src/Economy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "src/lib/Errors.sol";

contract L4BillboardHandler is Test {
    struct Key {
        uint256 week;
        uint256 district;
    }
    Billboards public immutable boards;
    MockToken public immutable token;
    address public immutable pool;
    address[] public actors;
    Key[] public keys;
    mapping(address => uint256) public paid;
    mapping(address => uint256) public returned;
    mapping(address => uint256) public owed;
    uint256 public deposits;
    uint256 public refunds;
    uint256 public donated;
    uint256 public poolPaid;

    constructor(Billboards b, MockToken t, address p, address[] memory a) {
        boards = b;
        token = t;
        pool = p;
        actors = a;
    }

    function bid(uint256 who, uint256 district, uint256 extra) public {
        address p = actors[who % actors.length];
        district %= 8;
        uint256 week = boards.week() + 1;
        Billboards.Billboard memory previous = boards.billboard(week, district);
        uint256 minimum = Math.max(750 ether, previous.bid + previous.bid / 20 + 1);
        uint256 balance = token.balanceOf(p);
        if (balance < minimum) return;
        uint256 amount = minimum + bound(extra, 0, Math.min(10_000 ether, balance - minimum));
        vm.prank(p);
        boards.bidBillboard(district, amount, "L4 TEST", "L4_test");
        if (previous.bid == 0) keys.push(Key(week, district));
        else owed[previous.bidder] += previous.bid;
        paid[p] += amount;
        deposits += amount;
        assertEq(token.balanceOf(p), balance - amount, "bid debited exactly once");
    }

    function withdraw(uint256 who) public {
        address p = actors[who % actors.length];
        uint256 amount = owed[p];
        if (amount == 0) {
            vm.prank(p);
            vm.expectRevert(InsufficientBalance.selector);
            boards.withdrawRefund();
            return;
        }
        uint256 before_ = token.balanceOf(p);
        vm.prank(p);
        boards.withdrawRefund();
        owed[p] = 0;
        returned[p] += amount;
        refunds += amount;
        assertEq(token.balanceOf(p) - before_, amount, "refund belongs to outbid actor");
    }

    function settle(uint256 which) public {
        if (keys.length == 0) return;
        Key memory key = keys[which % keys.length];
        Billboards.Billboard memory board = boards.billboard(key.week, key.district);
        if (board.settled) {
            vm.expectRevert(InvalidValue.selector);
            boards.settleBillboard(key.week, key.district);
        } else if (key.week > boards.week()) {
            vm.expectRevert(TooEarly.selector);
            boards.settleBillboard(key.week, key.district);
        } else {
            uint256 before_ = token.balanceOf(pool);
            boards.settleBillboard(key.week, key.district);
            assertEq(token.balanceOf(pool) - before_, board.bid);
            poolPaid += board.bid;
        }
    }

    function elapse(uint256 seconds_) public {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1, 8 days));
    }

    function donate(uint256 who, uint256 amount) public {
        address p = actors[who % actors.length];
        uint256 balance = token.balanceOf(p);
        if (balance == 0) return;
        amount = bound(amount, 1, Math.min(balance, 100 ether));
        vm.prank(p);
        token.transfer(address(boards), amount);
        donated += amount;
        paid[p] += amount;
    }

    function check() public view {
        uint256 liability;
        for (uint256 i; i < actors.length; ++i) {
            address p = actors[i];
            assertEq(boards.refund(p), owed[p], "independent refund ledger");
            assertEq(token.balanceOf(p) + paid[p], 1_000_000 ether + returned[p]);
            liability += owed[p];
        }
        for (uint256 i; i < keys.length; ++i) {
            Billboards.Billboard memory b = boards.billboard(keys[i].week, keys[i].district);
            if (!b.settled) liability += b.bid;
        }
        assertEq(boards.escrow(), liability, "live bids plus pull refunds");
        assertEq(deposits, refunds + poolPaid + liability, "no value created or lost");
        assertEq(token.balanceOf(address(boards)), liability + donated);
        assertEq(token.balanceOf(pool), poolPaid);
        assertEq(token.allowance(address(boards), pool), 0, "donation allowance cleared");
    }

    function closeAll() external {
        vm.warp(vm.getBlockTimestamp() + 8 days);
        for (uint256 i; i < keys.length; ++i) {
            settle(i);
        }
        for (uint256 i; i < actors.length; ++i) {
            withdraw(i);
        }
        check();
        assertEq(boards.escrow(), 0, "all obligations can be discharged");
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract L4BillboardInvariantTest is L4Fixture {
    L4BillboardHandler internal handler;

    function setUp() public override {
        super.setUp();
        _enable(5);
        handler = new L4BillboardHandler(boards, asset, address(pool), actors);
        // Every run starts with real competing bids and an outstanding refund.
        handler.bid(0, 0, 0);
        handler.bid(1, 0, 0);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.bid.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.settle.selector;
        selectors[3] = handler.elapse.selector;
        selectors[4] = handler.donate.selector;
        _target(address(handler), selectors);
    }

    function invariant_billboardFundsBackEveryBidAndRefund() public view {
        handler.check();
    }

    function afterInvariant() public {
        handler.closeAll();
    }
}

contract L4CivicHandler is Test {
    Civic public immutable civic;
    MockToken public immutable token;
    address public immutable pool;
    address public immutable governor;
    address[] public actors;
    mapping(uint256 => uint256) public funded;
    mapping(uint256 => uint256) public claimed;
    mapping(uint256 => uint256) public poolByWar;
    mapping(uint256 => mapping(address => uint256)) public contributions;
    mapping(address => uint256) public spent;
    mapping(address => uint256) public received;
    uint256 public deposits;
    uint256 public payouts;
    uint256 public poolPaid;

    constructor(Civic c, MockToken t, address p, address g, address[] memory a) {
        civic = c;
        token = t;
        pool = p;
        governor = g;
        actors = a;
    }

    function war(uint256 id) public view returns (Civic.War memory w) {
        (bool ok, bytes memory result) = address(civic).staticcall(abi.encodeWithSignature("wars(uint256)", id));
        require(ok);
        w = abi.decode(result, (Civic.War));
    }

    function start(bool reverse) public {
        uint256 id = civic.warId();
        if (id != 0 && !war(id).settled) {
            vm.prank(governor);
            vm.expectRevert(InvalidValue.selector);
            civic.startWar(0, 1);
            return;
        }
        vm.prank(governor);
        civic.startWar(reverse ? 1 : 0, reverse ? 0 : 1);
    }

    function fund(uint256 who, uint256 amount) public {
        uint256 id = civic.warId();
        Civic.War memory w = war(id);
        if (id == 0 || w.settled || block.timestamp >= w.end) return;
        address p = actors[who % actors.length];
        uint256 balance = token.balanceOf(p);
        if (balance == 0) return;
        amount = bound(amount, 1, Math.min(balance, 50_000 ether));
        vm.prank(p);
        civic.fundWar(amount);
        deposits += amount;
        funded[id] += amount;
        contributions[id][p] += amount;
        spent[p] += amount;
        assertEq(token.balanceOf(p), balance - amount);
    }

    function finish() public {
        uint256 id = civic.warId();
        Civic.War memory w = war(id);
        if (id == 0 || w.settled || block.timestamp < w.end) {
            vm.expectRevert(TooEarly.selector);
            civic.finishWar();
            return;
        }
        uint256 before_ = token.balanceOf(pool);
        civic.finishWar();
        uint256 amount = token.balanceOf(pool) - before_;
        poolByWar[id] = amount;
        poolPaid += amount;
    }

    function claim(uint256 which, uint256 who) public {
        uint256 count = civic.warId();
        if (count == 0) return;
        uint256 id = bound(which, 1, count);
        address p = actors[who % actors.length];
        Civic.War memory w = war(id);
        uint256 contribution = contributions[id][p];
        bool eligible = w.settled && !civic.warClaimed(id, p) && civic.district(p) == w.winner && contribution != 0;
        if (!eligible) {
            vm.prank(p);
            vm.expectRevert(InvalidValue.selector);
            civic.claimWar(id);
            return;
        }
        uint256 before_ = token.balanceOf(p);
        vm.prank(p);
        uint256 amount = civic.claimWar(id);
        assertEq(token.balanceOf(p) - before_, amount);
        assertEq(amount, Math.mulDiv(w.payout, contribution, w.winningChest), "proportional entitlement");
        payouts += amount;
        claimed[id] += amount;
        received[p] += amount;
    }

    function elapse(uint256 seconds_) public {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1, 3 days));
    }

    function check() public view {
        uint256 liabilities;
        for (uint256 id = 1; id <= civic.warId(); ++id) {
            Civic.War memory w = war(id);
            assertEq(w.chestA + w.chestB, funded[id]);
            uint256 a;
            uint256 b;
            for (uint256 i; i < actors.length; ++i) {
                uint256 contribution = contributions[id][actors[i]];
                assertEq(civic.contribution(id, actors[i]), contribution, "contribution credited to its payer");
                if (civic.district(actors[i]) == w.a) a += Math.min(contribution, w.chestA / 10);
                else b += Math.min(contribution, w.chestB / 10);
            }
            // Independent sum over every actor checks the optimized top-ten accounting.
            assertEq(civic.warScore(id, w.a), a * 10000 / civic.warRate(id));
            assertEq(civic.warScore(id, w.b), b * 10000 / civic.warRate(id));
            if (w.settled) {
                assertEq(w.winner, a * 10000 / civic.warRate(id) >= b * 10000 / civic.warRate(id) ? w.a : w.b);
                assertLe(claimed[id], w.payout);
                assertEq(w.payout + poolByWar[id], funded[id]);
                liabilities += w.payout - claimed[id];
            } else {
                liabilities += funded[id];
            }
        }
        assertEq(civic.escrow(), liabilities);
        assertEq(token.balanceOf(address(civic)), liabilities);
        assertEq(deposits, payouts + poolPaid + liabilities);
        assertEq(token.balanceOf(pool), poolPaid);
        assertEq(token.allowance(address(civic), pool), 0);
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]) + spent[actors[i]], 1_000_000 ether + received[actors[i]]);
        }
    }

    function closeAll() external {
        uint256 count = civic.warId();
        if (count != 0 && !war(count).settled) {
            vm.warp(Math.max(vm.getBlockTimestamp(), war(count).end));
            finish();
        }
        for (uint256 id = 1; id <= count; ++id) {
            for (uint256 i; i < actors.length; ++i) {
                claim(id, i);
            }
            // Accepted integer-division dust is less than one wei per eligible claimant.
            assertLt(war(id).payout - claimed[id], actors.length);
        }
        check();
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract L4CivicInvariantTest is L4Fixture {
    L4CivicHandler internal handler;

    function setUp() public override {
        super.setUp();
        _enable(0);
        handler = new L4CivicHandler(civic, asset, address(pool), governor, actors);
        handler.start(false);
        for (uint256 i; i < actors.length; ++i) {
            handler.fund(i, 1000 ether + i);
        }
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.start.selector;
        selectors[1] = handler.fund.selector;
        selectors[2] = handler.finish.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.elapse.selector;
        _target(address(handler), selectors);
    }

    function invariant_warEscrowAndCappedScores() public view {
        handler.check();
    }

    function afterInvariant() public {
        handler.closeAll();
    }
}

contract L4EconomyHandler is Test {
    Economy public immutable economy;
    MockToken public immutable token;
    L4Dependencies public immutable l3;
    address[] public actors;
    mapping(address => uint256) public principal;
    mapping(address => uint256) public deposited;
    mapping(address => uint256) public returned;

    constructor(Economy e, MockToken t, L4Dependencies dependencies, address[] memory a) {
        economy = e;
        token = t;
        l3 = dependencies;
        actors = a;
    }

    function lock(uint256 who, uint256 amount, uint256 term) public {
        address p = actors[who % actors.length];
        if (!l3.live() || principal[p] != 0) return;
        uint256 days_ = term % 3 == 0 ? 7 : term % 3 == 1 ? 14 : 30;
        (uint256 minimum,) = economy.lockQuote(p, days_);
        uint256 balance = token.balanceOf(p);
        if (balance < minimum) return;
        amount = bound(amount, minimum, Math.min(balance, 200_000 ether));
        vm.prank(p);
        economy.lock(amount, days_);
        principal[p] = amount;
        deposited[p] += amount;
    }

    function unlock(uint256 who) public {
        address p = actors[who % actors.length];
        (uint256 amount,, uint64 end,) = economy.locks(p);
        if (amount == 0 || block.timestamp < end) {
            vm.prank(p);
            vm.expectRevert(TooEarly.selector);
            economy.unlock();
            return;
        }
        vm.prank(p);
        economy.unlock();
        assertEq(amount, principal[p]);
        principal[p] = 0;
        returned[p] += amount;
        assertEq(economy.next(p), address(0));
        assertEq(economy.previous(p), address(0));
    }

    function elapse(uint256 seconds_, bool live) public {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1, 31 days));
        l3.setLive(live);
    }

    function check() public view {
        uint256 total;
        uint256[8] memory totals;
        uint256[8] memory counts;
        for (uint256 i; i < actors.length; ++i) {
            address p = actors[i];
            (uint256 amount,, uint64 end,) = economy.locks(p);
            assertEq(amount, principal[p]);
            assertEq(deposited[p], returned[p] + amount);
            assertEq(token.balanceOf(p) + amount, 1_000_000 ether, "principal roundtrip cannot create value");
            if (block.timestamp >= end) assertEq(economy.boostAt(p, block.timestamp), 0);
            uint256 district = economy.district(p);
            total += amount;
            totals[district] += amount;
            if (amount != 0) ++counts[district];
        }
        assertEq(total, economy.totalLocked());
        assertEq(token.balanceOf(address(economy)), total);
        for (uint256 district; district < 8; ++district) {
            assertEq(economy.districtTotal(district), totals[district]);
            uint256 capped;
            for (uint256 i; i < actors.length; ++i) {
                if (economy.district(actors[i]) == district) {
                    capped += Math.min(principal[actors[i]], totals[district] / 10);
                }
            }
            assertEq(economy.districtStake(district), capped);
            address cursor = economy.head(district);
            address previous;
            uint256 previousAmount = type(uint256).max;
            uint256 visited;
            while (cursor != address(0)) {
                assertLt(visited, actors.length, "linked-list cycle");
                assertEq(economy.previous(cursor), previous);
                assertEq(economy.district(cursor), district);
                assertGt(principal[cursor], 0);
                assertLe(principal[cursor], previousAmount, "descending escrow order");
                previousAmount = principal[cursor];
                previous = cursor;
                cursor = economy.next(cursor);
                ++visited;
            }
            assertEq(visited, counts[district], "every lock appears exactly once");
        }
    }

    function closeAll() external {
        vm.warp(vm.getBlockTimestamp() + 31 days);
        l3.setLive(false);
        for (uint256 i; i < actors.length; ++i) {
            unlock(i);
        }
        check();
        assertEq(economy.totalLocked(), 0, "withdrawal liveness while rewards are stopped");
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract L4EconomyInvariantTest is L4Fixture {
    L4EconomyHandler internal handler;

    function setUp() public override {
        super.setUp();
        _enable(4);
        handler = new L4EconomyHandler(economy, asset, l3, actors);
        for (uint256 i; i < actors.length; ++i) {
            handler.lock(i, 60_000 ether + i, i);
        }
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.lock.selector;
        selectors[1] = handler.unlock.selector;
        selectors[2] = handler.elapse.selector;
        _target(address(handler), selectors);
    }

    function invariant_lockPrincipalListsAndDistrictCaps() public view {
        handler.check();
    }

    function afterInvariant() public {
        handler.closeAll();
    }
}
