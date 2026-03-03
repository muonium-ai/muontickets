import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "mt.py"
PYTHON = ROOT / ".venv" / "bin" / "python"


class QueueAllocationTests(unittest.TestCase):
    def run_cli(self, cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(PYTHON), str(CLI), *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
        )

    def _set_lease_expired(self, ticket_path: Path) -> None:
        text = ticket_path.read_text(encoding="utf-8")
        updated = re.sub(
            r"^lease_expires_at:\s*.*$",
            "lease_expires_at: 1970-01-01T00:00:00Z",
            text,
            flags=re.M,
        )
        ticket_path.write_text(updated, encoding="utf-8")

    def test_allocate_task_can_reallocate_expired_lease(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=str(workdir), check=True)

            self.assertEqual(self.run_cli(workdir, "init").returncode, 0)
            self.assertEqual(self.run_cli(workdir, "new", "Lease Ticket").returncode, 0)

            first = self.run_cli(workdir, "allocate-task", "--owner", "agent-a")
            self.assertEqual(first.returncode, 0)
            self.assertIn("T-000002", first.stdout)

            ticket_path = workdir / "tickets" / "T-000002.md"
            self._set_lease_expired(ticket_path)

            second = self.run_cli(workdir, "allocate-task", "--owner", "agent-b")
            self.assertEqual(second.returncode, 0)
            self.assertIn("T-000002", second.stdout)

            incidents = (workdir / "tickets" / "incidents.log").read_text(encoding="utf-8")
            self.assertIn("stale-lease-reallocation", incidents)
            self.assertIn("id=T-000002", incidents)

    def test_fail_task_retries_then_moves_to_errors(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=str(workdir), check=True)

            self.assertEqual(self.run_cli(workdir, "init").returncode, 0)
            self.assertEqual(self.run_cli(workdir, "new", "Retry Ticket").returncode, 0)

            tid = "T-000002"
            for _ in range(2):
                alloc = self.run_cli(workdir, "allocate-task", "--owner", "agent-a")
                self.assertEqual(alloc.returncode, 0)
                self.assertIn(tid, alloc.stdout)

                failed = self.run_cli(workdir, "fail-task", tid, "--error", "transient failure")
                self.assertEqual(failed.returncode, 0)
                self.assertIn("re-queued", failed.stdout)

            alloc = self.run_cli(workdir, "allocate-task", "--owner", "agent-a")
            self.assertEqual(alloc.returncode, 0)
            self.assertIn(tid, alloc.stdout)

            exhausted = self.run_cli(workdir, "fail-task", tid, "--error", "persistent failure")
            self.assertEqual(exhausted.returncode, 0)
            self.assertIn("moved to tickets/errors", exhausted.stdout)

            self.assertFalse((workdir / "tickets" / f"{tid}.md").exists())
            self.assertTrue((workdir / "tickets" / "errors" / f"{tid}.md").exists())


if __name__ == "__main__":
    unittest.main()
