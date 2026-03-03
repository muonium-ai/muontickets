import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "mt.py"
PYTHON = ROOT / ".venv" / "bin" / "python"


class ArchiveGuidanceTests(unittest.TestCase):
    def run_cli(self, cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(PYTHON), str(CLI), *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
        )

    def test_archive_block_and_force_guidance(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)

            subprocess.run(["git", "init", "-q"], cwd=str(workdir), check=True)

            self.assertEqual(self.run_cli(workdir, "init").returncode, 0)
            self.assertEqual(self.run_cli(workdir, "new", "Ticket Alpha").returncode, 0)
            self.assertEqual(self.run_cli(workdir, "claim", "T-000002", "--owner", "tester").returncode, 0)
            self.assertEqual(self.run_cli(workdir, "set-status", "T-000002", "needs_review").returncode, 0)
            self.assertEqual(self.run_cli(workdir, "done", "T-000002").returncode, 0)
            self.assertEqual(
                self.run_cli(workdir, "new", "Ticket Beta", "--depends-on", "T-000002").returncode,
                0,
            )

            blocked = self.run_cli(workdir, "archive", "T-000002")
            self.assertNotEqual(blocked.returncode, 0)
            self.assertIn("active tickets depend on this ticket: T-000003", blocked.stderr)
            self.assertIn("using --force can leave invalid active references", blocked.stderr)

            forced = self.run_cli(workdir, "archive", "T-000002", "--force")
            self.assertEqual(forced.returncode, 0)
            combined = f"{forced.stdout}\n{forced.stderr}"
            self.assertIn("force-archiving with active dependents: T-000003", combined)

            validate = self.run_cli(workdir, "validate")
            self.assertNotEqual(validate.returncode, 0)
            self.assertIn("depends_on archived ticket T-000002", validate.stderr)
            self.assertIn("avoid mt archive --force", validate.stderr)


if __name__ == "__main__":
    unittest.main()
