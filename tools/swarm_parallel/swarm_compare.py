#!/usr/bin/env python3
from __future__ import annotations

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWARM = ROOT / "tools/swarm_parallel/swarm_parallel_test.py"
PY = ROOT / ".venv/bin/python"

THREADS = 24
DURATION = 45
SEED = 42
SEED_TICKETS = 80

IMPLEMENTATIONS = {
    "python-mt.py": f"{PY} {ROOT / 'mt.py'}",
    "rust-mt": str(ROOT / "ports/dist/rust-mt"),
    "zig-mt": str(ROOT / "ports/dist/zig-mt"),
}

TOTALS_RE = re.compile(r"\|\s*Success=(\d+),\s*Fail=(\d+)\s*\|")


def run_one(name: str, mt_cmd: str) -> tuple[int, int, int, str]:
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

    success = fail = -1
    m = TOTALS_RE.search(output)
    if m:
        success = int(m.group(1))
        fail = int(m.group(2))

    return proc.returncode, success, fail, output


def rate(success: int, fail: int) -> float:
    total = success + fail
    if success < 0 or fail < 0 or total <= 0:
        return 0.0
    return success / total * 100.0


def main() -> int:
    results: list[tuple[str, int, int, int, float]] = []
    failures: list[tuple[str, str]] = []

    print("# Swarm performance comparison")
    print(f"- threads={THREADS}, duration={DURATION}s, seed={SEED}, seed_tickets={SEED_TICKETS}")
    print()

    for name, mt_cmd in IMPLEMENTATIONS.items():
        print(f"Running {name} ...")
        code, success, fail, output = run_one(name, mt_cmd)
        success_rate = rate(success, fail)
        results.append((name, code, success, fail, success_rate))
        if code != 0:
            failures.append((name, output))

    print("\n| Implementation | Exit | Success | Fail | Success Rate |")
    print("|---|---:|---:|---:|---:|")
    for name, code, success, fail, success_rate in results:
        print(f"| {name} | {code} | {success} | {fail} | {success_rate:.1f}% |")

    comparable = [r for r in results if r[2] >= 0 and r[3] >= 0 and (r[2] + r[3]) > 0]
    if comparable:
        print("\n| Implementation | Ops Total | Ops/sec |")
        print("|---|---:|---:|")
        for name, _code, success, fail, _sr in comparable:
            total = success + fail
            ops_per_sec = total / DURATION
            print(f"| {name} | {total} | {ops_per_sec:.2f} |")

    if failures:
        print("\n# Non-zero exit details")
        for name, out in failures:
            print(f"\n## {name}\n")
            print(out[:3000])

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
