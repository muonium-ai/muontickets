# MuonTickets Parity Report (Python vs Zig vs Rust)

Date: 2026-03-03

## Scope

Compared implementations:
- Python reference CLI: `muontickets/mt.py`
- Zig port: `ports/zig-mt/src/main.zig`
- Rust port: `ports/rust-mt/src/main.rs`

Assessment method:
- Static command/option surface comparison.
- Behavior confirmation via conformance fixtures in `tests/test_conformance_runner.py`.

## Feature Tracking Table

| Feature | Python (`mt.py`) | Zig (`zig-mt`) | Rust (`rust-mt`) | Deviation | Fix / Tracking Note | Status |
|---|---|---|---|---|---|---|
| Command surface (`init/new/ls/show/pick/claim/comment/set-status/done/archive/graph/export/stats/validate/report`) | ✅ | ✅ | ✅ | None | Covered by conformance fixture suite | Aligned |
| `new` options (`--priority --type --effort --label --tag --depends-on --goal`) | ✅ | ✅ | ✅ | None | Domain parity aligned to `p0/p1/p2` + `spec/code/tests/docs/refactor/chore` | Aligned |
| `ls` options (`--status --label --owner --priority --type --show-invalid`) | ✅ | ✅ | ✅ | None | Zig `--show-invalid` parity was implemented and regression-tested | Aligned |
| `pick` options (`--owner --label --avoid-label --priority --type --branch --ignore-deps --max-claimed-per-owner --json`) | ✅ | ✅ | ✅ | None | Scoring/tie-break covered by `pick_scoring` fixture | Aligned |
| `claim/set-status/done/archive` workflow guards | ✅ | ✅ | ✅ | None | Transition + dependency/archive safety behavior covered by fixtures | Aligned |
| `graph` options (`--mermaid --open-only`) | ✅ | ✅ | ✅ | None | Verified in reporting/graph fixtures | Aligned |
| `export` formats (`json/jsonl`) + payload shape | ✅ | ✅ | ✅ | None | Zig payload parity (labels/tags/owner/dates/deps/branch/excerpt/path) implemented | Aligned |
| `validate` policy flags (`--max-claimed-per-owner --enforce-done-deps`) and strict checks | ✅ | ✅ | ✅ | None | Zig strict checks (parse errors, required fields, date order) added + tested | Aligned |
| `report` options (`--db --search --limit --summary`) + SQLite output | ✅ | ✅ | ✅ | None | Report DB + summary/search behavior validated in fixture runs | Aligned |

## Conformance Status

Cross-language conformance run (11 fixture tests) is passing:

- Command used:
  - `.venv/bin/python -m unittest tests.test_conformance_runner.ConformanceRunnerTests.test_core_workflow_fixture tests.test_conformance_runner.ConformanceRunnerTests.test_reporting_graph_pick_fixture tests.test_conformance_runner.ConformanceRunnerTests.test_options_parity_fixture tests.test_conformance_runner.ConformanceRunnerTests.test_pick_scoring_fixture tests.test_conformance_runner.ConformanceRunnerTests.test_zig_reporting_graph_pick_fixture tests.test_conformance_runner.ConformanceRunnerTests.test_zig_options_parity_fixture tests.test_conformance_runner.ConformanceRunnerTests.test_zig_pick_scoring_fixture tests.test_conformance_runner.ConformanceRunnerTests.test_rust_core_workflow_fixture tests.test_conformance_runner.ConformanceRunnerTests.test_rust_reporting_graph_pick_fixture tests.test_conformance_runner.ConformanceRunnerTests.test_rust_options_parity_fixture tests.test_conformance_runner.ConformanceRunnerTests.test_rust_pick_scoring_fixture`
- Result:
  - `Ran 11 tests in 1.954s`
  - `OK`

## Current Conclusion

Within the covered fixture scope and command/option surface, parity is achieved across:
- `mt.py`
- `zig-mt`
- `rust-mt`

## Notes / Caveat

This report reflects parity for currently implemented and tested flows. As new flags/behaviors are added, parity should be maintained by extending conformance fixtures first, then verifying all three implementations against those fixtures.
