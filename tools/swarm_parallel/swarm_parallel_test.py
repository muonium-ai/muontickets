#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import random
import re
import shlex
import subprocess
import tempfile
import threading
import time
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MT_CMD = f"{ROOT / '.venv/bin/python'} {ROOT / 'mt.py'}"
ID_RE = re.compile(r"^T-\d{6}$")


@dataclass
class CmdResult:
    code: int
    out: str
    err: str


class Runner:
    def __init__(self, cmd_prefix: Sequence[str], cwd: Path):
        self.cmd_prefix = list(cmd_prefix)
        self.cwd = cwd

    def run(self, args: Sequence[str]) -> CmdResult:
        proc = subprocess.run(
            [*self.cmd_prefix, *args],
            cwd=str(self.cwd),
            capture_output=True,
            text=True,
        )
        return CmdResult(proc.returncode, proc.stdout, proc.stderr)


class Metrics:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.ok = Counter()
        self.fail = Counter()

    def mark(self, key: str, success: bool) -> None:
        with self.lock:
            if success:
                self.ok[key] += 1
            else:
                self.fail[key] += 1

    def snapshot(self) -> Tuple[Counter, Counter]:
        with self.lock:
            return Counter(self.ok), Counter(self.fail)


ROLE_TYPES: Dict[str, List[str]] = {
    "design-agent": ["spec", "docs"],
    "code-agent": ["code", "refactor", "chore"],
    "review-agent": ["tests", "docs"],
    "security-agent": ["code", "tests", "refactor"],
}
ROLE_LABELS: Dict[str, List[str]] = {
    "design-agent": ["design"],
    "code-agent": ["feature"],
    "review-agent": ["review"],
    "security-agent": ["security"],
}


def parse_ids(ls_output: str) -> List[str]:
    ids: List[str] = []
    for line in ls_output.splitlines():
        tok = line.strip().split(" ", 1)[0]
        if ID_RE.match(tok):
            ids.append(tok)
    return ids


def parse_id_from_new(output: str) -> Optional[str]:
    for token in re.findall(r"T-\d{6}", output):
        if ID_RE.match(token):
            return token
    return None


def create_ticket_for_role(runner: Runner, role: str, rng: random.Random, metrics: Metrics) -> None:
    typ = rng.choice(ROLE_TYPES[role])
    label = rng.choice(ROLE_LABELS[role])
    title = f"{role} task {rng.randint(1, 999999)}"
    result = runner.run(["new", title, "--type", typ, "--priority", rng.choice(["p0", "p1", "p2"]), "--label", label])
    metrics.mark("create", result.code == 0)


def dispatcher_loop(
    runner: Runner,
    stop_event: threading.Event,
    rng_seed: int,
    metrics: Metrics,
    poll_interval: float,
) -> None:
    rng = random.Random(rng_seed)
    roles = list(ROLE_TYPES.keys())
    while not stop_event.is_set():
        res = runner.run(["ls", "--status", "ready"])
        if res.code != 0:
            metrics.mark("dispatch_scan", False)
            time.sleep(poll_interval)
            continue
        ready_ids = parse_ids(res.out)
        metrics.mark("dispatch_scan", True)
        rng.shuffle(ready_ids)
        for tid in ready_ids[:10]:
            show = runner.run(["show", tid])
            if show.code != 0:
                metrics.mark("dispatch_show", False)
                continue
            metrics.mark("dispatch_show", True)
            text = show.out + show.err
            assigned_role: Optional[str] = None
            # Label-directed first, then type fallback.
            for role in roles:
                if any(f"{label}" in text for label in ROLE_LABELS[role]):
                    assigned_role = role
                    break
            if assigned_role is None:
                for role in roles:
                    if any(f"type: {t}" in text for t in ROLE_TYPES[role]):
                        assigned_role = role
                        break
            if assigned_role is None:
                assigned_role = rng.choice(roles)

            claim = runner.run(["claim", tid, "--owner", assigned_role, "--ignore-deps"])
            metrics.mark("dispatch_claim", claim.code == 0)
        time.sleep(poll_interval)


def list_owned_claimed(runner: Runner, owner: str) -> List[str]:
    res = runner.run(["ls", "--status", "claimed", "--owner", owner])
    if res.code != 0:
        return []
    return parse_ids(res.out)


def list_status_ids(runner: Runner, status: str) -> List[str]:
    res = runner.run(["ls", "--status", status])
    if res.code != 0:
        return []
    return parse_ids(res.out)


