# Tools Usage

Developer utility scripts are organized under `tools/` and grouped by purpose.

## Benchmarks

### allocate-task single run

```bash
.venv/bin/python tools/benchmarks/bench_allocate_task.py --duration 20 --seed-tickets 200 --warmup 20
```

Outputs allocation throughput and latency (`alloc/s`, mean/p50/p95 ms) for Python, Rust, and Zig.

### allocate-task multi-run median

```bash
.venv/bin/python tools/benchmarks/bench_allocate_task_5run.py --runs 5 --duration 20 --seed-tickets 200 --warmup 20
```

Runs repeated benchmark trials and reports median metrics per implementation.

## Swarm parallel comparison

### single run

```bash
.venv/bin/python tools/swarm_parallel/swarm_compare.py
```

### 5-run median

```bash
.venv/bin/python tools/swarm_parallel/swarm_compare_5run.py
```

Both scripts call `tools/swarm_parallel/swarm_parallel_test.py` and compare Python/Rust/Zig operation throughput.

## Conformance utility

### fixture parity compare

```bash
.venv/bin/python tools/conformance/run_cli_compare.py
```

Runs selected conformance fixtures across Python/Rust/Zig and prints pass/fail matrix and first-line output diffs.

## Ticket seeding helpers

### queue workflow chain

```bash
.venv/bin/python tools/ticket_seed/create_queue_tickets.py
```

### queue parity roadmap chain

```bash
.venv/bin/python tools/ticket_seed/create_queue_parity_tickets.py
```

### atomic-write fix ticket helper

```bash
.venv/bin/python tools/ticket_seed/create_atomic_write_fix_ticket.py
```

These are convenience seeders for local planning workflows and are intended for maintainers.
