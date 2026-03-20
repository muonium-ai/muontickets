import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "mt.py"
PYTHON = ROOT / ".venv" / "bin" / "python"


class DependencyCycleValidationTests(unittest.TestCase):
    """Tests for T-000116: self-dependency and cycle detection."""

    def run_cli(self, cwd, *args):
        return subprocess.run(
            [str(PYTHON), str(CLI), *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
        )

    def _init_repo(self, workdir):
        subprocess.run(["git", "init", "-q"], cwd=str(workdir), check=True)
        self.assertEqual(self.run_cli(workdir, "init").returncode, 0)
        # init creates T-000001 as example; new tickets start at T-000002

    def _set_depends_on(self, ticket_path, deps):
        """Set depends_on to given list of ticket IDs."""
        text = Path(ticket_path).read_text()
        if not deps:
            dep_block = "depends_on: []"
        else:
            lines = ["depends_on:"] + [f"- {d}" for d in deps]
            dep_block = "\n".join(lines)
        new_text = re.sub(
            r"^depends_on:.*?(?=\n[a-z]|\n---|\Z)",
            dep_block + "\n",
            text,
            count=1,
            flags=re.MULTILINE | re.DOTALL,
        )
        Path(ticket_path).write_text(new_text)

    def test_validate_detects_self_dependency(self):
        """A ticket that depends on itself must be flagged."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)
            self.run_cli(workdir, "new", "Alpha")
            ticket = workdir / "tickets" / "T-000002.md"
            self._set_depends_on(ticket, ["T-000002"])

            r = self.run_cli(workdir, "validate")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("T-000002 depends_on itself", r.stderr)

    def test_validate_detects_two_ticket_cycle(self):
        """A->B->A cycle must be detected."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)
            self.run_cli(workdir, "new", "Alpha")
            self.run_cli(workdir, "new", "Beta")
            t1 = workdir / "tickets" / "T-000002.md"
            t2 = workdir / "tickets" / "T-000003.md"
            self._set_depends_on(t1, ["T-000003"])
            self._set_depends_on(t2, ["T-000002"])

            r = self.run_cli(workdir, "validate")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("dependency cycle", r.stderr)

    def test_validate_detects_three_ticket_cycle(self):
        """A->B->C->A cycle must be detected."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)
            self.run_cli(workdir, "new", "Alpha")
            self.run_cli(workdir, "new", "Beta")
            self.run_cli(workdir, "new", "Gamma")
            t2 = workdir / "tickets" / "T-000002.md"
            t3 = workdir / "tickets" / "T-000003.md"
            t4 = workdir / "tickets" / "T-000004.md"
            self._set_depends_on(t2, ["T-000003"])
            self._set_depends_on(t3, ["T-000004"])
            self._set_depends_on(t4, ["T-000002"])

            r = self.run_cli(workdir, "validate")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("dependency cycle", r.stderr)
            # Verify the cycle mentions all three tickets
            cycle_line = [l for l in r.stderr.splitlines() if "dependency cycle" in l][0]
            self.assertIn("T-000002", cycle_line)
            self.assertIn("T-000003", cycle_line)
            self.assertIn("T-000004", cycle_line)

    def test_validate_passes_valid_linear_deps(self):
        """A->B->C (no cycle) should pass validation."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)
            self.run_cli(workdir, "new", "Alpha")
            self.run_cli(workdir, "new", "Beta")
            self.run_cli(workdir, "new", "Gamma")
            t2 = workdir / "tickets" / "T-000002.md"
            t3 = workdir / "tickets" / "T-000003.md"
            self._set_depends_on(t2, ["T-000003"])
            self._set_depends_on(t3, ["T-000004"])

            r = self.run_cli(workdir, "validate")
            self.assertEqual(r.returncode, 0, f"Expected pass but got: {r.stderr}")

    def test_validate_passes_no_dependencies(self):
        """Tickets with no dependencies should pass."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)
            self.run_cli(workdir, "new", "Alpha")
            self.run_cli(workdir, "new", "Beta")

            r = self.run_cli(workdir, "validate")
            self.assertEqual(r.returncode, 0, f"Expected pass but got: {r.stderr}")

    def test_self_dep_and_cycle_reported_together(self):
        """Both self-dep and cycle errors should appear in one validate run."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)
            self.run_cli(workdir, "new", "Alpha")
            self.run_cli(workdir, "new", "Beta")
            self.run_cli(workdir, "new", "Gamma")
            t2 = workdir / "tickets" / "T-000002.md"
            t3 = workdir / "tickets" / "T-000003.md"
            t4 = workdir / "tickets" / "T-000004.md"
            # T-000002 self-dep
            self._set_depends_on(t2, ["T-000002"])
            # T-000003 <-> T-000004 cycle
            self._set_depends_on(t3, ["T-000004"])
            self._set_depends_on(t4, ["T-000003"])

            r = self.run_cli(workdir, "validate")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("depends_on itself", r.stderr)
            self.assertIn("dependency cycle", r.stderr)


if __name__ == "__main__":
    unittest.main()
