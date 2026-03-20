import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "mt.py"
PYTHON = ROOT / ".venv" / "bin" / "python"


class FailTaskOwnerGuardTests(unittest.TestCase):
    """fail-task must verify caller identity matches current owner/allocated_to."""

    def run_cli(self, cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(PYTHON), str(CLI), *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
        )

    def _init_repo(self) -> Path:
        td = tempfile.mkdtemp()
        workdir = Path(td)
        subprocess.run(["git", "init", "-q"], cwd=str(workdir), check=True)
        self.assertEqual(self.run_cli(workdir, "init").returncode, 0)
        return workdir

    def _meta_field(self, ticket_path: Path, key: str) -> str:
        text = ticket_path.read_text(encoding="utf-8")
        match = re.search(rf"^{re.escape(key)}:\s*(.*)$", text, flags=re.M)
        return (match.group(1) if match else "").strip().strip("'\"")

    def _set_lease_expired(self, ticket_path: Path) -> None:
        text = ticket_path.read_text(encoding="utf-8")
        updated = re.sub(
            r"^lease_expires_at:\s*.*$",
            "lease_expires_at: 1970-01-01T00:00:00Z",
            text,
            flags=re.M,
        )
        ticket_path.write_text(updated, encoding="utf-8")

    # ── owner match ──

    def test_fail_task_succeeds_when_owner_matches(self) -> None:
        """fail-task should succeed when caller matches allocated_to."""
        workdir = self._init_repo()
        self.assertEqual(self.run_cli(workdir, "new", "Task A").returncode, 0)

        self.assertEqual(
            self.run_cli(workdir, "allocate-task", "--owner", "agent-a").returncode, 0)

        r = self.run_cli(workdir, "fail-task", "T-000002", "--owner", "agent-a",
                         "--error", "some error")
        self.assertEqual(r.returncode, 0)
        self.assertIn("re-queued", r.stdout)

    def test_fail_task_rejected_when_owner_mismatches(self) -> None:
        """fail-task must reject when caller doesn't match current owner."""
        workdir = self._init_repo()
        self.assertEqual(self.run_cli(workdir, "new", "Task A").returncode, 0)

        self.assertEqual(
            self.run_cli(workdir, "allocate-task", "--owner", "agent-a").returncode, 0)

        r = self.run_cli(workdir, "fail-task", "T-000002", "--owner", "agent-b",
                         "--error", "stale error")
        self.assertEqual(r.returncode, 2)
        self.assertIn("does not match", r.stderr)

    # ── stale worker scenario ──

    def test_stale_worker_cannot_clobber_reallocation(self) -> None:
        """After lease expires and ticket is reallocated, old worker's fail-task
        must be rejected to prevent clobbering the new allocation."""
        workdir = self._init_repo()
        self.assertEqual(self.run_cli(workdir, "new", "Task A").returncode, 0)

        tid = "T-000002"
        ticket_path = workdir / "tickets" / f"{tid}.md"

        # agent-a gets allocation
        self.assertEqual(
            self.run_cli(workdir, "allocate-task", "--owner", "agent-a").returncode, 0)

        # Expire the lease
        self._set_lease_expired(ticket_path)

        # agent-b gets reallocation
        self.assertEqual(
            self.run_cli(workdir, "allocate-task", "--owner", "agent-b").returncode, 0)
        self.assertEqual(self._meta_field(ticket_path, "allocated_to"), "agent-b")

        # agent-a (stale) tries to fail-task — must be rejected
        r = self.run_cli(workdir, "fail-task", tid, "--owner", "agent-a",
                         "--error", "stale failure")
        self.assertEqual(r.returncode, 2)
        self.assertIn("does not match", r.stderr)

        # Ticket should still be claimed by agent-b
        self.assertEqual(self._meta_field(ticket_path, "status"), "claimed")
        self.assertEqual(self._meta_field(ticket_path, "allocated_to"), "agent-b")

    # ── force bypass ──

    def test_fail_task_force_bypasses_owner_check(self) -> None:
        """--force should bypass the owner identity check."""
        workdir = self._init_repo()
        self.assertEqual(self.run_cli(workdir, "new", "Task A").returncode, 0)

        self.assertEqual(
            self.run_cli(workdir, "allocate-task", "--owner", "agent-a").returncode, 0)

        r = self.run_cli(workdir, "fail-task", "T-000002", "--owner", "agent-b",
                         "--error", "forced", "--force")
        self.assertEqual(r.returncode, 0)

    # ── owner required ──

    def test_fail_task_requires_owner_flag(self) -> None:
        """fail-task without --owner should fail with argparse error."""
        workdir = self._init_repo()
        self.assertEqual(self.run_cli(workdir, "new", "Task A").returncode, 0)
        self.assertEqual(
            self.run_cli(workdir, "allocate-task", "--owner", "agent-a").returncode, 0)

        r = self.run_cli(workdir, "fail-task", "T-000002", "--error", "no owner given")
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
