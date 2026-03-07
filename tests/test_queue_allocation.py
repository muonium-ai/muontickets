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

    def _meta_field(self, ticket_path: Path, key: str) -> str:
        text = ticket_path.read_text(encoding="utf-8")
        match = re.search(rf"^{re.escape(key)}:\s*(.*)$", text, flags=re.M)
        self.assertIsNotNone(match, f"missing metadata field: {key}")
        return (match.group(1) if match else "").strip()

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
            ticket_path = workdir / "tickets" / f"{tid}.md"

            for attempt in range(1, 3):
                alloc = self.run_cli(workdir, "allocate-task", "--owner", "agent-a")
                self.assertEqual(alloc.returncode, 0)
                self.assertIn(tid, alloc.stdout)

                failed = self.run_cli(workdir, "fail-task", tid, "--error", "transient failure")
                self.assertEqual(failed.returncode, 0)
                self.assertIn("re-queued", failed.stdout)
                self.assertIn(f"{attempt}/3", failed.stdout)
                self.assertEqual(self._meta_field(ticket_path, "status"), "ready")
                self.assertEqual(self._meta_field(ticket_path, "retry_count"), str(attempt))
                self.assertEqual(self._meta_field(ticket_path, "retry_limit"), "3")
                self.assertEqual(self._meta_field(ticket_path, "last_error"), "transient failure")

            alloc = self.run_cli(workdir, "allocate-task", "--owner", "agent-a")
            self.assertEqual(alloc.returncode, 0)
            self.assertIn(tid, alloc.stdout)

            exhausted = self.run_cli(workdir, "fail-task", tid, "--error", "persistent failure")
            self.assertEqual(exhausted.returncode, 0)
            self.assertIn("moved to tickets/errors", exhausted.stdout)

            self.assertFalse((workdir / "tickets" / f"{tid}.md").exists())
            error_ticket_path = workdir / "tickets" / "errors" / f"{tid}.md"
            self.assertTrue(error_ticket_path.exists())
            self.assertEqual(self._meta_field(error_ticket_path, "status"), "blocked")
            self.assertEqual(self._meta_field(error_ticket_path, "retry_count"), "3")
            self.assertEqual(self._meta_field(error_ticket_path, "retry_limit"), "3")
            self.assertEqual(self._meta_field(error_ticket_path, "last_error"), "persistent failure")

            no_candidate = self.run_cli(workdir, "allocate-task", "--owner", "agent-a", "--label", "queue")
            self.assertEqual(no_candidate.returncode, 3)
            self.assertIn("no allocatable tickets found", no_candidate.stderr)

    def test_new_ignores_nested_git_submodule_ticket_ids(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=str(workdir), check=True)

            self.assertEqual(self.run_cli(workdir, "init").returncode, 0)

            nested_repo = workdir / "tickets" / "mt" / "muontickets"
            (nested_repo / "tickets").mkdir(parents=True, exist_ok=True)
            (nested_repo / ".git").write_text("gitdir: ../../.git/modules/tickets/mt/muontickets\n", encoding="utf-8")
            (nested_repo / "tickets" / "T-000123.md").write_text("---\nid: T-000123\n---\n", encoding="utf-8")

            created = self.run_cli(workdir, "new", "Parent Repo Ticket")
            self.assertEqual(created.returncode, 0)
            self.assertIn("T-000002", created.stdout)
            self.assertTrue((workdir / "tickets" / "T-000002.md").exists())
            self.assertEqual("T-000002", (workdir / "tickets" / "last_ticket_id").read_text(encoding="utf-8").strip())


if __name__ == "__main__":
    unittest.main()
