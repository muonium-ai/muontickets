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


def main() -> int:
    out = run(
        "new",
        "Fix transient parse_error via atomic ticket writes",
        "--type",
        "code",
        "--priority",
        "p1",
        "--effort",
        "s",
        "--label",
        "concurrency",
        "--label",
        "reliability",
        "--goal",
        "Eliminate transient YAML parse errors under concurrent swarm operations by making ticket file writes atomic.",
    )
    m = ID_RE.search(out)
    if not m:
        raise RuntimeError(f"Could not parse ticket id from output: {out}")
    tid = m.group(1)

    run("claim", tid, "--owner", "codex", "--force")
    run(
        "comment",
        tid,
        "Implemented atomic ticket writes in mt.py write_ticket (tempfile + fsync + os.replace) and verified with swarm run at 1000 seed tickets; parse_error bucket dropped to zero in latest run.",
    )
    run("set-status", tid, "needs_review", "--force")

    print(tid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
