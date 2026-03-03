import subprocess
import unittest
import shutil
import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PYTHON = ROOT / ".venv" / "bin" / "python"
MT_CLI = ROOT / "mt.py"
RUNNER = ROOT / "tests" / "conformance" / "runner.py"
FIXTURES = ROOT / "tests" / "conformance" / "fixtures"


class ConformanceRunnerTests(unittest.TestCase):
    def run_fixture(self, fixture_name: str) -> subprocess.CompletedProcess[str]:
        fixture = FIXTURES / fixture_name
        env = dict(**__import__("os").environ)
        env["MT_CMD"] = f"{PYTHON} {MT_CLI}"
        return subprocess.run(
            [str(PYTHON), str(RUNNER), "--fixture", str(fixture)],
            cwd=str(ROOT),
            env=env,
            capture_output=True,
            text=True,
        )

    def test_core_workflow_fixture(self) -> None:
        proc = self.run_fixture("core_workflow.json")
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_reporting_graph_pick_fixture(self) -> None:
        proc = self.run_fixture("reporting_graph_pick.json")
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_zig_reporting_graph_pick_fixture(self) -> None:
        zig_bin = os.environ.get("ZIG_MT_BIN", "").strip()
        if not zig_bin:
            default_bin = ROOT / "ports" / "zig-mt" / "zig-out" / "bin" / "mt-zig"
            if default_bin.exists():
                zig_bin = str(default_bin)
            elif shutil.which("zig"):
                build = subprocess.run(
                    ["zig", "build"],
                    cwd=str(ROOT / "ports" / "zig-mt"),
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(build.returncode, 0, msg=f"stdout:\n{build.stdout}\nstderr:\n{build.stderr}")
                if default_bin.exists():
                    zig_bin = str(default_bin)
        if not zig_bin:
            self.skipTest("zig binary not available; set ZIG_MT_BIN or install zig")

        fixture = FIXTURES / "zig_reporting_graph_pick.json"
        env = dict(**__import__("os").environ)
        env["MT_CMD"] = zig_bin
        proc = subprocess.run(
            [str(PYTHON), str(RUNNER), "--fixture", str(fixture)],
            cwd=str(ROOT),
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)


if __name__ == "__main__":
    unittest.main()
