# BLACKOUT L4 job B tests

This suite adds coverage to the existing tests without changing pinned application code or configuration.

| File | Coverage |
| --- | --- |
| `Launch.t.sol` | All eight exact creation hashes from the assignment, registry pins, ordered CREATE2 deployment in one call on chain ID 4663, empty-chain constructor safety, runtime limits and forbidden opcodes. Each zero-registry constructor is also tested for whole-batch rollback. |
| `EscrowInvariants.t.sol` | Random billboard bids, self-outbids, refunds, settlement and direct donations; Civic wars with 16 actors, including 12 in one district to exercise the top-ten score cap; Economy locks, expiration, sorted-list integrity and withdrawals while rewards are stopped. |
| `FeeSeasonInvariants.t.sol` | Random fee deposits, token routing, reward/pot buys, sells, bounties and withdrawals; Season claims, expiry and rollover. Independent running totals reconcile assets with every tracked liability. |
| `FailurePaths.t.sol` | Authorization, input boundaries, notice timing, failed payments, insufficient market output, failed recipients and reentrancy attempts. Rejected operations must preserve balances, claim rights, queues and allowances. |
| `GameplayEdges.t.sol` | FarmEngine allocation bounds and monotonic output under repair; unauthorized and unresolved processing; Enhancement payment rollback; GridOperator and Enhancement native L2 clock boundaries. |

The five invariant suites each run 128 sequences of 96 calls with unexpected handler reverts treated as failures. Deterministic setup seeds nonempty positions. Billboard, Civic, Economy and FeeRouter teardown exercises withdrawal/settlement liveness. Fuzz properties run 1,000 examples each. Counts are inline in Solidity, so no command-line overrides are needed.

`L4Fixture.sol` uses the actual L4 contracts, Params and RewardPool. Its isolated registry and small L3 callback stub allow custody accounting to be checked independently of farming. The stub provides zero-yield floors, no district hash, readiness, synchronization and prize-pack receipts; it does not model L3 reward settlement, NFT minting or oracle authentication. Market execution uses the repo's existing local mock with configurable failures and short output. `GameplayEdges.t.sol` instead reuses the existing complete pinned deployment graph. Actor and governor addresses in these fixtures are test identities only.

The accepted source findings remain unchanged. Civic war assertions allow only the documented integer-division dust; the Season handler rolls an already finalized week. The isolated Economy handler tests principal and list integrity, not the accepted FarmRewards lock-boost re-commit behavior. The existing suites retain their coverage of the accepted implementation.

Run offline from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x639f066f0f04682dc29416e0249421603400a62fe7e56454f59bda585201b396 forge test
```

These are local tests, not an on-chain launch or verification of recorded live state. Live Robinhood integration remains subject to the existing optional fork/rehearsal suites, which skip without RPC configuration. No deployment addresses or launch number are produced by this testing assignment.
