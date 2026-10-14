// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../Base.t.sol";
import {FarmEngine} from "src/FarmEngine.sol";
import {GridOperator} from "src/GridOperator.sol";
import "src/lib/Errors.sol";

/// @dev These tests use the existing full, pinned deployment graph, including real L3 callbacks.
contract L4GameplayEdgesTest is BaseTest {
    function _nativeBlock(uint256 number) private {
        vm.mockCall(address(100), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(number));
    }

    function test_gridRobinhoodNativeBlockBoundaryAndResolutionIdempotence() public {
        vm.chainId(4663);
        _nativeBlock(9000);
        vm.prank(swarm);
        d.grid.submitPlan(2, GridOperator.Kind.Calm, 6000, keccak256("native plan"), "L2 plan");
        vm.prank(address(d.rewards));
        d.grid.shift(2);
        assertEq(d.grid.eventTarget(2), 9001);
        // An advanced block.number estimate cannot make a native L2 target available.
        vm.roll(100_000);
        _nativeBlock(9001);
        vm.expectRevert(TooEarly.selector);
        d.grid.resolve(2);
        bytes32 h = keccak256("last retrievable native block");
        vm.mockCall(address(100), abi.encodeWithSignature("arbBlockHash(uint256)", uint256(9001)), abi.encode(h));
        _nativeBlock(9257); // Exactly 256 native blocks later is still usable.
        assertTrue(d.grid.resolve(2));
        (GridOperator.Kind kind, uint16 severity, uint8 district, bytes32 seed, bool resolved) = d.grid.eventAt(2);
        assertTrue(resolved);
        assertEq(uint256(kind), uint256(GridOperator.Kind.Calm));
        assertEq(severity, 6000);
        assertLt(district, 8);
        assertEq(seed, keccak256(abi.encode(keccak256("native plan"), h, address(d.grid), uint256(2))));
        uint256 bounty = d.fees.credit(address(this));
        _nativeBlock(9999);
        assertTrue(d.grid.resolve(2));
        (,,, bytes32 afterSeed, bool afterResolved) = d.grid.eventAt(2);
        assertEq(afterSeed, seed);
        assertTrue(afterResolved);
        assertEq(d.fees.credit(address(this)), bounty, "resolved event cannot pay again");
    }

    function test_gridUnauthorizedMutatorsAndPlanLetterBoundaries() public {
        vm.expectRevert(Unauthorized.selector);
        d.grid.shift(2);
        vm.expectRevert(Unauthorized.selector);
        d.grid.resolveFor(1, alice);
        vm.expectRevert(Unauthorized.selector);
        d.grid.tokenLobby(alice, 1);
        vm.expectRevert(InvalidValue.selector);
        d.grid.lobbyETH{value: 1}();
        vm.startPrank(swarm);
        vm.expectRevert(InvalidValue.selector);
        d.grid.submitPlan(2, GridOperator.Kind.Calm, 6000, bytes32(0), "");
        vm.expectRevert(InvalidValue.selector);
        d.grid.submitPlan(2, GridOperator.Kind.Calm, 2999, bytes32(0), "below floor");
        vm.expectRevert(InvalidValue.selector);
        d.grid.submitPlan(2, GridOperator.Kind.Calm, 6000, bytes32(0), string(new bytes(1025)));
        assertFalse(d.grid.planAt(2).submitted);
        d.grid.submitPlan(2, GridOperator.Kind.Calm, 3000, keccak256("bounded plan"), string(new bytes(1024)));
        vm.expectRevert(AlreadyDone.selector);
        d.grid.submitPlan(2, GridOperator.Kind.Outage, 10000, bytes32(0), "overwrite");
        vm.stopPrank();
        GridOperator.Plan memory plan = d.grid.planAt(2);
        assertEq(plan.severity, 3000);
        assertEq(bytes(plan.letter).length, 1024);
        assertEq(plan.number, keccak256("bounded plan"));
    }

    function test_engineUnauthorizedOrUnresolvedProcessingCannotWearItems() public {
        uint256 item = mintItem(alice, 0, 0);
        FarmEngine.Snapshot memory snapshot;
        snapshot.ids[0] = item;
        snapshot.health[0] = 10000;
        vm.expectRevert(Unauthorized.selector);
        d.engine.process(alice, 1, snapshot);
        vm.prank(address(d.farm));
        vm.expectRevert(TooEarly.selector);
        d.engine.process(alice, 1, snapshot);
        assertEq(d.items.data(item).durability, 10000);
        assertEq(d.items.data(item).holder, alice);
        vm.expectRevert(InvalidValue.selector);
        d.engine.stats(snapshot, 4, false, 1);
        vm.expectRevert(InvalidValue.selector);
        d.engine.preview(snapshot.ids, 0, type(uint256).max);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_engineAllocationEnvelopeAndWearMonotonicity(uint256 seed) public {
        FarmEngine.Snapshot memory snapshot;
        // Two full rooms fit in the real inventory without bypassing capacity.
        for (uint256 i; i < 12; ++i) {
            uint256 random = uint256(keccak256(abi.encode(seed, i)));
            uint256 item = mintItem(alice, uint8(random % 12), uint8((random >> 8) % 5));
            uint8 clock = uint8((random >> 16) % 17);
            uint16 health = uint16((random >> 24) % 10001);
            vm.prank(address(d.farm));
            d.items.maintain(item, health, clock);
            snapshot.ids[i] = item;
            snapshot.clocks[i] = clock;
            snapshot.health[i] = health;
        }
        snapshot.theftUntil = seed % 2 == 0 ? 3 : 0;
        snapshot.routerRepairBps = uint16((seed >> 8) % 10001);
        uint256 envelope = d.engine.allocationHash(snapshot.ids, true);
        uint256 raw;
        for (uint256 room; room < 4; ++room) {
            FarmEngine.RoomStats memory worn = d.engine.stats(snapshot, room, false, 1);
            assertLe(worn.productive, worn.raw);
            assertLe(worn.power, worn.productive);
            raw += worn.raw;
            // Restoring durability cannot reduce output; allocation is independent of ordinary wear.
            for (uint256 slot; slot < 6; ++slot) {
                snapshot.health[room * 6 + slot] = 10000;
            }
            FarmEngine.RoomStats memory healthy = d.engine.stats(snapshot, room, false, 1);
            assertGe(healthy.productive, worn.productive);
            assertGe(healthy.power, worn.power);
            assertEq(healthy.raw, worn.raw);
        }
        assertLe(raw, envelope, "committed allocation bounds current combo output");
    }

    function test_enhancementFailedPaymentAndBadOwnerDoNotCommitOrCharge() public {
        uint256 item = mintItem(alice, 1, 0);
        uint256 cost = d.economy.enhanceQuote(item);
        uint256 balance = token.balanceOf(alice);
        uint256 poolBalance = token.balanceOf(address(d.pool));
        vm.prank(bob);
        vm.expectRevert(InvalidValue.selector);
        d.enhancement.commit(item, cost, true);
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.enhancement.commit(item, cost - 1, true);
        token.setFail(true);
        vm.prank(alice);
        vm.expectRevert("test transfer failure");
        d.enhancement.commit(item, cost, true);
        assertEq(d.enhancement.pending(item), 0);
        assertEq(d.enhancement.nextId(), 1);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(address(d.pool)), poolBalance);
        token.setFail(false);
        vm.prank(alice);
        uint256 id = d.enhancement.commit(item, cost, true);
        assertEq(d.enhancement.pending(item), id);
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.enhancement.commit(item, type(uint256).max, true);
        assertEq(token.balanceOf(alice), balance - cost);
    }

    function test_enhancementNativeHashWindowAndCapturedSeedSurviveL1ClockChanges() public {
        vm.chainId(4663);
        _nativeBlock(8000);
        uint256 item = mintItem(alice, 0, 0);
        vm.prank(alice);
        uint256 id = d.enhancement.commit(item, type(uint256).max, true);
        (,, uint64 target,,,,) = d.enhancement.attempts(id);
        assertEq(target, 8002);
        vm.roll(1_000_000);
        _nativeBlock(target);
        vm.expectRevert(TooEarly.selector);
        d.enhancement.capture(id);
        _nativeBlock(uint256(target) + 1);
        vm.mockCall(
            address(100), abi.encodeWithSignature("arbBlockHash(uint256)", uint256(target)), abi.encode(bytes32(0))
        );
        vm.expectRevert(NotConfigured.selector);
        d.enhancement.capture(id);
        assertEq(d.enhancement.pending(item), id);
        bytes32 h = keccak256("native enhancement hash");
        vm.mockCall(address(100), abi.encodeWithSignature("arbBlockHash(uint256)", uint256(target)), abi.encode(h));
        _nativeBlock(uint256(target) + 256);
        d.enhancement.capture(id);
        (,,,, bytes32 seed, bool captured, bool resolved) = d.enhancement.attempts(id);
        assertTrue(captured && !resolved);
        assertEq(seed, keccak256(abi.encode(h, address(d.enhancement), id)));
        _nativeBlock(uint256(target) + 500);
        d.enhancement.resolve(id);
        assertEq(d.enhancement.pending(item), 0);
        assertEq(d.items.data(item).overclock, uint256(seed) % 100 < 95 ? 1 : 0);
        vm.expectRevert(InvalidValue.selector);
        d.enhancement.resolve(id);
    }
}
