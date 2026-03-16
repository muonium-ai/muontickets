# MuonTickets Parity Report (Python vs Zig vs Rust vs C)

Date: 2026-03-16

## Scope

Compared implementations:
- Python reference CLI: `muontickets/mt.py`
- Zig port: `ports/zig-mt/src/main.zig`
- Rust port: `ports/rust-mt/src/main.rs`
- C port: `ports/c-mt/src/main.c`

Assessment method:
- Static command/option surface comparison.
- Behavior confirmation via conformance fixtures in `tests/test_conformance_runner.py`.

## Feature Tracking Table

### Aligned (All Ports Match Python Reference)

| Feature | Python (`mt.py`) | Zig (`zig-mt`) | Rust (`rust-mt`) | C (`c-mt`) | Deviation | Fix / Tracking Note | Status |
|---|---|---|---|---|---|---|---|
| Command surface (`init/new/ls/show/pick/claim/comment/set-status/done/archive/graph/export/stats/validate/report`) | ✅ | ✅ | ✅ | ✅ | None | Covered by conformance fixture suite | Aligned |
| `new` options (`--priority --type --effort --label --tag --depends-on --goal`) | ✅ | ✅ | ✅ | ✅ | None | Domain parity aligned to `p0/p1/p2` + `spec/code/tests/docs/refactor/chore` | Aligned |
| `ls` options (`--status --label --owner --priority --type --show-invalid`) | ✅ | ✅ | ✅ | ✅ | None | Zig `--show-invalid` parity was implemented and regression-tested | Aligned |
| `pick` options (`--owner --label --avoid-label --priority --type --branch --ignore-deps --max-claimed-per-owner --json`) | ✅ | ✅ | ✅ | ✅ | None | Scoring/tie-break covered by `pick_scoring` fixture | Aligned |
| `allocate-task` queue leasing (`--owner --label --avoid-label --priority --type --branch --ignore-deps --max-claimed-per-owner --lease-minutes --json`) | ✅ | ✅ | ✅ | ✅ | None | Allocation + lease lifecycle covered by `queue_allocate_fail` fixture | Aligned |
| `fail-task` retry and escalation (`--error --retry-limit --force`) + move-to-errors flow | ✅ | ✅ | ✅ | ✅ | None | Retry requeue + retry-limit exhaustion to `tickets/errors` covered by `queue_allocate_fail` fixture | Aligned |
| `claim/set-status/done/archive` workflow guards | ✅ | ✅ | ✅ | ✅ | None | Transition + dependency/archive safety behavior covered by fixtures | Aligned |
| `graph` options (`--mermaid --open-only`) | ✅ | ✅ | ✅ | ✅ | None | Verified in reporting/graph fixtures | Aligned |
| `export` formats (`json/jsonl`) + payload shape | ✅ | ✅ | ✅ | ✅ | None | Zig payload parity and C output shape are covered by conformance and exact-output tests | Aligned |
| `report` options (`--db --search --limit --summary`) + SQLite output | ✅ | ✅ | ✅ | ✅ | None | Report DB + summary/search behavior validated in fixture runs, including `tickets/errors` search hits | Aligned |
| `version` command and global version flags (`version --json`, `-v`, `--version`) | ✅ | ✅ | ✅ | ✅ | None | Zig 0.15 compatibility fixes restored build-from-source and version test coverage | Aligned |

### Gaps — Features Present in Python but Missing from Ports

#### Tier 1: Entire `maintain` Command Group (Missing from Rust and Zig)

Python exposes `maintain` as a top-level subcommand with five sub-subcommands backed by a 150-rule taxonomy across 9 categories. Neither Rust nor Zig implements this at all. C was not in scope for `maintain` either.

