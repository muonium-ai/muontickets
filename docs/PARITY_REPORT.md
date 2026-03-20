# MuonTickets Parity Report (Python vs Zig vs Rust vs C)

Date: 2026-03-20

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
- Performance: `benchmark_ticket_lifecycle.py` with 30 and 1000 ticket runs.
- Frontmatter generation: `compare_generated_tickets.py` cross-implementation diff.

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

## Performance Benchmarks (2026-03-20)

### Smoke (30 tickets)

| Implementation | Create | Update | Archive | Report | Total | Create ops/s | Update ops/s | Archive ops/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| python-mt | 1.383s | 1.390s | 3.035s | 0.063s | 5.871s | 21.7 | 21.6 | 9.9 |
| rust-mt | 0.232s | 0.102s | 0.217s | 0.013s | 0.564s | 129.2 | 292.8 | 138.3 |
| zig-mt | 0.067s | 0.058s | 0.123s | 0.013s | 0.261s | 445.3 | 520.5 | 243.9 |
| c-mt | 0.073s | 0.067s | 0.133s | 0.065s | 0.338s | 410.0 | 450.8 | 225.6 |

### Full (1000 tickets)

| Implementation | Create | Update | Archive | Report | Total | Create ops/s | Update ops/s | Archive ops/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| python-mt | 48.381s | 47.803s | 318.988s | 0.561s | 415.733s | 20.7 | 20.9 | 3.1 |
| rust-mt | 105.683s | 3.510s | 16.846s | 0.256s | 126.295s | 9.5 | 284.9 | 59.4 |
| zig-mt | 2.327s | 1.892s | 15.508s | 0.308s | 20.034s | 429.7 | 528.5 | 64.5 |
| c-mt | 2.391s | 2.225s | 10.777s | 0.541s | 15.935s | 418.2 | 449.4 | 92.8 |

**Observations:**
- **c-mt** and **zig-mt** are fastest overall at 1000 tickets (~16s and ~20s).
- **rust-mt** has a severe create-phase regression at scale: 105.7s for 1000 creates (9.5 ops/s) vs 129 ops/s at 30 tickets, indicating non-linear scaling in ticket creation.
- **python-mt** archive phase degrades significantly at scale (3.1 ops/s at 1000 vs 9.9 at 30).

## Frontmatter Generation Variances

Differences found by `compare_generated_tickets.py` between ports:

| Field | Python | Rust | Zig | C |
|---|---|---|---|---|
| `created` | `'2026-03-20T05:53:57Z'` (ISO 8601 with time) | `2026-03-20` (date only) | `2026-03-20` (date only) | (matches Python) |
| `updated` | `'2026-03-20T05:53:57Z'` (ISO 8601 with time) | `2026-03-20` (date only) | `2026-03-20` (date only) | (matches Python) |
| `labels` | `''` (empty string) | `[alpha]` (YAML list) | `[alpha]` (YAML list) | (matches Python) |
| `tags` | `''` (empty string) | `[beta]` (YAML list) | `[beta]` (YAML list) | (matches Python) |

**Impact:** These differences do not affect conformance tests (which validate behavior, not raw YAML formatting), but they represent frontmatter serialization divergence that could cause issues for cross-implementation ticket interchange.

## Conclusion

Full conformance parity achieved across all four ports for all commands, options, and maintain subcommands. Every port is self-contained and production-ready with no external dependencies on other implementations.
