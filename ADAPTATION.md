# ADAPTATION — BLACKOUT L4 (job B) on Robinhood Chain (4663)

Launch kind: `evm_contracts`, eight application contracts, no token, pool or swarm share. Build: the unchanged
repository `foundry.toml` (solc 0.8.26, optimizer 200 runs, cancun, `via_ir = false`, `bytecode_hash = "none"`).

## Source changes

**None.** Every contract is pinned: `src/lib/ModuleCode.sol` holds the creation-code hashes of the fourteen modules,
the deployed L3 `GameRegistry` (`0x1b41fc9723df25eec7e91d947072dccc2483285f`) registers modules only against those
pins, and the L1 Desk is already bound to that registry. A source edit to any of the eight L4 contracts would change
its creation hash and make the launch unregistrable. The eight contracts are byte-identical to v3.17 / v3.18
(commit `86e71d4`); no file under `src/`, `script/`, `launch/` or any build configuration was modified.

## Verification of the launch requirements against the unchanged source

| Index | Contract | Constructor | Creation hash (built here) | Runtime bytes |
| --- | --- | --- | --- | --- |
| 0 | FeeRouter | `(address registry)` | `0x3b53c8d89f2836c0744007bac7e168e6c66dd19eaf4a74b2eadd5161ad12e6af` | 11750 |
| 1 | GridOperator | `(address registry)` | `0x931bdfaeeacadb7c8014ce1411671d0045013c2b373d95bbf0bb83dfce0b7c74` | 9519 |
| 2 | Season | `(address registry)` | `0xa79fdfbecdb2450bc94c1cedac7618b1f4244fe63c3f1bc6fea784f82cd42c83` | 11933 |
| 3 | FarmEngine | `(address registry)` | `0x48a9f8dd8c707a2a8c6b4a1838640be765a3e3c9d2306680bda5ce679b6dbe7c` | 10783 |
| 4 | Economy | `(address registry)` | `0x105f9f29d79579fa33ff8e11d4d86847dd7d9f59bd681500553a3844db50ccc9` | 11097 |
| 5 | Enhancement | `(address registry)` | `0x31242676dd3a728a2ad32a5cb300166020e87831b0f547756fa0bab88cedea38` | 7112 |
| 6 | Civic | `(address registry)` | `0xb3e89ec00b8ad51904cdac336644a6025ceea25c15fa931cac2ad13d89dc0bb2` | 13019 |
| 7 | Billboards | `(address registry)` | `0x3cb8b542f7baa025b6db7f2a4864288a594d05e75b9b4e9ec66416c1fe52aa60` | 6031 |

All eight hashes equal the expected creation hashes in the brief and `artifacts/v318/creation-hashes.json`
(`forge build` with the repository `foundry.toml`, `cast keccak` of `bytecode.object`; no link references).

- **Constructor the factory can call.** Each contract has one nonpayable constructor with a single `address`
  argument (`GameModule`, `src/lib/GameModule.sol`): it rejects the zero address and stores the registry. It makes no
  external call and does not require the argument to have code, so it runs on the empty chain of the protected
  rehearsal. The single constructor word of every contract is the recorded L3 GameRegistry, a static address; no
  `$owner`, no IMD protocol address and no `$contract:` reference is needed.
- **No owner or admin.** No L4 contract has an owner, admin, `owner()` or privileged setter; the only authority they
  consult is `Params.swarmWallet()` of the bound registry, which is the non-upgradeable L1 SwarmDesk. Nothing is
  assigned to `msg.sender` (the factory) or `tx.origin`.
- **Forbidden opcodes and size.** No DELEGATECALL, CALLCODE or SELFDESTRUCT in any runtime (checked with the same
  opcode walk as the protected probe); every runtime is below the 24,576-byte EIP-170 limit (largest: Civic, 13,019).
  No proxy, upgrade path, mint, pause, freeze, blacklist or seizure exists in the eight contracts.
- **Library linkage.** The libraries the modules use (`ModuleCode`, `EconomyMath`, `ChainClock`, …) have only
  internal functions; no artifact carries link references.

## Audit of the imported code (1 finding)

- **0d49094e (info), `GridOperator._resolve` keeps a submitted plan's severity after the positive-streak override
  replaces its kind — reproduced, accepted, not fixed.** `test/AuditL4V318.t.sol` reproduces it against the pinned
  code: with Outage plans at the 3000 floor for epochs 2–17 and 19–20 and no plan for epoch 18, the override fires
  from epoch 18; the unsubmitted epoch 18 resolves Green/Cheap at severity 10000 (1000 bps `FarmEngine` bonus) while
  the submitted epochs 19 and 20 resolve Green/Cheap at the submitted 3000 (300 bps). A second test shows the keeper
  rule the acceptance records: a plan submitted at 10000 for a forced-positive epoch resolves at full strength. The
  fix the audit suggests (set `x.severity = 10000` when the override replaces the kind) would change the
  GridOperator creation hash, which the bound registry would refuse, so under the requester's NO SOURCE CHANGES
  decision it is accepted and recorded in `docs/accepted-v318.md` ("Accepted at L4"). It moves no funds and only
  weakens a positive event for everyone, so the swarm cannot profit from it.
- The L3 import findings the brief lists (d873782c FarmRewards.claim lock-boost re-commit, b61f7912 PackSale starter
  flag) concern L3 contracts already deployed in launch 1722; they are accepted by the requester and untouched here.

## Files changed

| File | Change | Why |
| --- | --- | --- |
| `test/AuditL4V318.t.sol` | new: two tests | Reproduce audit 0d49094e against the pinned code and pin the accepted behaviour and the keeper rule (acceptance criterion: every finding reproduced with a test). |
| `docs/accepted-v318.md` | new section "Accepted at L4" | Record the accepted L4 finding with the project's other accepted findings. |
| `ADAPTATION.md` | new | This file. |

No file under `src/`, `script/`, `launch/`, `vendor/`, `foundry.toml` or `remappings` was touched. `launch.json` is
not written (the manifest step writes it).

## Checks run

- `forge build` with the unchanged `foundry.toml`: success.
- `forge test` with `FOUNDRY_FUZZ_SEED=0x639f066f0f04682dc29416e0249421603400a62fe7e56454f59bda585201b396`:
  all suites pass (the opt-in historical fork tests skip without a fork URL, as before).
- `python3 tools/pin_module_code.py --check`: module pins match the build.
- A local mirror of the protected deployment probe (CREATE2 of all eight creation codes with the registry word on
  an empty chain, EIP-170 bound, forbidden-opcode scan): passes.

## After the launch (keeper, from `launch-v39.md` §L4 and the brief)

Register roles 6–13 with `(role, N_B, role - 6, creationCode)` in the listed order, verify all fourteen
`module(role)` addresses, then `V4Market.bindFeeRouter`, `EndowmentEscrow.forward`, `RewardPool.fundEndowment`,
and only then execute stored oracle answers. GAME_CONFIG_HASH
`0x11ed7438974e96ecc962201e9c46422c7bf239d725876863fa25a56c734b20d3` is unchanged.
