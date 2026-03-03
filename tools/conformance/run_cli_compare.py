#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PY = str(ROOT / ".venv/bin/python")
RUNNER = str(ROOT / "tests/conformance/runner.py")
FIXTURES = [
    "core_workflow.json",
    "reporting_graph_pick.json",
    "options_parity.json",
    "pick_scoring.json",
]
IMPLS = {
    "python-mt": f"{PY} {ROOT / 'mt.py'}",
    "rust-mt": str(ROOT / "ports/dist/rust-mt"),
    "zig-mt": str(ROOT / "ports/dist/zig-mt"),
}


if not (ROOT / "ports/dist/rust-mt").exists() or not (ROOT / "ports/dist/zig-mt").exists():
    subprocess.run(["make", "-C", "ports", "release"], cwd=ROOT, check=True)

results = {}
for impl, mt_cmd in IMPLS.items():
    impl_res = {}
    for fx in FIXTURES:
        env = dict(os.environ)
        env["MT_CMD"] = mt_cmd
        proc = subprocess.run(
            [PY, RUNNER, "--fixture", str(ROOT / "tests/conformance/fixtures" / fx)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            env=env,
        )
        impl_res[fx] = {"code": proc.returncode, "out": proc.stdout, "err": proc.stderr}
    results[impl] = impl_res

print("# Conformance comparison")
print("| Fixture | python-mt | rust-mt | zig-mt |")
print("|---|---:|---:|---:|")
for fx in FIXTURES:
    row = [fx]
    for impl in ("python-mt", "rust-mt", "zig-mt"):
        code = results[impl][fx]["code"]
        row.append("PASS" if code == 0 else f"FAIL({code})")
    print(f"| {row[0]} | {row[1]} | {row[2]} | {row[3]} |")

print("\n# Output diff summary (stdout+stderr)")
for fx in FIXTURES:
    base = (results["python-mt"][fx]["out"] + results["python-mt"][fx]["err"]).replace("\r\n", "\n")
    for impl in ("rust-mt", "zig-mt"):
        other = (results[impl][fx]["out"] + results[impl][fx]["err"]).replace("\r\n", "\n")
        same = base == other
        print(f"- {fx}: python vs {impl}: {'IDENTICAL' if same else 'DIFFERENT'}")
        if not same:
            b = base.splitlines()
            o = other.splitlines()
            m = max(len(b), len(o))
            for i in range(m):
                bl = b[i] if i < len(b) else "<NO LINE>"
                ol = o[i] if i < len(o) else "<NO LINE>"
                if bl != ol:
                    print(f"  first diff line {i + 1}")
                    print(f"  python: {bl}")
                    print(f"  {impl}: {ol}")
                    break
