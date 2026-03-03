# Ticket lifecycle benchmark (temp)

Runs a same-shape lifecycle benchmark across Python, Rust, and Zig MuonTickets CLIs:
- create `N` tickets
- update all tickets (`comment`)
- archive all tickets (`done --force` + `archive --force`)
- run `report`

## Run

From repo root:

```bash
.venv/bin/python tools/perf_1000/benchmark_ticket_lifecycle.py --count 1000
```

The script auto-builds release binaries via `make -C ports release` if `ports/dist/rust-mt` or `ports/dist/zig-mt` is missing.

Output is a markdown table with per-phase timings and ops/sec for each implementation.
