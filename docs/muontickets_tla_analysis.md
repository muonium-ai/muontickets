# MuonTickets TLA Analysis

This report combines TLA PreCheck modeling with direct CLI experiments against MuonTickets.

## Coverage

- TLA models used in this repo:
  - `src/examples/muonTicketsLifecycle.machine.ts`
  - `src/examples/muonTicketsWip.machine.ts`
  - `src/examples/muonTicketsQueueLease.machine.ts`
  - `src/examples/muonTicketsQueueCompletion.machine.ts`
- CLI experiments run against:
  - Python: `tickets/mt/muontickets/muontickets/mt.py`
  - Rust: `tickets/mt/muontickets/ports/rust-mt/target/release/mt-port`
  - Zig: `tickets/mt/muontickets/ports/zig-mt/zig-out/bin/mt-zig`
- I did not do an independent correctness pass on the C port in this round.

## Headline Result

MuonTickets still has correctness gaps in four areas:

1. workflow invariants are enforced by `validate` after the fact instead of at transition time
2. queue ownership and lease metadata are not fully preserved or cleared correctly
3. ticket identity is not a single source of truth
4. concurrent writers can issue conflicting success responses

Issues 1 through 5 below are TLA-backed workflow findings. Issues 6 through 9 are empirical consistency and concurrency findings from direct CLI experiments.

## Confirmed Findings

### 1. `set-status` can create invalid lifecycle states

- TLA model: `MuonTicketsLifecycle`
- Repro:
  1. `mt init`
  2. `mt set-status T-000001 blocked`
  3. `mt set-status T-000001 claimed`
  4. `mt validate`
- Actual result:
  - `set-status ... claimed` succeeds
  - `validate` fails with `claimed ticket must have owner`
- Continuing with:
  1. `mt set-status T-000001 needs_review`
  2. `mt done T-000001`
  3. `mt validate`
- Actual result:
  - both transitions succeed
  - `validate` fails because `needs_review` and `done` require `branch`
- Why this matters:
  - the transition layer can create states that the validation layer later rejects
  - `set-status blocked -> claimed` also bypasses the dependency checks that `claim` normally performs
- Port coverage:
  - reproduced in Python, Rust, and Zig
- Recommended fix:
  - make `claim` the only normal entry into `claimed`, or make `set-status` enforce the same owner, branch, and dependency invariants as `claim`

### 2. Direct `claim` bypasses the per-owner WIP limit

- TLA model: `MuonTicketsWip`
- Repro:
  1. `mt init`
  2. `mt new "WIP A"`
  3. `mt new "WIP B"`
  4. `mt claim T-000001 --owner agent-wip`
  5. `mt claim T-000002 --owner agent-wip`
  6. `mt claim T-000003 --owner agent-wip`
  7. `mt validate`
- Actual result:
  - all 3 claims succeed
  - `validate` fails because one owner now has 3 claimed tickets while the max is 2
- Why this matters:
  - `pick`, `allocate-task`, and `validate` enforce the WIP rule
  - direct `claim` is an escape hatch around that same rule
- Port coverage:
  - reproduced in Python, Rust, and Zig
- Recommended fix:
  - run the same WIP check inside `claim`
  - centralize the WIP rule so `claim`, `pick`, `allocate-task`, and `validate` cannot drift

### 3. `fail-task` can clobber reallocated queue work

- TLA model: `MuonTicketsQueueLease`
- Repro:
  1. `mt init`
  2. `mt allocate-task --owner agent-a`
  3. expire the lease
  4. `mt allocate-task --owner agent-b`
  5. confirm MuonTickets reports stale-lease reallocation
  6. `mt fail-task T-000001 --error "stale worker reported failure"`
- Actual result:
  - the stale lease is successfully reallocated to `agent-b`
  - a later `fail-task` still succeeds and pushes the ticket back to `ready`
  - `validate` still reports OK
- Why this matters:
  - a stale worker can overwrite the result of a later, valid reallocation
  - `fail-task` checks only `status == claimed`; it does not verify current owner or lease holder
