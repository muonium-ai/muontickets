# Swarm Performance Benchmark

Date: 2026-03-03  
Workspace: `/Users/senthil/github/muonium-ai/muontickets`

## Scope
This document captures a baseline performance comparison for swarm-style concurrent ticket operations across:
- Python CLI (`mt.py`)
- Rust CLI (`ports/dist/rust-mt`)
- Zig CLI (`ports/dist/zig-mt`)

`mp.py` was requested originally, but it does not exist in this repository. Python baseline used: `mt.py`.

## Benchmark Configuration (same settings for all runs)
- Threads: 24
- Duration: 45 seconds
- Seed: 42
- Seed tickets: 80
- Swarm driver: `tools/swarm_parallel/swarm_parallel_test.py`

---

## Snapshot Result (single run)
From `tmp/swarm_compare.py`:

| Implementation | Exit | Success | Fail | Success Rate | Ops Total | Ops/sec |
|---|---:|---:|---:|---:|---:|---:|
| python-mt.py | 0 | 3501 | 304 | 92.0% | 3805 | 84.56 |
| rust-mt | 0 | 11161 | 2463 | 81.9% | 13624 | 302.76 |
| zig-mt | 0 | 6823 | 1310 | 83.9% | 8133 | 180.73 |

---

## Stable Result (5-run median comparison)
From `tmp/swarm_compare_5run.py`.

### Per-run raw results

#### python-mt.py
| Run | Exit | Success | Fail | Ops/sec | Success Rate |
|---|---:|---:|---:|---:|---:|
| 1 | 0 | 3268 | 327 | 79.89 | 90.9% |
| 2 | 0 | 3368 | 349 | 82.60 | 90.6% |
| 3 | 0 | 3199 | 272 | 77.13 | 92.2% |
| 4 | 0 | 3203 | 263 | 77.02 | 92.4% |
| 5 | 0 | 2900 | 306 | 71.24 | 90.5% |

#### rust-mt
| Run | Exit | Success | Fail | Ops/sec | Success Rate |
|---|---:|---:|---:|---:|---:|
| 1 | 0 | 9538 | 2787 | 273.89 | 77.4% |
| 2 | 0 | 10312 | 2280 | 279.82 | 81.9% |
| 3 | 0 | 10038 | 2577 | 280.33 | 79.6% |
| 4 | 0 | 9565 | 2897 | 276.93 | 76.8% |
| 5 | 0 | 9620 | 2603 | 271.62 | 78.7% |

#### zig-mt
| Run | Exit | Success | Fail | Ops/sec | Success Rate |
|---|---:|---:|---:|---:|---:|
| 1 | 0 | 6509 | 1241 | 172.22 | 84.0% |
| 2 | 0 | 6421 | 1219 | 169.78 | 84.0% |
| 3 | 0 | 6360 | 1209 | 168.20 | 84.0% |
| 4 | 0 | 6331 | 1205 | 167.47 | 84.0% |
| 5 | 0 | 6353 | 1203 | 167.91 | 84.1% |

### Median summary
| Implementation | Median Ops/sec | Median Success Rate | Runs OK |
|---|---:|---:|---:|
| rust-mt | 276.93 | 78.7% | 5/5 |
| zig-mt | 168.20 | 84.0% | 5/5 |
| python-mt.py | 77.13 | 90.9% | 5/5 |

### Ranking by median throughput
1. rust-mt — 276.93 ops/sec (median success rate 78.7%)
2. zig-mt — 168.20 ops/sec (median success rate 84.0%)
3. python-mt.py — 77.13 ops/sec (median success rate 90.9%)

---

## Analysis and interpretation
- Rust delivers the highest throughput, roughly **1.65×** Zig and **3.59×** Python by median ops/sec.
- Zig is a middle ground: notably faster than Python, with higher median success rate than Rust under this stress profile.
- Python has the lowest throughput but the highest success rate, suggesting stronger operational correctness/stability at this concurrency/load setting.
- The throughput-vs-success trade-off is visible across all three implementations and should be tracked over time.

## Baseline for future comparisons
Use this report as baseline and re-run with identical settings:

```bash
.venv/bin/python tools/swarm_parallel/swarm_parallel_test.py --threads 24 --duration 45 --seed 42 --seed-tickets 80
```

For side-by-side comparison scripts used in this session:

```bash
.venv/bin/python tmp/swarm_compare.py
.venv/bin/python tmp/swarm_compare_5run.py
```

## Suggested future tracking fields
- CPU model / core count
- OS and kernel version
- Binary build mode and compiler versions
- p50/p95 command latency by operation type
- Failure reason breakdown by operation
