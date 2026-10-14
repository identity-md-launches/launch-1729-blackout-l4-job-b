// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {L4Fixture, L4Dependencies} from "./L4Fixture.sol";
import {Test} from "forge-std/Test.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {FeeRouter} from "src/FeeRouter.sol";
import {Season} from "src/Season.sol";
import {Params} from "src/Params.sol";
import {RewardPool} from "src/RewardPool.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "src/lib/Errors.sol";

contract L4FeeHandler is Test {
    FeeRouter public immutable fees;
    Season public immutable season;
    MockToken public immutable token;
    MockMarket public immutable market;
    address public immutable pool;
    address public immutable producer;
    address[] public actors;
    uint256 public ethIn;
    uint256 public ethBought;
    uint256 public ethSold;
    uint256 public ethWithdrawn;
    uint256 public tokensIn;
    uint256 public tokensSold;
    uint256 public tokensRouted;
    uint256 public poolBuys;
    uint256 public potBuys;

    constructor(FeeRouter f, Season s, MockToken t, MockMarket m, address p, address l3, address[] memory a) {
        fees = f;
        season = s;
        token = t;
        market = m;
        pool = p;
        producer = l3;
        actors = a;
    }

    function deposit(uint256 stream, uint256 amount) public {
        amount = bound(amount, 1, 5 ether);
        if (stream % 3 == 0) {
            fees.depositBaseFee{value: amount}();
        } else {
            vm.deal(address(market), address(market).balance + amount);
            vm.prank(address(market));
            if (stream % 3 == 1) fees.depositSellTax{value: amount}();
            else fees.depositLaunchTax{value: amount}();
        }
        ethIn += amount;
    }

    function route(uint256 amount) public {
        amount = bound(amount, 1, 10_000 ether);
        uint256 balance = token.balanceOf(address(this));
        if (balance < amount) return;
        uint256 before_ = token.balanceOf(pool);
        token.transfer(address(fees), amount);
        vm.prank(producer);
        fees.routeTokens(amount);
        tokensIn += amount;
        tokensRouted += token.balanceOf(pool) - before_;
    }

    function buy(bool pot, uint256 amount, uint256 who) public {
        uint256 available = pot ? fees.potETH() : fees.rewardETH();
        if (available == 0) return;
        amount = bound(amount, Math.min(available, 0.05 ether), Math.min(available, 0.5 ether));
        uint256 minimum = market.quote(amount) * 9850 / 10000;
        if (minimum == 0) return;
        address recipient = pot ? address(season) : pool;
        uint256 before_ = token.balanceOf(recipient);
        uint256 last = fees.lastBuy();
        vm.prank(actors[who % actors.length]);
        if (last != 0 && block.timestamp < last + 5 minutes) {
            vm.expectRevert(TooEarly.selector);
            if (pot) fees.executePotBuys(amount, minimum);
            else fees.executeBuys(amount, minimum);
            return;
        }
        uint256 received = pot ? fees.executePotBuys(amount, minimum) : fees.executeBuys(amount, minimum);
        assertEq(received, token.balanceOf(recipient) - before_);
        assertGe(received, minimum);
        ethBought += amount;
        if (pot) potBuys += received;
        else poolBuys += received;
    }

    function sell() public {
        (uint256 amount, uint256 minimum) = fees.sellBatchQuote();
        if (amount == 0 || minimum == 0) return;
        uint256 last = fees.lastSell();
        if (last != 0 && block.timestamp < last + 5 minutes) {
            vm.expectRevert(TooEarly.selector);
            fees.executeSells(1, minimum);
            return;
        }
        uint256 poolBefore = token.balanceOf(pool);
        uint256 marketBefore = token.balanceOf(address(market));
        uint256 balanceBefore = address(fees).balance;
        uint256 received = fees.executeSells(1, minimum);
        assertEq(token.balanceOf(address(market)) - marketBefore, amount, "entire safe batch sold");
        assertEq(address(fees).balance - balanceBefore, received);
        tokensRouted += token.balanceOf(pool) - poolBefore;
        tokensSold += amount;
        ethSold += received;
    }

    function bounty(uint256 who) public {
        vm.prank(producer);
        fees.payBounty(actors[who % actors.length]);
    }

    function withdraw(uint256 who) public {
        address p = who % (actors.length + 1) == actors.length ? fees.team() : actors[who % (actors.length + 1)];
        uint256 amount = fees.credit(p);
        uint256 before_ = p.balance;
        vm.prank(p);
        if (amount == 0) {
            vm.expectRevert(InsufficientBalance.selector);
            fees.withdraw();
        } else {
            fees.withdraw();
            assertEq(p.balance - before_, amount);
            ethWithdrawn += amount;
        }
    }

    function elapse(uint256 seconds_) public {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1, 1 hours));
    }

    function check() public view {
        uint256 credits = fees.credit(fees.team());
        for (uint256 i; i < actors.length; ++i) {
            credits += fees.credit(actors[i]);
        }
        assertEq(address(fees).balance, fees.rewardETH() + fees.potETH() + fees.heartbeatBalance() + credits);
        assertEq(ethIn + ethSold, address(fees).balance + ethBought + ethWithdrawn);
        assertLe(fees.heartbeatBalance(), fees.HEARTBEAT_CAP());
        assertEq(token.balanceOf(address(fees)), fees.teamTokens() + fees.heartbeatTokens());
        assertEq(tokensIn, token.balanceOf(address(fees)) + tokensSold + tokensRouted);
        assertEq(token.balanceOf(pool), tokensRouted + poolBuys);
        assertEq(
            RewardPool(pool).otherInflow(), tokensRouted + poolBuys, "pre-endowment inflows cannot count as principal"
        );
        assertEq(token.balanceOf(address(season)), potBuys);
        assertEq(season.potLiability(), potBuys);
        assertEq(token.allowance(address(fees), address(market)), 0, "sell allowance revoked");
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract L4FeeInvariantTest is L4Fixture {
    L4FeeHandler internal handler;

    function setUp() public override {
        super.setUp();
        _enable(6);
        handler = new L4FeeHandler(fees, season, asset, exchange, address(pool), address(l3), actors);
        asset.transfer(address(handler), 10_000_000 ether);
        vm.deal(address(handler), 10_000 ether);
        handler.deposit(1, 5 ether);
        handler.route(10_000 ether);
        // Guarantee both conversion directions are exercised before random sequencing.
        handler.sell();
        handler.buy(false, 0.5 ether, 0);
        handler.elapse(5 minutes);
        handler.buy(true, 0.5 ether, 1);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.route.selector;
        selectors[2] = handler.buy.selector;
        selectors[3] = handler.sell.selector;
        selectors[4] = handler.bounty.selector;
        selectors[5] = handler.withdraw.selector;
        selectors[6] = handler.elapse.selector;
        _target(address(handler), selectors);
    }

    function invariant_feeEtherAndTokensConservedAcrossConversions() public view {
        handler.check();
    }

    function afterInvariant() public {
        for (uint256 i; i <= actors.length; ++i) {
            handler.withdraw(i);
        }
        handler.check();
        assertEq(fees.credit(fees.team()), 0);
        for (uint256 i; i < actors.length; ++i) {
            assertEq(fees.credit(actors[i]), 0);
        }
    }
}

contract L4SeasonHandler is Test {
    Season public immutable season;
    MockToken public immutable token;
    address public immutable fees;
    address[] public actors;
    uint256 public deposits;
    uint256 public paid;
    uint256 public maxWeek;
    mapping(address => uint256) public received;
    mapping(uint256 => uint256) public paidByWeek;

    constructor(Season s, MockToken t, address f, address[] memory a) {
        season = s;
        token = t;
        fees = f;
        actors = a;
    }

    function fund(uint256 amount) public {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        amount = bound(amount, 1, Math.min(balance, 10_000 ether));
        uint256 w = (block.timestamp - season.launchTime()) / 7 days;
        maxWeek = Math.max(w, maxWeek);
        token.transfer(address(season), amount);
        vm.prank(fees);
        season.depositPot(amount);
        deposits += amount;
    }

    function claim(uint256 who, uint256 kind) public {
        // Week zero has 16 genuine score entries, three lottery winners and one best farmer.
        address p = actors[who % actors.length];
        (, uint8 district, address best,,) = season.result(0);
        bool eligible;
        if (kind % 3 == 0) eligible = p == best && !season.bestClaimed(0);
        else if (kind % 3 == 1) eligible = season.lotteryWon(0, p) && !season.lotteryClaimed(0, p);
        else eligible = uint256(keccak256(abi.encodePacked(p))) % 8 == district && !season.districtClaimed(0, p);
        bytes memory data = kind % 3 == 0
            ? abi.encodeCall(Season.claimBest, (0))
            : kind % 3 == 1 ? abi.encodeCall(Season.claimLottery, (0)) : abi.encodeCall(Season.claimDistrict, (0));
        uint256 before_ = token.balanceOf(p);
        if (!eligible || season.rolled(0) || block.timestamp >= season.claimDeadline(0)) {
            bytes32 stateBefore = keccak256(
                abi.encode(
                    season.bestClaimed(0),
                    season.lotteryClaimed(0, p),
                    season.districtClaimed(0, p),
                    season.potLiability()
                )
            );
            vm.prank(p);
            (bool ok, bytes memory reason) = address(season).call(data);
            assertFalse(ok);
            assertEq(bytes4(reason), eligible ? TooEarly.selector : InvalidValue.selector);
            assertEq(
                keccak256(
                    abi.encode(
                        season.bestClaimed(0),
                        season.lotteryClaimed(0, p),
                        season.districtClaimed(0, p),
                        season.potLiability()
                    )
                ),
                stateBefore
            );
        } else {
            vm.prank(p);
            (bool ok, bytes memory reason) = address(season).call(data);
            assertTrue(ok, string(reason));
            uint256 amount = token.balanceOf(p) - before_;
            paid += amount;
            paidByWeek[0] += amount;
            received[p] += amount;
        }
    }

    function rollover() public {
        if (season.rolled(0) || block.timestamp < season.claimDeadline(0)) {
            vm.expectRevert(TooEarly.selector);
            season.rollover(0);
            return;
        }
        uint256 current = (block.timestamp - season.launchTime()) / 7 days;
        maxWeek = Math.max(current, maxWeek);
        uint256 remaining = season.potRemaining(0);
        uint256 before_ = season.potRemaining(current);
        uint256 liability = season.potLiability();
        season.rollover(0);
        assertEq(season.potRemaining(0), 0);
        assertEq(season.potRemaining(current), before_ + remaining);
        assertEq(season.potLiability(), liability, "rollover moves obligations, not tokens");
    }

    function elapse(uint256 seconds_) public {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1, 5 days));
    }

    function check() public view {
        uint256 liability;
        for (uint256 w; w <= maxWeek; ++w) {
            liability += season.potRemaining(w);
        }
        assertEq(season.potLiability(), liability);
        assertEq(token.balanceOf(address(season)), liability);
        assertEq(deposits, paid + liability);
        assertLe(paidByWeek[0], season.pot(0), "claims never exceed original weekly pot");
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), 1_000_000 ether + received[actors[i]]);
        }
        if (season.rolled(0)) assertEq(season.potRemaining(0), 0);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract L4SeasonInvariantTest is L4Fixture {
    L4SeasonHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new L4SeasonHandler(season, asset, address(fees), actors);
        asset.transfer(address(handler), 1_000_000 ether);
        handler.fund(9999 ether + 7);
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(address(l3));
            season.recordSpend(actors[i], (i + 1) * 100 ether, true);
            for (uint256 e; e < 20; ++e) {
                vm.prank(address(l3));
                season.recordActivity(actors[i], 0, 0, 1000 + i);
            }
        }
        vm.warp(launch + 7 days);
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(address(l3));
            season.complete(actors[i], 0);
        }
        vm.warp(season.deadline(0));
        season.prepare(0, 64);
        uint256 target = vm.getBlockNumber() + 2;
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("L4 week zero entropy"));
        season.finalize(0);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.claim.selector;
        selectors[2] = handler.rollover.selector;
        selectors[3] = handler.elapse.selector;
        _target(address(handler), selectors);
    }

    function invariant_seasonPotClaimsAndRolloverRemainBacked() public view {
        handler.check();
    }
}
