# MuonTickets Parity Report (Python vs Zig vs Rust vs C)

Date: 2026-03-17

## Scope

Compared implementations:
- Python reference CLI: `muontickets/mt.py`
- Zig port: `ports/zig-mt/src/main.zig`
- Rust port: `ports/rust-mt/src/main.rs`
- C port: `ports/c-mt/src/main.c` (hybrid: native commands + Python delegation)

Assessment method:
- Static command/option surface comparison.
- Behavior confirmation via conformance fixtures in `tests/test_conformance_runner.py`.
- Makefile `test-conformance` target runs 20 tests (5 per port).

## Conformance Fixture Matrix

| Fixture | Python | Zig | Rust | C |
|---|---|---|---|---|
| `core_workflow` | PASS | PASS | PASS | PASS |
| `reporting_graph_pick` | PASS | PASS | PASS | PASS |
| `options_parity` | PASS | PASS | PASS | PASS |
| `pick_scoring` | PASS | PASS | PASS | PASS |
| `queue_allocate_fail` | PASS | PASS | PASS | PASS |

All 20 tests passing — full 5/5 fixture parity across all four ports.

## Feature Tracking Table

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
| `export` formats (`json/jsonl`) + payload shape | ✅ | ✅ | ✅ | ✅ | None | Payload parity covered by conformance and exact-output tests | Aligned |
| `validate` policy flags (`--max-claimed-per-owner --enforce-done-deps`) and strict checks | ✅ | ✅ | ✅ | ✅ | None | Strict checks exercised in conformance | Aligned |
| `report` options (`--db --search --limit --summary`) + SQLite output | ✅ | ✅ | ✅ | ✅ | None | Report DB + summary/search behavior validated in fixture runs | Aligned |
| `version` command and global version flags (`version --json`, `-v`, `--version`) | ✅ | ✅ | ✅ | ✅ | None | Version test coverage verified | Aligned |
| `maintain` subcommands (`init-config/doctor/list/scan/create`) | ✅ | ✅ | — | ✅ | Rust lacks maintain | Zig port fully implements maintain group; C delegates to Python | Partial |

## C Port Architecture Note

The C port (`c-mt`) uses a hybrid strategy:
- **Native C implementations**: `version`, `init`, `new`, `show`, `comment`, `done`, `archive` — executed directly for performance
- **Python delegation**: all other commands are forwarded to the canonical `mt.py` via `fork()+execvp()` (Unix) or `_spawnvp()` (Windows)
- This guarantees behavior parity while providing a cross-platform native binary entrypoint

## Verification Status

Current verification runs passing:

- Makefile conformance suite:
  - Command: `make test-conformance`
  - Result: `Ran 20 tests`, `OK` (5 Python + 5 Zig + 5 Rust + 5 C)

## Current Conclusion

Within the covered fixture scope, version checks, and command/option surface, full conformance parity is achieved across:
- `mt.py` (Python reference)
- `zig-mt` (Zig port)
- `rust-mt` (Rust port)
- `c-mt` (C port, hybrid native + delegation)

The `maintain` subcommand group is implemented in Python, Zig, and C (via delegation) but not yet in Rust.

## Notes / Caveat

This report reflects parity for currently implemented and tested flows. As new flags or behaviors are added, parity should be maintained by extending conformance fixtures first, then verifying all ports against those fixtures.
