#!/usr/bin/env python3
from __future__ import annotations

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PY = ROOT / ".venv/bin/python"
MT = ROOT / "mt.py"
ID_RE = re.compile(r"(T-\d{6})\.md")


def run(*args: str) -> str:
    proc = subprocess.run([str(PY), str(MT), *args], cwd=ROOT, capture_output=True, text=True, check=True)
    return (proc.stdout or "").strip()


def new_ticket(title: str, ttype: str, priority: str, effort: str, labels: list[str], goal: str, depends_on: str | None = None) -> str:
    cmd = ["new", title, "--type", ttype, "--priority", priority, "--effort", effort, "--goal", goal]
    for label in labels:
        cmd.extend(["--label", label])
    if depends_on:
        cmd.extend(["--depends-on", depends_on])
    out = run(*cmd)
    m = ID_RE.search(out)
    if not m:
        raise RuntimeError(f"Could not parse ticket id from output: {out}")
    return m.group(1)


def comment(ticket_id: str, text: str) -> None:
    run("comment", ticket_id, text)


if __name__ == "__main__":
    parent = new_ticket(
        "Queue parity roadmap for Rust and Zig against Python",
        ttype="spec",
        priority="p0",
        effort="m",
        labels=["parity", "queue", "ports"],
        goal="Define and track command/behavior parity for queue features (allocate-task, fail-task, lease expiry, retries, errors folder) across rust-mt and zig-mt.",
    )

    t1 = new_ticket(
        "Add queue conformance fixtures for allocate-task and fail-task",
        ttype="tests",
        priority="p0",
        effort="m",
        labels=["parity", "queue", "tests"],
        goal="Create black-box fixtures that encode Python queue behavior for allocation leases, stale reallocation logging, retry increments, and retry-limit errors routing.",
        depends_on=parent,
    )

    t2 = new_ticket(
        "Implement Rust allocate-task command and lease metadata parity",
        ttype="code",
        priority="p0",
        effort="m",
        labels=["parity", "queue", "rust"],
        goal="Add allocate-task in rust-mt with Python-equivalent filters, lease-minutes default 5, stale lease reallocation semantics, and incidents logging.",
        depends_on=t1,
    )

    t3 = new_ticket(
        "Implement Rust fail-task retry-limit and errors-folder parity",
        ttype="code",
        priority="p0",
        effort="m",
        labels=["parity", "queue", "rust"],
        goal="Add fail-task in rust-mt with retry_count/retry_limit behavior and escalation to tickets/errors matching Python.",
        depends_on=t2,
    )

    t4 = new_ticket(
        "Implement Zig allocate-task command and lease metadata parity",
        ttype="code",
        priority="p0",
        effort="m",
        labels=["parity", "queue", "zig"],
        goal="Add allocate-task in zig-mt with Python-equivalent filters, lease-minutes default 5, stale lease reallocation semantics, and incidents logging.",
        depends_on=t3,
    )

    t5 = new_ticket(
        "Implement Zig fail-task retry-limit and errors-folder parity",
        ttype="code",
        priority="p0",
        effort="m",
        labels=["parity", "queue", "zig"],
        goal="Add fail-task in zig-mt with retry_count/retry_limit behavior and escalation to tickets/errors matching Python.",
        depends_on=t4,
    )

    t6 = new_ticket(
        "Align Rust and Zig schema/template fields for queue metadata",
        ttype="refactor",
        priority="p1",
        effort="s",
        labels=["parity", "queue", "schema"],
        goal="Ensure both ports read/write the same queue metadata fields as Python (allocated_to, allocated_at, lease_expires_at, retry_count, retry_limit, last_error, last_attempted_at).",
        depends_on=t5,
    )

    t7 = new_ticket(
        "Update parity report and docs for queue command support matrix",
        ttype="docs",
        priority="p1",
        effort="s",
        labels=["parity", "queue", "docs"],
        goal="Update PARITY_REPORT and relevant docs with queue command parity status and known deviations across Python/Rust/Zig.",
        depends_on=t6,
    )

    comment(parent, "Created queue parity execution chain covering tests, Rust implementation, Zig implementation, schema/template alignment, and final documentation parity update.")
    comment(t1, "Fixture scope should include stdout/stderr stream parity and deterministic behavior checks for stale-lease and retry-limit transitions.")

    print("Created tickets:")
    for tid in [parent, t1, t2, t3, t4, t5, t6, t7]:
        print(tid)