| Feature | Python | Zig | Rust | C | Tracking Ticket |
|---|:---:|:---:|:---:|:---:|---|
| `maintain init-config` (`--force`, `--detect`) | ✅ | ❌ | ❌ | N/A | T-000090, T-000091 |
| `maintain doctor` | ✅ | ❌ | ❌ | N/A | T-000090, T-000091 |
| `maintain list` (`--category`, `--rule`) | ✅ | ❌ | ❌ | N/A | T-000090, T-000091 |
| `maintain scan` (`--category`, `--rule`, `--all`, `--diff`, `--format`, `--profile`, `--fix`) | ✅ | ❌ | ❌ | N/A | T-000090, T-000091 |
| `maintain create` (`--category`, `--rule`, `--all`, `--dry-run`, `--priority`, `--owner`, `--skip-scan`) | ✅ | ❌ | ❌ | N/A | T-000090, T-000091 |

#### Tier 2: Missing Flags on Existing Commands (Rust and Zig)

`pick` and `allocate-task` support agent profiling via `--skill` and `--role`, which expand into label+type filter profiles. Both flags are absent from Rust and Zig.

| Command | Flag | Python | Zig | Rust | C | Tracking Ticket |
|---|---|:---:|:---:|:---:|:---:|---|
| `pick` | `--skill` (choices: `design`, `database`, `review`) | ✅ | ❌ | ❌ | N/A | T-000092, T-000093 |
| `pick` | `--role` (choices: `architect`, `devops`, `developer`, `reviewer`) | ✅ | ❌ | ❌ | N/A | T-000092, T-000093 |
| `allocate-task` | `--skill` | ✅ | ❌ | ❌ | N/A | T-000092, T-000093 |
| `allocate-task` | `--role` | ✅ | ❌ | ❌ | N/A | T-000092, T-000093 |

#### Tier 3: Behavioral Deviations

| Issue | Python | Zig | Rust | C | Tracking Ticket |
|---|---|---|---|---|---|
| `ls`/`show` output stream — Zig uses `std.debug.print` (stderr); Python and Rust use stdout | stdout | ❌ stderr | stdout | stdout | T-000094 |
| `ls` header suppression — Zig always prints the header even when 0 rows match | suppressed | ❌ always printed | suppressed | suppressed | T-000094 |
| `validate` per-field schema checks — Rust skips 11 of 20 checks (id pattern, title minLength, priority/type enums, labels/depends_on types, date patterns, ordering, branch/owner nullable rules) | full | full | ❌ partial | N/A | T-000095 |
| Default ticket template queue lifecycle fields (`retry_count`, `retry_limit`, `allocated_to`, `allocated_at`, `lease_expires_at`, `last_error`, `last_attempted_at`) missing from Rust and Zig templates | full | ❌ missing | ❌ missing | N/A | T-000096, T-000097 |
| `score` field type: Python writes float, Rust writes integer (`score as i64`), Zig writes string | float | ❌ string | ❌ integer | N/A | T-000098 |

## Verification Status

Current verification runs are passing from current source artifacts:

- Full test suite:
  - Command: `/.venv/bin/python -W error::DeprecationWarning -m unittest discover -s tests`
  - Result: `Ran 50 tests`, `OK`
- Cross-language conformance suite:
  - Command: `/.venv/bin/python -W error::DeprecationWarning -m unittest -v tests.test_conformance_runner`
  - Result: `Ran 29 tests`, `OK`
- Zig version coverage restored:
  - Command: `/.venv/bin/python -W error::DeprecationWarning -m unittest -v tests.test_versioning.VersioningTests.test_zig_version_json_output tests.test_versioning.VersioningTests.test_zig_global_version_invocations`
  - Result: `Ran 2 tests`, `OK`

Note: The above suite does not yet cover `maintain`, `--skill`/`--role`, or the behavioral fixes tracked in Tier 2/3 above.

## Current Conclusion

Within the covered fixture scope, version checks, and command/option surface, parity is achieved across `mt.py`, `zig-mt`, `rust-mt`, and `c-mt` for all features listed in the Aligned table.

The gaps catalogued above (Tiers 1–3) represent features added to the Python reference after the last parity sweep. Porting work is tracked in tickets T-000090 through T-000098.

## Notes / Caveat

This report reflects parity for currently implemented and tested flows. As new flags or behaviors are added, parity should be maintained by extending conformance fixtures first, then verifying Python, Zig, Rust, and C against those fixtures and version checks.
