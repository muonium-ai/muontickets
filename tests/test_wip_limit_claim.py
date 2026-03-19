import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "mt.py"
PYTHON = ROOT / ".venv" / "bin" / "python"


class ClaimWipLimitTests(unittest.TestCase):
    """claim and set-status must enforce per-owner WIP limit (same as pick/allocate-task)."""

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

    # ── claim: WIP limit enforcement ──

    def test_claim_rejects_when_wip_exceeded(self) -> None:
        """Claiming a third ticket with default max=2 must fail."""
        workdir = self._init_repo()
        # Create 3 ready tickets (T-000002, T-000003, T-000004 since T-000001 is the seed)
        for title in ["Task A", "Task B", "Task C"]:
            self.assertEqual(self.run_cli(workdir, "new", title).returncode, 0)

        # Claim first two — should succeed
        self.assertEqual(
            self.run_cli(workdir, "claim", "T-000002", "--owner", "alice").returncode, 0)
        self.assertEqual(
            self.run_cli(workdir, "claim", "T-000003", "--owner", "alice").returncode, 0)

        # Third claim should fail (WIP limit = 2)
        r = self.run_cli(workdir, "claim", "T-000004", "--owner", "alice")
        self.assertEqual(r.returncode, 2)
        self.assertIn("already has 2 claimed tickets", r.stderr)

    def test_claim_allows_different_owner(self) -> None:
        """WIP limit is per-owner, so a different owner should succeed."""
        workdir = self._init_repo()
        for title in ["Task A", "Task B", "Task C"]:
            self.assertEqual(self.run_cli(workdir, "new", title).returncode, 0)

        self.assertEqual(
            self.run_cli(workdir, "claim", "T-000002", "--owner", "alice").returncode, 0)
        self.assertEqual(
            self.run_cli(workdir, "claim", "T-000003", "--owner", "alice").returncode, 0)

        # Bob should be able to claim even though alice is at limit
        r = self.run_cli(workdir, "claim", "T-000004", "--owner", "bob")
        self.assertEqual(r.returncode, 0)

    def test_claim_custom_wip_limit(self) -> None:
        """--max-claimed-per-owner overrides the default limit."""
        workdir = self._init_repo()
        for title in ["Task A", "Task B", "Task C"]:
            self.assertEqual(self.run_cli(workdir, "new", title).returncode, 0)

        self.assertEqual(
            self.run_cli(workdir, "claim", "T-000002", "--owner", "alice").returncode, 0)
        self.assertEqual(
            self.run_cli(workdir, "claim", "T-000003", "--owner", "alice").returncode, 0)

        # With limit=3, third claim should succeed
        r = self.run_cli(workdir, "claim", "T-000004", "--owner", "alice",
                         "--max-claimed-per-owner", "3")
        self.assertEqual(r.returncode, 0)

    def test_claim_force_bypasses_wip(self) -> None:
        """--force skips WIP check."""
        workdir = self._init_repo()
        for title in ["Task A", "Task B", "Task C"]:
            self.assertEqual(self.run_cli(workdir, "new", title).returncode, 0)

        self.assertEqual(
            self.run_cli(workdir, "claim", "T-000002", "--owner", "alice").returncode, 0)
        self.assertEqual(
            self.run_cli(workdir, "claim", "T-000003", "--owner", "alice").returncode, 0)

        r = self.run_cli(workdir, "claim", "T-000004", "--owner", "alice", "--force")
        self.assertEqual(r.returncode, 0)

    # ── set-status: WIP limit enforcement ──

    def test_set_status_claimed_rejects_when_wip_exceeded(self) -> None:
        """set-status to claimed also enforces WIP limit."""
        workdir = self._init_repo()
        for title in ["Task A", "Task B", "Task C"]:
            self.assertEqual(self.run_cli(workdir, "new", title).returncode, 0)

        # Claim two tickets for alice
        self.assertEqual(
            self.run_cli(workdir, "claim", "T-000002", "--owner", "alice").returncode, 0)
        self.assertEqual(
            self.run_cli(workdir, "claim", "T-000003", "--owner", "alice").returncode, 0)

        # set-status T-000004 claimed with alice as owner should fail
        r = self.run_cli(workdir, "set-status", "T-000004", "claimed", "--owner", "alice")
        self.assertEqual(r.returncode, 2)
        self.assertIn("already has 2 claimed tickets", r.stderr)

    def test_set_status_claimed_custom_wip_limit(self) -> None:
        """set-status respects --max-claimed-per-owner."""
        workdir = self._init_repo()
        for title in ["Task A", "Task B", "Task C"]:
            self.assertEqual(self.run_cli(workdir, "new", title).returncode, 0)

        self.assertEqual(
            self.run_cli(workdir, "claim", "T-000002", "--owner", "alice").returncode, 0)
        self.assertEqual(
            self.run_cli(workdir, "claim", "T-000003", "--owner", "alice").returncode, 0)

        r = self.run_cli(workdir, "set-status", "T-000004", "claimed",
                         "--owner", "alice", "--max-claimed-per-owner", "3")
        self.assertEqual(r.returncode, 0)

    def test_set_status_force_bypasses_wip(self) -> None:
        """--force on set-status bypasses WIP check."""
        workdir = self._init_repo()
        for title in ["Task A", "Task B", "Task C"]:
            self.assertEqual(self.run_cli(workdir, "new", title).returncode, 0)

        self.assertEqual(
            self.run_cli(workdir, "claim", "T-000002", "--owner", "alice").returncode, 0)
        self.assertEqual(
            self.run_cli(workdir, "claim", "T-000003", "--owner", "alice").returncode, 0)

        r = self.run_cli(workdir, "set-status", "T-000004", "claimed", "--force")
        self.assertEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
