# MuonTickets Parity Report (Python vs Zig vs Rust vs C)

Date: 2026-03-17

## Scope

Compared implementations:
- Python reference CLI: `muontickets/mt.py`
- Zig port: `ports/zig-mt/src/main.zig`
- Rust port: `ports/rust-mt/src/main.rs`
- C port: `ports/c-mt/src/main.c`

Assessment method:
- Static command/option surface comparison.
- Behavior confirmation via conformance fixtures in `tests/test_conformance_runner.py`.
- Makefile `test-conformance` target runs 24 tests (6 per port).

## Conformance Fixture Matrix

| Fixture | Python | Zig | Rust | C |
|---|---|---|---|---|
| `core_workflow` | PASS | PASS | PASS | PASS |
| `reporting_graph_pick` | PASS | PASS | PASS | PASS |
| `options_parity` | PASS | PASS | PASS | PASS |
| `pick_scoring` | PASS | PASS | PASS | PASS |
| `queue_allocate_fail` | PASS | PASS | PASS | PASS |
| `maintain_parity` | PASS | PASS | PASS | PASS |

All 24 tests passing — full 6/6 fixture parity across all four ports.

## Feature Tracking Table

| Feature | Python (`mt.py`) | Zig (`zig-mt`) | Rust (`rust-mt`) | C (`c-mt`) | Status |
|---|---|---|---|---|---|
| Command surface (`init/new/ls/show/pick/claim/comment/set-status/done/archive/graph/export/stats/validate/report`) | ✅ | ✅ | ✅ | ✅ | Aligned |
| `new` options (`--priority --type --effort --label --tag --depends-on --goal`) | ✅ | ✅ | ✅ | ✅ | Aligned |
| `ls` options (`--status --label --owner --priority --type --show-invalid`) | ✅ | ✅ | ✅ | ✅ | Aligned |
| `pick` options (`--owner --label --avoid-label --priority --type --branch --ignore-deps --max-claimed-per-owner --json`) | ✅ | ✅ | ✅ | ✅ | Aligned |
| `allocate-task` queue leasing | ✅ | ✅ | ✅ | ✅ | Aligned |
| `fail-task` retry and escalation | ✅ | ✅ | ✅ | ✅ | Aligned |
| `claim/set-status/done/archive` workflow guards | ✅ | ✅ | ✅ | ✅ | Aligned |
| `graph` options (`--mermaid --open-only`) | ✅ | ✅ | ✅ | ✅ | Aligned |
| `export` formats (`json/jsonl`) | ✅ | ✅ | ✅ | ✅ | Aligned |
| `validate` policy flags | ✅ | ✅ | ✅ | ✅ | Aligned |
| `report` options (`--db --search --limit --summary`) | ✅ | ✅ | ✅ | ✅ | Aligned |
| `version` command and flags | ✅ | ✅ | ✅ | ✅ | Aligned |
| `maintain init-config` (`--force --detect`) | ✅ | ✅ | ✅ | ✅ | Aligned |
| `maintain doctor` | ✅ | ✅ | ✅ | ✅ | Aligned |
| `maintain list` (`--category --rule`) | ✅ | ✅ | ✅ | ✅ | Aligned |
| `maintain scan` (`--category --rule --all --format --profile --diff --fix`) | ✅ | ✅ | ✅ | ✅ | Aligned |
| `maintain create` (`--category --rule --all --dry-run --skip-scan --priority --owner`) | ✅ | ✅ | ✅ | ✅ | Aligned |

## Implementation Notes

- **Python**: Reference implementation, all 150 maintenance rules with 7 built-in scanners
- **Zig**: Fully native, all 150 rules and scanners, reads VERSION file at build time
- **Rust**: Fully native, all 150 rules and scanners, uses clap + serde_yaml + regex
- **C**: Fully native (no Python delegation), all 150 rules and scanners, POSIX regex

## Verification Status

- Makefile conformance suite:
  - Command: `make test-conformance`
  - Result: `Ran 24 tests`, `OK` (6 Python + 6 Zig + 6 Rust + 6 C)

## Conclusion

Full conformance parity achieved across all four ports for all commands, options, and maintain subcommands. Every port is self-contained and production-ready with no external dependencies on other implementations.
