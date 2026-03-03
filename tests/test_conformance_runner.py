import subprocess
import unittest
import shutil
import os
import tempfile
import textwrap
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PYTHON = ROOT / ".venv" / "bin" / "python"
MT_CLI = ROOT / "mt.py"
RUNNER = ROOT / "tests" / "conformance" / "runner.py"
FIXTURES = ROOT / "tests" / "conformance" / "fixtures"


class ConformanceRunnerTests(unittest.TestCase):
    def get_zig_bin(self) -> str:
        zig_bin = os.environ.get("ZIG_MT_BIN", "").strip()
        if zig_bin:
            return zig_bin

        default_bin = ROOT / "ports" / "zig-mt" / "zig-out" / "bin" / "mt-zig"
        if default_bin.exists():
            return str(default_bin)

        if shutil.which("zig"):
            build = subprocess.run(
                ["zig", "build"],
                cwd=str(ROOT / "ports" / "zig-mt"),
                capture_output=True,
                text=True,
            )
            self.assertEqual(build.returncode, 0, msg=f"stdout:\n{build.stdout}\nstderr:\n{build.stderr}")
            if default_bin.exists():
                return str(default_bin)

        self.skipTest("zig binary not available; set ZIG_MT_BIN or install zig")

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

    def test_options_parity_fixture(self) -> None:
        proc = self.run_fixture("options_parity.json")
        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("OK: all steps passed", proc.stdout)

    def test_zig_reporting_graph_pick_fixture(self) -> None:
        zig_bin = self.get_zig_bin()

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

    def test_zig_options_parity_fixture(self) -> None:
        zig_bin = self.get_zig_bin()

        fixture = FIXTURES / "options_parity.json"
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

    def test_zig_new_uses_template_defaults(self) -> None:
        zig_bin = self.get_zig_bin()

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=str(root), check=True)
            subprocess.run([zig_bin, "init"], cwd=str(root), check=True, capture_output=True, text=True)

            template = textwrap.dedent(
                """\
                ---
                id: T-000000
                title: Template: replace title
                status: blocked
                priority: p0
                type: research
                effort: l
                labels: [alpha, beta]
                tags: [zig, template]
                owner: agent-x
                created: 1970-01-01
                updated: 1970-01-01
                depends_on: [T-000123]
                branch: feat/template-defaults
                ---

                ## Goal
                Template goal body.

                ## Acceptance Criteria
                - [ ] Template AC

                ## Notes
                Template notes.
                """
            )
            (root / "tickets" / "ticket.template").write_text(template, encoding="utf-8")

            subprocess.run([zig_bin, "new", "From Template"], cwd=str(root), check=True, capture_output=True, text=True)
            shown = subprocess.run([zig_bin, "show", "T-000002"], cwd=str(root), check=True, capture_output=True, text=True)
            text = shown.stdout + shown.stderr

            self.assertIn("status: blocked", text)
            self.assertIn("priority: p0", text)
            self.assertIn("type: research", text)
            self.assertIn("effort: l", text)
            self.assertIn("labels: [\"alpha\", \"beta\"]", text)
            self.assertIn("tags: [\"zig\", \"template\"]", text)
            self.assertIn("owner: agent-x", text)
            self.assertIn("depends_on: [\"T-000123\"]", text)
            self.assertIn("branch: feat/template-defaults", text)
            self.assertIn("Template goal body.", text)


if __name__ == "__main__":
    unittest.main()
