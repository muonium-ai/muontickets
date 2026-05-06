import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "mt.py"
PYTHON = ROOT / ".venv" / "bin" / "python"


class CliTicketIdErrorTests(unittest.TestCase):
    """CLI ticket-id lookup errors should be concise user-facing stderr."""

    def run_cli(self, cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(PYTHON), str(CLI), *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
        )

    def _init_repo(self, workdir: Path) -> None:
        subprocess.run(["git", "init", "-q"], cwd=str(workdir), check=True)
        self.assertEqual(self.run_cli(workdir, "init").returncode, 0)

    def assert_user_facing_error(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertNotIn("Traceback", result.stderr)

    def test_show_missing_ticket_reports_error_without_traceback(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)

            result = self.run_cli(workdir, "show", "T-999999")

            self.assert_user_facing_error(result)
            self.assertIn("Ticket not found: T-999999", result.stderr)

    def test_claim_missing_ticket_reports_error_without_traceback(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)

            result = self.run_cli(workdir, "claim", "T-999999", "--owner", "alice")

            self.assert_user_facing_error(result)
            self.assertIn("Ticket not found: T-999999", result.stderr)

    def test_invalid_ticket_id_reports_expected_format(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)

            result = self.run_cli(workdir, "show", "abc")

            self.assert_user_facing_error(result)
            self.assertIn("Invalid ticket id: abc", result.stderr)
            self.assertIn("expected format T-000000", result.stderr)


if __name__ == "__main__":
    unittest.main()
