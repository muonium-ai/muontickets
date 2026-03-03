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
    return proc.stdout.strip()


def new_ticket(title: str, ttype: str, priority: str, effort: str, labels: list[str], goal: str, depends_on: str | None = None) -> str:
    cmd = ["new", title, "--type", ttype, "--priority", priority, "--effort", effort, "--goal", goal]
    for label in labels:
        cmd.extend(["--label", label])
    if depends_on:
        cmd.extend(["--depends-on", depends_on])
    out = run(*cmd)
    match = ID_RE.search(out)
    if not match:
        raise RuntimeError(f"Unable to parse ticket id from output: {out}")
    return match.group(1)


def comment(ticket_id: str, text: str) -> None:
    run("comment", ticket_id, text)


if __name__ == "__main__":
    parent = new_ticket(
        "Design queue-style allocate-task model with lease/retry/error routing",
        ttype="spec",
        priority="p0",
        effort="m",
        labels=["queue", "allocation"],
        goal="Define the end-to-end queue semantics for allocate-task including lease expiry, retries, and error escalation.",
    )

    t1 = new_ticket(
        "Implement allocate-task command returning ticket id",
        ttype="code",
        priority="p0",
        effort="m",
        labels=["queue", "allocation"],
        goal="Add allocate-task command that atomically assigns a claimable ticket and returns ticket id plus metadata for agent execution.",
        depends_on=parent,
    )

    t2 = new_ticket(
        "Add lease validity window and stale-reallocation logging",
        ttype="code",
        priority="p0",
        effort="m",
        labels=["queue", "lease"],
        goal="Enforce default 5-minute lease, allow re-allocation after expiry, and log stale-lease incidents for investigation.",
        depends_on=t1,
    )

    t3 = new_ticket(
        "Add retry count and retry-limit escalation to errors folder",
        ttype="code",
        priority="p0",
        effort="m",
        labels=["queue", "retry"],
        goal="Track retry_count per ticket, enforce retry_limit, and move exhausted items to errors bucket for manual resolution.",
        depends_on=t2,
    )

    t4 = new_ticket(
        "Add tests for allocate-task lease expiry and retry behavior",
        ttype="tests",
        priority="p1",
        effort="m",
        labels=["queue", "tests"],
        goal="Add deterministic tests for allocation, lease timeout reallocation, retry increments, retry-limit handling, and error routing.",
        depends_on=t3,
    )

    t5 = new_ticket(
        "Update objectives template and skills docs for queue workflow",
        ttype="docs",
        priority="p1",
        effort="s",
        labels=["docs", "queue"],
        goal="Update project objectives, ticket.template, and skills guide to document allocate-task lifecycle and operator procedures.",
        depends_on=t4,
    )

    comment(parent, "User direction captured: move from contention-heavy pick toward queue semantics (allocate-once, lease timeout, retry with limits, error/manual-resolution path).")
    comment(t2, "Lease target from user request: default validity window 5 minutes; stale lease should trigger re-allocation eligibility and incident logging.")
    comment(t3, "Error handling requirement: retry counter + retry limit; on exhaustion route to errors bucket/folder similar to archive for manual follow-up.")

    print("Created tickets:")
    for tid in [parent, t1, t2, t3, t4, t5]:
        print(tid)