- Port coverage:
  - reproduced in Python, Rust, and Zig
- Recommended fix:
  - require actor or owner identity on `fail-task`
  - reject the mutation unless it matches the current `owner` or `allocated_to`

### 4. Python writes lease timestamps it cannot parse itself

- This is a concrete Python port bug, not a TLA transition bug.
- `allocate-task` writes `lease_expires_at` in this form:
  - `2026-03-19T02:45:48+00:00Z`
- Python `parse_utc_iso()` handles trailing `Z` by converting it to `+00:00`, so the stored value becomes:
  - `2026-03-19T02:45:48+00:00+00:00`
- Actual result:
  - `parse_utc_iso("2026-03-19T02:45:48+00:00Z") -> None`
  - `lease_expired(...) -> False`
- Why this matters:
  - naturally written leases can fail open and never expire
  - stale-lease reallocation in the Python port depends on `lease_expired()`
- Port coverage:
  - confirmed in Python
  - not reproduced in Rust or Zig; those ports write plain `...Z` timestamps
- Recommended fix:
  - stop appending `Z` to a string that already has `+00:00`
  - validate parseability of `lease_expires_at`, `allocated_at`, and `last_attempted_at`

### 5. Successful queue completion preserves active lease metadata

- TLA model: `MuonTicketsQueueCompletion`
- Repro:
  1. `mt init`
  2. `mt allocate-task --owner agent-q`
  3. `mt set-status T-000001 needs_review`
  4. `mt done T-000001`
  5. `mt show T-000001`
  6. `mt validate`
- Actual result:
  - the ticket reaches `done`
  - these queue fields are still present:
    - `allocated_to`
    - `allocated_at`
    - `lease_expires_at`
    - `last_attempted_at`
  - `validate` still reports OK
- Why this matters:
  - completed tickets still look actively leased even though queue execution is over
- Port coverage:
  - confirmed in Python
- Recommended fix:
  - clear active lease fields when leaving live queue execution
  - at minimum, clear them on transition into `needs_review` and `done`

### 6. Filename and frontmatter `id` can diverge without validation

- Repro:
  1. `mt init`
  2. edit `tickets/T-000001.md` so frontmatter says `id: T-999999`
  3. run `mt validate`
  4. run `mt show T-000001`
  5. run `mt claim T-000001 --owner mismatch-owner`
  6. run `mt report --search T-999999`
- Actual result:
  - `validate` reports OK
  - `show T-000001` reads the file by filename but prints `id: T-999999`
  - `claim T-000001` succeeds against that same file
  - `report` indexes the file under `T-999999`
- Why this matters:
  - mutation commands use the filename as identity
  - reporting and export use frontmatter `id` as identity
  - that creates split-brain ticket identity semantics
- Port coverage:
  - reproduced in Python, Rust, and Zig
- Additional port divergence:
  - Python and Rust derive the default branch from the embedded frontmatter `id`
  - Zig derives the default branch from the CLI or filename ticket ID
- Recommended fix:
  - require filename and frontmatter `id` to match
  - reject mismatches in `validate`
  - reject writes that would create or preserve an ID mismatch

### 7. Duplicate logical IDs are not rejected

- Repro:
  1. `mt init`
  2. copy `tickets/T-000001.md` to `tickets/T-000002.md` without changing frontmatter `id`
  3. copy `tickets/T-000001.md` into `tickets/archived/T-000001.md`
  4. run `mt validate`
  5. run `mt export --format json`
  6. run `mt report --search T-000001`
- Actual result:
  - `validate` reports OK
  - `export` emits multiple rows with the same logical ID
  - `report` shows three rows for `T-000001` across active and archived buckets
- Why this matters:
  - the system allows multiple files to claim the same logical ticket identity
  - combined with finding 6, reporting and mutation can disagree about what a given ticket ID even means
- Port coverage:
  - confirmed in Python
- Recommended fix:
  - enforce uniqueness of frontmatter `id` across all buckets
  - treat duplicate logical IDs as validation failures