def worker_loop(
    runner: Runner,
    role: str,
    stop_event: threading.Event,
    rng_seed: int,
    metrics: Metrics,
) -> None:
    rng = random.Random(rng_seed)
    role_types = ROLE_TYPES[role]

    while not stop_event.is_set():
        op = rng.choice(["pick", "create", "comment", "needs_review", "done", "archive"])

        if op == "pick":
            chosen_type = rng.choice(role_types)
            pick = runner.run([
                "pick",
                "--owner",
                role,
                "--type",
                chosen_type,
                "--ignore-deps",
                "--max-claimed-per-owner",
                "5",
            ])
            metrics.mark("pick", pick.code == 0)

        elif op == "create":
            create_ticket_for_role(runner, role, rng, metrics)

        elif op == "comment":
            owned = list_owned_claimed(runner, role)
            if owned:
                tid = rng.choice(owned)
                result = runner.run(["comment", tid, f"progress from {role}"])
                metrics.mark("comment", result.code == 0)
            else:
                metrics.mark("comment", True)

        elif op == "needs_review":
            owned = list_owned_claimed(runner, role)
            if owned:
                tid = rng.choice(owned)
                result = runner.run(["set-status", tid, "needs_review", "--force"])
                metrics.mark("set_needs_review", result.code == 0)
            else:
                metrics.mark("set_needs_review", True)

        elif op == "done":
            review_ids = list_status_ids(runner, "needs_review")
            if review_ids:
                tid = rng.choice(review_ids)
                result = runner.run(["done", tid, "--force"])
                metrics.mark("done", result.code == 0)
            else:
                metrics.mark("done", True)

        elif op == "archive":
            done_ids = list_status_ids(runner, "done")
            if done_ids:
                tid = rng.choice(done_ids)
                result = runner.run(["archive", tid, "--force"])
                metrics.mark("archive", result.code == 0)
            else:
                metrics.mark("archive", True)

        time.sleep(rng.uniform(0.01, 0.08))


def seed_board(runner: Runner, count: int, rng: random.Random, metrics: Metrics) -> None:
    roles = list(ROLE_TYPES.keys())
    for _ in range(count):
        create_ticket_for_role(runner, rng.choice(roles), rng, metrics)


def markdown_report(ok: Counter, fail: Counter, elapsed: float, threads: int, duration: int) -> str:
    ops = sorted(set(ok.keys()) | set(fail.keys()))
    lines = []
    lines.append("# Swarm Parallel Test Report")
    lines.append("")
    lines.append(f"- Duration target: **{duration}s**")
    lines.append(f"- Actual elapsed: **{elapsed:.2f}s**")
    lines.append(f"- Worker threads: **{threads}** (+1 dispatcher)")
    lines.append("")
    lines.append("| Operation | Success | Fail | Success Rate |")
    lines.append("|---|---:|---:|---:|")
    for op in ops:
        s = ok.get(op, 0)
        f = fail.get(op, 0)
        total = s + f
        rate = (s / total * 100.0) if total else 100.0
        lines.append(f"| {op} | {s} | {f} | {rate:.1f}% |")
    lines.append("")
    lines.append("| Totals |")
    lines.append("|---|")
    lines.append(f"| Success={sum(ok.values())}, Fail={sum(fail.values())} |")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Parallel MuonTickets swarm simulation with role-based assignment")
    parser.add_argument("--mt-cmd", default=DEFAULT_MT_CMD, help="CLI command prefix to run mt (e.g. '.venv/bin/python mt.py' or 'ports/dist/rust-mt')")
    parser.add_argument("--threads", type=int, default=16, help="Number of worker threads")
    parser.add_argument("--duration", type=int, default=30, help="Test duration in seconds")
    parser.add_argument("--seed", type=int, default=42, help="Random seed")
    parser.add_argument("--seed-tickets", type=int, default=60, help="Initial ready tickets")
    parser.add_argument("--dispatch-interval", type=float, default=0.2, help="Dispatcher polling interval seconds")
    args = parser.parse_args()

    mt_cmd = shlex.split(args.mt_cmd)
    rng = random.Random(args.seed)
    metrics = Metrics()

    with tempfile.TemporaryDirectory(prefix="mt-swarm-") as td:
        board = Path(td)
        subprocess.run(["git", "init", "-q"], cwd=board, check=True)
        runner = Runner(mt_cmd, board)

        init = runner.run(["init"])
        if init.code != 0:
            raise SystemExit(f"init failed:\n{init.out}\n{init.err}")

        seed_board(runner, args.seed_tickets, rng, metrics)

        stop_event = threading.Event()

        dispatcher = threading.Thread(
            target=dispatcher_loop,
            args=(runner, stop_event, args.seed + 1000, metrics, args.dispatch_interval),
            daemon=True,
            name="dispatcher",
        )
        dispatcher.start()

        roles = list(ROLE_TYPES.keys())
        workers: List[threading.Thread] = []
        for i in range(args.threads):
            role = roles[i % len(roles)]
            t = threading.Thread(
                target=worker_loop,
                args=(runner, role, stop_event, args.seed + i + 1, metrics),
                daemon=True,
                name=f"worker-{i}-{role}",
            )
            workers.append(t)
            t.start()

        t0 = time.perf_counter()
        time.sleep(max(args.duration, 1))
        stop_event.set()

        for t in workers:
            t.join(timeout=2.0)
        dispatcher.join(timeout=2.0)

        elapsed = time.perf_counter() - t0

        # Final board checks and report generation.
        validate = runner.run(["validate", "--max-claimed-per-owner", "20"])
        metrics.mark("final_validate", validate.code == 0)
        report = runner.run(["report", "--db", "tickets/tickets_report.sqlite3", "--search", "task", "--limit", "20"])
        metrics.mark("final_report", report.code == 0)

        ok, fail = metrics.snapshot()
        print(markdown_report(ok, fail, elapsed, args.threads, args.duration))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
