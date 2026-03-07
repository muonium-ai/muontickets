# MuonTickets Parity Report (Python vs Zig vs Rust vs C)

Date: 2026-03-07

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
| `validate` policy flags (`--max-claimed-per-owner --enforce-done-deps`) and strict checks | ✅ | ✅ | ✅ | ✅ | None | Zig strict checks and C parity checks are exercised in conformance | Aligned |
| `report` options (`--db --search --limit --summary`) + SQLite output | ✅ | ✅ | ✅ | ✅ | None | Report DB + summary/search behavior validated in fixture runs, including `tickets/errors` search hits | Aligned |
| `version` command and global version flags (`version --json`, `-v`, `--version`) | ✅ | ✅ | ✅ | ✅ | None | Zig 0.15 compatibility fixes restored build-from-source and version test coverage | Aligned |

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

## Current Conclusion

Within the covered fixture scope, version checks, and command/option surface, parity is achieved across:
- `mt.py`
- `zig-mt`
- `rust-mt`
- `c-mt`

## Notes / Caveat

This report reflects parity for currently implemented and tested flows. As new flags or behaviors are added, parity should be maintained by extending conformance fixtures first, then verifying Python, Zig, Rust, and C against those fixtures and version checks.
