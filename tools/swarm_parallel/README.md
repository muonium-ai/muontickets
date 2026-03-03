# Swarm Parallel Test

This tool simulates many asynchronous AI agents operating on the same MuonTickets board.

Features:
- Multithreaded workers performing random lifecycle operations
- Dispatcher thread that assigns/claims tickets to role-specific agents
- Role specialization model (design/code/review/security)
- Reproducible runs via `--seed`
- Markdown summary of operation success/failure rates

## Run (Python CLI)

```bash
.venv/bin/python tools/swarm_parallel/swarm_parallel_test.py --threads 24 --duration 45
```

## Run (Rust binary)

```bash
.venv/bin/python tools/swarm_parallel/swarm_parallel_test.py --mt-cmd "ports/dist/rust-mt" --threads 24 --duration 45
```

## Run (Zig binary)

```bash
.venv/bin/python tools/swarm_parallel/swarm_parallel_test.py --mt-cmd "ports/dist/zig-mt" --threads 24 --duration 45
```

## Suggested smoke run

```bash
.venv/bin/python tools/swarm_parallel/swarm_parallel_test.py --threads 8 --duration 10 --seed-tickets 20
```
