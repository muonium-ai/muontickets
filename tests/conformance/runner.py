#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


def run_step(cmd_prefix: list[str], cwd: Path, step: dict[str, Any]) -> tuple[bool, str]:
    args = step.get("args") or []
    if not isinstance(args, list):
        return False, f"step {step.get('name', '<unnamed>')}: args must be a list"

    cmd = [*cmd_prefix, *[str(x) for x in args]]
    proc = subprocess.run(cmd, cwd=str(cwd), capture_output=True, text=True)

    name = str(step.get("name", "<unnamed>"))
    expect_exit = int(step.get("expect_exit", 0))
    out = proc.stdout or ""
    err = proc.stderr or ""
    combined = out + err

    if proc.returncode != expect_exit:
        return (
            False,
            f"[{name}] exit mismatch: got {proc.returncode}, expected {expect_exit}\n"
            f"cmd: {' '.join(cmd)}\nstdout:\n{out}\nstderr:\n{err}",
        )

    for needle in step.get("expect_stdout_contains", []) or []:
        if needle not in out:
            return (
                False,
                f"[{name}] missing stdout text: {needle!r}\n"
                f"cmd: {' '.join(cmd)}\nstdout:\n{out}\nstderr:\n{err}",
            )

    for needle in step.get("expect_stderr_contains", []) or []:
        if needle not in err:
            return (
                False,
                f"[{name}] missing stderr text: {needle!r}\n"
                f"cmd: {' '.join(cmd)}\nstdout:\n{out}\nstderr:\n{err}",
            )

    for needle in step.get("expect_output_contains", []) or []:
        if needle not in combined:
            return (
                False,
                f"[{name}] missing output text: {needle!r}\n"
                f"cmd: {' '.join(cmd)}\nstdout:\n{out}\nstderr:\n{err}",
            )

    return True, f"PASS [{name}]"


def run_fixture(fixture_path: Path, cmd_prefix: list[str]) -> int:
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    steps = fixture.get("steps") or []
    if not isinstance(steps, list) or not steps:
        print(f"invalid fixture {fixture_path}: expected non-empty steps list", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        subprocess.run(["git", "init", "-q"], cwd=str(root), check=True)

        failures: list[str] = []
        print(f"== fixture: {fixture.get('name', fixture_path.stem)} ==")
        for step in steps:
            ok, message = run_step(cmd_prefix, root, step)
            if ok:
                print(message)
            else:
                print(message, file=sys.stderr)
                failures.append(message)

        if failures:
            print(f"FAILED: {len(failures)} step(s)", file=sys.stderr)
            return 1

        print("OK: all steps passed")
        return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Run MuonTickets black-box conformance fixtures")
    parser.add_argument("--fixture", required=True, help="Path to fixture JSON file")
    args = parser.parse_args()

    fixture_path = Path(args.fixture)
    if not fixture_path.exists():
        print(f"fixture not found: {fixture_path}", file=sys.stderr)
        return 2

    cmd_env = os.environ.get("MT_CMD", "")
    if cmd_env.strip():
        cmd_prefix = shlex.split(cmd_env)
    else:
        cmd_prefix = [sys.executable, "mt.py"]

    return run_fixture(fixture_path, cmd_prefix)


if __name__ == "__main__":
    raise SystemExit(main())
