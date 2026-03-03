#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import statistics
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PY = ROOT / ".venv" / "bin" / "python"
BENCH = ROOT / "tools" / "benchmarks" / "bench_allocate_task.py"

ROW_RE = re.compile(
    r"^\|\s*(python|rust|zig)\s*\|\s*(\d+)\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*$"
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run allocate-task benchmark 5+ times and report medians")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--duration", type=float, default=20.0)
    parser.add_argument("--seed-tickets", type=int, default=200)
    parser.add_argument("--warmup", type=int, default=20)
    args = parser.parse_args()

    cmd = [
        str(PY),
        str(BENCH),
        "--duration",
        str(args.duration),
        "--seed-tickets",
        str(args.seed_tickets),
        "--warmup",
        str(args.warmup),
    ]

    stats = {
        "python": {"alloc_s": [], "mean_ms": [], "median_ms": [], "p95_ms": []},
        "rust": {"alloc_s": [], "mean_ms": [], "median_ms": [], "p95_ms": []},
        "zig": {"alloc_s": [], "mean_ms": [], "median_ms": [], "p95_ms": []},
    }

    for i in range(args.runs):
        proc = subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True)
        output = (proc.stdout or "") + "\n" + (proc.stderr or "")
        if proc.returncode != 0:
            print(f"run {i + 1} failed exit={proc.returncode}")
            print(output[:3000])
            return proc.returncode

        found = set()
        for line in output.splitlines():
            m = ROW_RE.match(line.strip())
            if not m:
                continue
            impl = m.group(1)
            stats[impl]["alloc_s"].append(float(m.group(3)))
            stats[impl]["mean_ms"].append(float(m.group(4)))
            stats[impl]["median_ms"].append(float(m.group(5)))
            stats[impl]["p95_ms"].append(float(m.group(6)))
            found.add(impl)

        if found != {"python", "rust", "zig"}:
            print(f"run {i + 1} parse failure; found={found}")
            print(output)
            return 2

    print("# allocate-task 5-run median benchmark")
    print(f"- runs={args.runs}, duration={args.duration}s, seed_tickets={args.seed_tickets}, warmup={args.warmup}")
    print("| Impl | median alloc/s | median mean ms | median p50 ms | median p95 ms |")
    print("|---|---:|---:|---:|---:|")

    for impl in ["python", "rust", "zig"]:
        print(
            "| {impl} | {alloc_s:.2f} | {mean_ms:.2f} | {median_ms:.2f} | {p95_ms:.2f} |".format(
                impl=impl,
                alloc_s=statistics.median(stats[impl]["alloc_s"]),
                mean_ms=statistics.median(stats[impl]["mean_ms"]),
                median_ms=statistics.median(stats[impl]["median_ms"]),
                p95_ms=statistics.median(stats[impl]["p95_ms"]),
            )
        )

    print("\n# per-run alloc/s")
    for impl in ["python", "rust", "zig"]:
        values = ", ".join(f"{v:.2f}" for v in stats[impl]["alloc_s"])
        print(f"- {impl}: {values}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