### 8. Dependency validation misses self-dependencies and cycles

- Repro A: self-dependency
  1. `mt init`
  2. edit `tickets/T-000001.md` so `depends_on: [T-000001]`
  3. run `mt validate`
  4. run `mt claim T-000001 --owner self-owner`
- Actual result:
  - `validate` reports OK
  - `claim` later refuses because `T-000001` is not done
- Repro B: 2-ticket cycle
  1. `mt init`
  2. create `T-000002`
  3. set `T-000001 depends_on [T-000002]`
  4. set `T-000002 depends_on [T-000001]`
  5. run `mt validate`
  6. run `mt validate --enforce-done-deps`
- Actual result:
  - both validation commands report OK
- Why this matters:
  - permanently unclaimable ticket graphs can appear valid
  - the problem is only discovered later when individual workflow commands refuse to move
- Port coverage:
  - confirmed in Python
- Recommended fix:
  - reject self-dependencies
  - detect and reject dependency cycles during validation

### 9. Core writer commands are not safe under concurrent writers

- Repro area:
  - `mt new`
  - `mt claim`
  - `mt pick`
  - `mt allocate-task`
- Confirmed results from Python parallel-writer stress tests:
  - parallel `new` can return the same ticket ID twice and silently overwrite one file
  - parallel `claim` can tell multiple agents they succeeded against the same ready ticket
  - parallel `pick` can hand the same ticket to multiple agents
  - parallel `allocate-task` can lease the same ticket to multiple agents
  - `validate` still reports OK after those races
- Why this matters:
  - multiple agents can receive a success response for mutually incompatible work
  - the final on-disk file only reflects the last writer, so the earlier success responses become silent lies
- Port coverage:
  - confirmed in Python
  - I did not get a multi-success repro for Rust or Zig in a single short spot-check, so I am not marking port-wide parity on this one yet
- Recommended fix:
  - add inter-process locking or compare-and-swap style revision checks around all critical mutations
  - protect both ticket creation and ticket mutation, not just file replacement

## Port Notes

- Reproduced in Python, Rust, and Zig:
  - invalid lifecycle transitions via `set-status`
  - direct `claim` bypassing WIP limits
  - stale-worker `fail-task` after lease reallocation
  - filename and frontmatter ID mismatch acceptance
- Confirmed only in Python so far:
  - broken lease timestamp serialization
  - queue completion leaving active lease fields behind
  - duplicate logical IDs not being rejected
  - self-dependencies and dependency cycles passing validation
  - multi-writer races on `new`, `claim`, `pick`, and `allocate-task`
- Confirmed divergence:
  - under an ID mismatch, Python and Rust derive the default branch from frontmatter `id`
  - Zig derives the default branch from the filename or CLI ID instead

## Recommended Fix Order

1. Move invariant enforcement into the transition commands themselves.
2. Enforce a single ticket identity model: filename must match frontmatter `id`, and logical IDs must be unique.
3. Fix Python lease serialization and clear active lease fields on queue completion.
4. Add dependency-graph validation for self-dependencies and cycles.
5. Add inter-process locking or revision checks around all writer commands.
6. Add cross-port conformance tests so Python, Rust, and Zig do not drift.

## Minimum Regression Suite

1. `set-status blocked -> claimed` without owner should fail.
2. `set-status ... claimed` with unresolved dependencies should fail.
3. claiming a third ticket for the same owner should fail when the configured max is 2.
4. after stale-lease reallocation from `agent-a` to `agent-b`, `fail-task` for `agent-a` should fail.
5. `allocate-task` must write a parseable `lease_expires_at`.
6. `allocate-task -> needs_review -> done` must clear active lease fields.
7. `validate` must fail if filename and frontmatter `id` differ.
8. `validate` must fail on duplicate logical IDs across active, archive, backlog, and error buckets.
9. `validate` must fail on self-dependencies and dependency cycles.
10. parallel `new`, `claim`, `pick`, and `allocate-task` must never issue incompatible success responses.
