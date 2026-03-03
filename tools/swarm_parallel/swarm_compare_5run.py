#!/usr/bin/env python3
from __future__ import annotations

import re
import statistics
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWARM = ROOT / "tools/swarm_parallel/swarm_parallel_test.py"
PY = ROOT / ".venv/bin/python"

THREADS = 24
DURATION = 45
SEED = 42
SEED_TICKETS = 80
RUNS = 5

IMPLEMENTATIONS = {
    "python-mt.py": f"{PY} {ROOT / 'mt.py'}",
    "rust-mt": str(ROOT / "ports/dist/rust-mt"),
    "zig-mt": str(ROOT / "ports/dist/zig-mt"),
}

TOTALS_RE = re.compile(r"\|\s*Success=(\d+),\s*Fail=(\d+)\s*\|")


def run_one(mt_cmd: str) -> tuple[int, int, int, str]:
    cmd = [
        str(PY),
        str(SWARM),
        "--mt-cmd",
        mt_cmd,
        "--threads",
        str(THREADS),
        "--duration",
        str(DURATION),
        "--seed",
        str(SEED),
        "--seed-tickets",
        str(SEED_TICKETS),
    ]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    output = (proc.stdout or "") + (proc.stderr or "")
    match = TOTALS_RE.search(output)
    if not match:
        return proc.returncode, -1, -1, output
    success = int(match.group(1))
    fail = int(match.group(2))
    return proc.returncode, success, fail, output


def success_rate(success: int, fail: int) -> float:
    total = success + fail
    return (success / total * 100.0) if total > 0 else 0.0


def main() -> int:
    print("# Swarm 5-run median comparison")
    print(f"- runs={RUNS}, threads={THREADS}, duration={DURATION}s, seed={SEED}, seed_tickets={SEED_TICKETS}")
    print()

    summary: dict[str, dict[str, list[float] | list[int]]] = {}

    for name, mt_cmd in IMPLEMENTATIONS.items():
        print(f"Running {name} ({RUNS} runs)...")
        ops_per_sec_values: list[float] = []
        success_rates: list[float] = []
        exits: list[int] = []
        successes: list[int] = []
        fails: list[int] = []

        for run_idx in range(1, RUNS + 1):
            code, success, fail, output = run_one(mt_cmd)
            exits.append(code)
            successes.append(success)
            fails.append(fail)
            if code == 0 and success >= 0 and fail >= 0:
                total_ops = success + fail
                ops_per_sec_values.append(total_ops / DURATION)
                success_rates.append(success_rate(success, fail))
                print(
                    f"  run {run_idx}: exit={code} success={success} fail={fail} "
                    f"ops/sec={total_ops / DURATION:.2f} success_rate={success_rate(success, fail):.1f}%"
                )
            else:
                print(f"  run {run_idx}: exit={code} parse_failed")
                print(output[:1200])

        summary[name] = {
            "exits": exits,
            "success": successes,
            "fail": fails,
            "ops_per_sec": ops_per_sec_values,
            "success_rate": success_rates,
        }

    print("\n| Implementation | Median Ops/sec | Median Success Rate | Runs OK |")
    print("|---|---:|---:|---:|")

    ranking: list[tuple[str, float, float, int]] = []
    for name, data in summary.items():
        ops_vals = data["ops_per_sec"]
        sr_vals = data["success_rate"]
        runs_ok = len(ops_vals)
        med_ops = statistics.median(ops_vals) if ops_vals else 0.0
        med_sr = statistics.median(sr_vals) if sr_vals else 0.0
        ranking.append((name, med_ops, med_sr, runs_ok))

    ranking.sort(key=lambda row: row[1], reverse=True)
    for name, med_ops, med_sr, runs_ok in ranking:
        print(f"| {name} | {med_ops:.2f} | {med_sr:.1f}% | {runs_ok}/{RUNS} |")

    print("\n## Ranking by median ops/sec")
    for idx, (name, med_ops, med_sr, _runs_ok) in enumerate(ranking, start=1):
        print(f"{idx}. {name} — {med_ops:.2f} ops/sec (median success rate {med_sr:.1f}%)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
