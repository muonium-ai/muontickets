#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import shlex
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PY = ROOT / ".venv" / "bin" / "python"
TID_RE = re.compile(r"T-\d{6}")


class BenchError(RuntimeError):
    pass


def run(cmd_prefix: list[str], cwd: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run([*cmd_prefix, *args], cwd=str(cwd), capture_output=True, text=True)


def parse_tid(output: str) -> str | None:
    text = output.strip()
    if not text:
        return None
    if text.startswith("{"):
        try:
            payload = json.loads(text)
            tid = payload.get("ticket_id")
            if isinstance(tid, str) and TID_RE.fullmatch(tid):
                return tid
        except json.JSONDecodeError:
            pass
    m = TID_RE.search(text)
    return m.group(0) if m else None


def setup_board(cmd_prefix: list[str], workspace: Path, seed_tickets: int) -> None:
    subprocess.run(["git", "init", "-q"], cwd=str(workspace), check=True)

    init_res = run(cmd_prefix, workspace, ["init"])
    if init_res.returncode != 0:
        raise BenchError(f"init failed: {init_res.stderr}\n{init_res.stdout}")

    for i in range(seed_tickets):
        new_res = run(
            cmd_prefix,
            workspace,
            ["new", f"Queue Bench Ticket {i+1}", "--label", "queue", "--type", "code", "--priority", "p1"],
        )
        if new_res.returncode != 0:
            raise BenchError(f"new failed at {i+1}: {new_res.stderr}\n{new_res.stdout}")


def benchmark_allocate(
    cmd_prefix: list[str],
    workspace: Path,
    duration: float,
    owner: str,
    warmup: int,
) -> dict[str, float | int]:
    for _ in range(warmup):
        alloc = run(cmd_prefix, workspace, ["allocate-task", "--owner", owner, "--json"])
        if alloc.returncode != 0:
            break
        tid = parse_tid(alloc.stdout)
        if not tid:
            break
        run(cmd_prefix, workspace, ["fail-task", tid, "--error", "warmup", "--retry-limit", "100000"])

    latencies_ms: list[float] = []
    ok = 0
    alloc_fail = 0
    fail_fail = 0

    end_at = time.perf_counter() + duration
    while time.perf_counter() < end_at:
        t0 = time.perf_counter()
        alloc = run(cmd_prefix, workspace, ["allocate-task", "--owner", owner, "--json"])
        t1 = time.perf_counter()
        latencies_ms.append((t1 - t0) * 1000.0)

        if alloc.returncode != 0:
            alloc_fail += 1
            continue

        tid = parse_tid(alloc.stdout)
        if not tid:
            alloc_fail += 1
            continue

        fail = run(cmd_prefix, workspace, ["fail-task", tid, "--error", "bench", "--retry-limit", "100000"])
        if fail.returncode != 0:
            fail_fail += 1
            continue

        ok += 1

    elapsed = duration
    p95 = statistics.quantiles(latencies_ms, n=100)[94] if len(latencies_ms) >= 100 else (max(latencies_ms) if latencies_ms else 0.0)

    return {
        "allocate_ok": ok,
        "allocate_fail": alloc_fail,
        "fail_task_fail": fail_fail,
        "elapsed_s": elapsed,
        "alloc_ops_per_s": (ok / elapsed) if elapsed > 0 else 0.0,
        "alloc_mean_ms": statistics.mean(latencies_ms) if latencies_ms else 0.0,
        "alloc_median_ms": statistics.median(latencies_ms) if latencies_ms else 0.0,
        "alloc_p95_ms": p95,
        "samples": len(latencies_ms),
    }


def run_impl(name: str, mt_cmd: str, duration: float, seed_tickets: int, warmup: int) -> tuple[str, dict[str, float | int] | str]:
    cmd_prefix = shlex.split(mt_cmd)
    with tempfile.TemporaryDirectory(prefix=f"mt-alloc-bench-{name}-") as td:
        ws = Path(td)
        try:
            setup_board(cmd_prefix, ws, seed_tickets)
            metrics = benchmark_allocate(cmd_prefix, ws, duration=duration, owner="bench-agent", warmup=warmup)
            return name, metrics
        except Exception as exc:  # noqa: BLE001
            return name, str(exc)


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark allocate-task throughput/latency across implementations")
    parser.add_argument("--duration", type=float, default=20.0)
    parser.add_argument("--seed-tickets", type=int, default=200)
    parser.add_argument("--warmup", type=int, default=20)
    parser.add_argument(
        "--python-cmd",
        default=f"{PY} {ROOT / 'mt.py'}",
    )
    parser.add_argument(
        "--rust-cmd",
        default=str(ROOT / "ports/rust-mt/target/debug/mt-port"),
    )
    parser.add_argument(
        "--zig-cmd",
        default=str(ROOT / "ports/zig-mt/zig-out/bin/mt-zig"),
    )
    args = parser.parse_args()

    impls = [
        ("python", args.python_cmd),
        ("rust", args.rust_cmd),
        ("zig", args.zig_cmd),
    ]

    print("# allocate-task benchmark")
    print(f"- duration={args.duration}s")
    print(f"- seed_tickets={args.seed_tickets}")
    print(f"- warmup={args.warmup}")
    print()

    rows: list[tuple[str, dict[str, float | int] | str]] = []
    for name, cmd in impls:
        print(f"Running {name} ...")
        rows.append(run_impl(name, cmd, args.duration, args.seed_tickets, args.warmup))

    print("\n| Impl | alloc ok | alloc/s | mean ms | median ms | p95 ms | alloc fail | fail-task fail |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|")

    for name, result in rows:
        if isinstance(result, str):
            print(f"| {name} | error | - | - | - | - | - | - |")
            print(f"\n{name} error: {result}\n")
            continue

        print(
            "| {name} | {ok} | {ops:.2f} | {mean:.2f} | {med:.2f} | {p95:.2f} | {af} | {ff} |".format(
                name=name,
                ok=result["allocate_ok"],
                ops=result["alloc_ops_per_s"],
                mean=result["alloc_mean_ms"],
                med=result["alloc_median_ms"],
                p95=result["alloc_p95_ms"],
                af=result["allocate_fail"],
                ff=result["fail_task_fail"],
            )
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
