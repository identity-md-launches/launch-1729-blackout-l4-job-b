// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {GridOperator} from "../src/GridOperator.sol";

/// @notice L4 (job B) import audit 0d49094e, informational, reproduced against the pinned GridOperator and
/// accepted as is (`docs/accepted-v318.md`, "L4 import audit"). `_resolve` replaces a submitted plan's kind with
/// Green/Cheap when fewer than four positive events occurred in the previous 19 epochs, but keeps the plan's
/// submitted severity, so a negative plan at the 3000 floor becomes a positive event at 3000 (a 300 bps output
/// bonus in `FarmEngine`), while an unsubmitted epoch in the same situation resolves positive at 10000 (1000 bps).
/// No source change is possible: every L4 module is pinned in the bound L3 registry, so this test asserts the
/// pinned behaviour and documents the keeper rule (submit forced-positive epochs at a high severity).
contract AuditL4V318Test is BaseTest {
    uint16 private constant FLOOR = 3000;
    uint16 private constant FALLBACK = 10000;

    function _submitOutage(uint256 e) private {
        vm.prank(swarm);
        d.grid.submitPlan(e, GridOperator.Kind.Outage, FLOOR, keccak256(abi.encode("outage", e)), "outage plan");
    }

    function _positive(GridOperator.Kind k) private pure returns (bool) {
        return k == GridOperator.Kind.Green || k == GridOperator.Kind.Cheap;
    }

    /// @notice Audit reproduction. Epoch 1 is the fallback Green of the table; epochs 2-17 and 19-20 carry Outage
    /// plans at the floor; epoch 18 carries no plan. Entering epoch 18 the window [1, 18) holds one positive, so
    /// the override fires: the unsubmitted epoch 18 resolves positive at 10000, and the submitted epochs 19 and 20
    /// (still fewer than four positives in their windows) resolve positive at the submitted 3000.
    function testForcedPositiveKeepsSubmittedSeverityWhileFallbackPositiveIsFull() public {
        assertEq(d.rewards.epoch(), 1);
        for (uint256 e = 2; e <= 21; ++e) {
            if (e != 18) _submitOutage(e);
            step(); // closes e - 1 (resolving its event with the plan) and opens e
            assertEq(d.rewards.epoch(), e);
        }
        (GridOperator.Kind k1, uint16 s1,,, bool r1) = d.grid.eventAt(1);
        assertTrue(r1 && k1 == GridOperator.Kind.Green && s1 == FALLBACK, "epoch 1 is the table's Green");
        for (uint256 e = 2; e <= 17; ++e) {
            (GridOperator.Kind k,,,,) = d.grid.eventAt(e);
            assertFalse(_positive(k), "no override while the window still holds enough future positives");
        }

        // Unsubmitted epoch in the override: full fallback severity.
        (GridOperator.Kind k18, uint16 s18,,, bool r18) = d.grid.eventAt(18);
        assertTrue(r18);
        assertFalse(d.grid.planAt(18).submitted);
        assertTrue(_positive(k18), "fewer than four positives in [1, 18): forced positive");
        assertEq(s18, FALLBACK, "the fallback positive carries severity 10000 (1000 bps bonus)");

        // Submitted negative plans in the override: the kind is replaced, the submitted severity is kept.
        for (uint256 e = 19; e <= 20; ++e) {
            GridOperator.Plan memory p = d.grid.planAt(e);
            assertTrue(p.submitted && p.kind == GridOperator.Kind.Outage && p.severity == FLOOR);
            (GridOperator.Kind k, uint16 s,,, bool r) = d.grid.eventAt(e);
            assertTrue(r);
            assertTrue(_positive(k), "the override replaced the Outage plan's kind");
            assertEq(s, FLOOR, "pinned behaviour: the forced positive keeps the plan's 3000, not 10000");
            // FarmEngine applies severity / 10 as the Green output bonus: 300 bps here against 1000 bps for a
            // fallback positive, a 700 bps weaker positive for every local farm that epoch (accepted, pinned).
            assertEq(uint256(s) / 10, 300);
            assertEq(uint256(s18) / 10, 1000);
        }
    }

    /// @notice The keeper rule the acceptance records: a plan submitted at 10000 for a forced-positive epoch
    /// resolves at full strength, so the swarm is never worse off than the fallback when it submits high.
    function testHighSeverityPlanInForcedPositiveEpochResolvesAtFullStrength() public {
        for (uint256 e = 2; e <= 19; ++e) {
            _submitOutage(e);
            step();
        }
        vm.prank(swarm);
        d.grid.submitPlan(20, GridOperator.Kind.Outage, FALLBACK, keccak256("high"), "outage plan at 10000");
        step();
        (GridOperator.Kind k, uint16 s,,, bool r) = d.grid.eventAt(19);
        assertTrue(r && _positive(k) && s == FLOOR, "epoch 19: forced positive at the floor");
        step();
        (k, s,,, r) = d.grid.eventAt(20);
        assertTrue(r);
        assertTrue(_positive(k), "epoch 20 is still forced positive");
        assertEq(s, FALLBACK, "a high submitted severity carries into the forced positive");
    }
}
