#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shlex
import statistics
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Tuple

ROOT = Path(__file__).resolve().parents[2]
PY = ROOT / ".venv" / "bin" / "python"
VENV_PY = str(PY)
PY_MT = ROOT / "mt.py"
PORTS_MAKE = ROOT / "ports" / "Makefile"
RUST_BIN = ROOT / "ports" / "dist" / "rust-mt"
ZIG_BIN = ROOT / "ports" / "dist" / "zig-mt"
C_BIN = ROOT / "ports" / "dist" / "c-mt"


@dataclass
class PhaseResult:
    create_s: float
    update_s: float
    archive_s: float
    report_s: float

    @property
    def total_s(self) -> float:
        return self.create_s + self.update_s + self.archive_s + self.report_s


@dataclass
class ImplResult:
    name: str
    phase: PhaseResult


def run(cmd: List[str], cwd: Path, check: bool = True, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(cmd, cwd=str(cwd), capture_output=True, text=True, env=env)
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"Command failed ({proc.returncode}): {' '.join(shlex.quote(c) for c in cmd)}\\n"
            f"cwd={cwd}\\nstdout:\\n{proc.stdout}\\nstderr:\\n{proc.stderr}"
        )
    return proc


def zig_version_text() -> str:
    proc = subprocess.run(["zig", "version"], cwd=str(ROOT), capture_output=True, text=True)
    if proc.returncode != 0:
        return "unknown"
    return (proc.stdout or proc.stderr or "unknown").strip().splitlines()[0]


def ensure_binary(label: str, path: Path, make_target: str, warnings: List[str]) -> bool:
    if path.exists():
        return True
    try:
        run(["make", "-C", "ports", make_target], cwd=ROOT)
    except Exception as ex:
        msg = str(ex)
        if label == "zig-mt" and "build.zig.zon" in msg and "expected enum literal" in msg:
            warnings.append(
                f"{label}: build failed due to Zig/project format mismatch (zig version: {zig_version_text()}). "
                "Investigate build.zig.zon compatibility."
            )
        else:
            warnings.append(f"{label}: build failed ({ex})")
        return False
    if not path.exists():
        warnings.append(f"{label}: expected binary missing after build at {path}")
        return False
    return True


def resolve_impls() -> Tuple[List[Tuple[str, List[str], dict[str, str] | None]], List[str]]:
    warnings: List[str] = []
    impls: List[Tuple[str, List[str], dict[str, str] | None]] = [("python-mt", [str(PY), str(PY_MT)], None)]

    if ensure_binary("rust-mt", RUST_BIN, "rust", warnings):
        impls.append(("rust-mt", [str(RUST_BIN)], None))
    if ensure_binary("zig-mt", ZIG_BIN, "zig", warnings):
        impls.append(("zig-mt", [str(ZIG_BIN)], None))
    if ensure_binary("c-mt", C_BIN, "c", warnings):
        c_env = dict(os.environ)
        c_env["MT_PYTHON"] = VENV_PY
        impls.append(("c-mt", [str(C_BIN)], c_env))

    return impls, warnings


def measure(fn) -> float:
    t0 = time.perf_counter()
    fn()
    return time.perf_counter() - t0


def build_ids(count: int) -> List[str]:
    return [f"T-{i:06d}" for i in range(2, count + 2)]


def bench_impl(name: str, prefix: List[str], count: int, report_db: str, env: dict[str, str] | None = None) -> ImplResult:
    with tempfile.TemporaryDirectory(prefix=f"mt-bench-{name}-") as td:
        wd = Path(td)
        run(["git", "init", "-q"], cwd=wd)

        run([*prefix, "init"], cwd=wd, env=env)

        ids = build_ids(count)

        create_s = measure(lambda: create_tickets(prefix, wd, count, env=env))
        update_s = measure(lambda: update_tickets(prefix, wd, ids, env=env))
        archive_s = measure(lambda: archive_tickets(prefix, wd, ids, env=env))
        report_s = measure(lambda: report_board(prefix, wd, report_db, env=env))

        return ImplResult(name=name, phase=PhaseResult(create_s, update_s, archive_s, report_s))


def create_tickets(prefix: List[str], wd: Path, count: int, env: dict[str, str] | None = None) -> None:
    for i in range(1, count + 1):
        run([*prefix, "new", f"Perf ticket {i}"], cwd=wd, env=env)


def update_tickets(prefix: List[str], wd: Path, ids: Iterable[str], env: dict[str, str] | None = None) -> None:
    for tid in ids:
        run([*prefix, "comment", tid, "perf-update"], cwd=wd, env=env)


def archive_tickets(prefix: List[str], wd: Path, ids: Iterable[str], env: dict[str, str] | None = None) -> None:
    for tid in ids:
        run([*prefix, "done", tid, "--force"], cwd=wd, env=env)
        run([*prefix, "archive", tid, "--force"], cwd=wd, env=env)


def report_board(prefix: List[str], wd: Path, report_db: str, env: dict[str, str] | None = None) -> None:
    run([*prefix, "report", "--db", report_db, "--search", "Perf", "--limit", "10"], cwd=wd, env=env)


def fmt(seconds: float) -> str:
    return f"{seconds:.3f}s"


def ops_per_sec(count: int, seconds: float) -> float:
    if seconds <= 0:
        return 0.0
    return count / seconds


def render_markdown(results: List[ImplResult], count: int) -> str:
    lines = []
    lines.append(f"# 1000-ticket lifecycle benchmark (n={count})")
    lines.append("")
    lines.append("| Implementation | Create | Update | Archive | Report | Total | Create ops/s | Update ops/s | Archive ops/s |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for r in results:
        lines.append(
            "| {name} | {create} | {update} | {archive} | {report} | {total} | {cops:.1f} | {uops:.1f} | {aops:.1f} |".format(
                name=r.name,
                create=fmt(r.phase.create_s),
                update=fmt(r.phase.update_s),
                archive=fmt(r.phase.archive_s),
                report=fmt(r.phase.report_s),
                total=fmt(r.phase.total_s),
                cops=ops_per_sec(count, r.phase.create_s),
                uops=ops_per_sec(count, r.phase.update_s),
                aops=ops_per_sec(count, r.phase.archive_s),
            )
        )

    lines.append("")
    totals = [r.phase.total_s for r in results]
    fastest = min(results, key=lambda r: r.phase.total_s)
    slowest = max(results, key=lambda r: r.phase.total_s)
    lines.append(f"- Fastest total: **{fastest.name}** ({fmt(fastest.phase.total_s)})")
    lines.append(f"- Slowest total: **{slowest.name}** ({fmt(slowest.phase.total_s)})")
    lines.append(f"- Mean total: **{statistics.mean(totals):.3f}s**")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark 1000-ticket lifecycle across Python/Rust/Zig/C MuonTickets CLIs")
    parser.add_argument("--count", type=int, default=1000, help="Number of tickets to create/update/archive")
    parser.add_argument("--report-db", default="tickets/tickets_report.sqlite3", help="Report DB path relative to temp board")
    args = parser.parse_args()

    impls, warnings = resolve_impls()
    if len(impls) == 0:
        raise RuntimeError("No benchmark implementations available.")

    if warnings:
        print("Warnings:")
        for w in warnings:
            print(f"- {w}")
        print()

    results: List[ImplResult] = []
    for name, prefix, env in impls:
        print(f"Running benchmark for {name} ...")
        result = bench_impl(name, prefix, args.count, args.report_db, env=env)
        results.append(result)

    print()
    print(render_markdown(results, args.count))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
