# Ticket lifecycle benchmark (temp)

Runs a same-shape lifecycle benchmark across Python, Rust, Zig, and C MuonTickets CLIs:
- create `N` tickets
- update all tickets (`comment`)
- archive all tickets (`done --force` + `archive --force`)
- run `report`

## Run

From repo root:

```bash
.venv/bin/python tools/perf_1000/benchmark_ticket_lifecycle.py --count 1000
```

The script auto-builds missing release binaries via `make -C ports <target>` for `rust`, `zig`, and `c`.

If a non-Python port fails to build, the benchmark now emits a warning and continues with remaining available implementations.

For `c-mt`, the benchmark sets `MT_PYTHON` to the repo virtualenv interpreter (`.venv/bin/python`) so delegated commands avoid slower system-Python fallback.

When Zig build fails with known `build.zig.zon` parse signatures, the warning includes detected `zig version` to aid triage.

Output is a markdown table with per-phase timings and ops/sec for each implementation.
