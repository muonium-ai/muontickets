# Contention Analysis

## Why 10–25% failures can occur in swarm runs

Most failures in the current swarm benchmark are expected contention effects, not necessarily functional correctness defects.

### 1) Concurrent stale-read races
The swarm harness runs many workers against the same board without transaction/lock coordination.
A worker can read ticket state (for example from `ls`/`show`) and then issue a mutating command after another worker has already changed that ticket.

Typical result:
- one command succeeds,
- competing commands fail with status/path/precondition errors.

### 2) Hotspot operations: `pick` and dispatcher `claim`
`pick` and dispatcher `claim` are the most race-prone operations because many threads target the same small set of `ready` tickets.
This creates natural collision:
- one thread claims first,
- others lose and return non-zero.

### 3) Lifecycle transition collisions
During high concurrency, operations overlap:
- one thread moves ticket status,
- another tries `set-status`/`done` from an outdated prior state,
- one thread archives while another tries `comment` or `show` on that same ticket.

These are expected under competitive parallel scheduling.

### 4) Throughput amplifies collision rate
Faster implementations attempt many more operations per second.
Higher ops/sec increases probability of collisions in the same time window, which can lower success rate even while total useful work increases.

## Interpreting current benchmark behavior
- Higher failure rate alone does not mean implementation is worse.
- Compare **both** throughput and success rate.
- Current results show a throughput-vs-contention tradeoff across Python, Rust, and Zig.

## Recommended next instrumentation
To separate expected contention from real bugs, bucket failures by reason:
- ticket not found / already archived
- invalid status transition / precondition mismatch
- no claimable ticket found
- dependency/state validation failures

Tracking these categories per implementation and per operation (`pick`, `claim`, `done`, `archive`, etc.) will make future comparisons far more actionable.
