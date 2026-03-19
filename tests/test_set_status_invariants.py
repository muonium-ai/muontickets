import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "mt.py"
PYTHON = ROOT / ".venv" / "bin" / "python"


class SetStatusClaimedInvariantTests(unittest.TestCase):
    """set-status must enforce owner, branch, and dependency invariants
    when transitioning to claimed (same as the claim command)."""

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

    def _read_meta_field(self, ticket_path: Path, key: str) -> str:
        import re
        text = ticket_path.read_text(encoding="utf-8")
        match = re.search(rf"^{re.escape(key)}:\s*(.*)$", text, flags=re.M)
        return (match.group(1) if match else "").strip().strip("'\"")

    # ── owner invariant ──

    def test_set_status_claimed_without_owner_rejected(self) -> None:
        """ready -> claimed via set-status without owner must fail."""
        workdir = self._init_repo()
        self.assertEqual(self.run_cli(workdir, "new", "No Owner").returncode, 0)
        r = self.run_cli(workdir, "set-status", "T-000002", "claimed")
        self.assertEqual(r.returncode, 2)
        self.assertIn("owner", r.stderr.lower())

    def test_set_status_claimed_with_owner_flag(self) -> None:
        """ready -> claimed via set-status with --owner must succeed."""
        workdir = self._init_repo()
        self.assertEqual(self.run_cli(workdir, "new", "Has Owner").returncode, 0)
        r = self.run_cli(workdir, "set-status", "T-000002", "claimed", "--owner", "alice")
        self.assertEqual(r.returncode, 0)
        ticket_path = workdir / "tickets" / "T-000002.md"
        self.assertEqual(self._read_meta_field(ticket_path, "owner"), "alice")
        self.assertTrue(self._read_meta_field(ticket_path, "branch"))  # branch auto-generated

    def test_set_status_claimed_uses_existing_owner(self) -> None:
        """blocked -> claimed when meta already has owner should succeed."""
        workdir = self._init_repo()
        self.assertEqual(self.run_cli(workdir, "new", "Blocked Ticket").returncode, 0)
        # claim first, then block, then re-claim via set-status
        self.assertEqual(self.run_cli(workdir, "claim", "T-000002", "--owner", "bob").returncode, 0)
        self.assertEqual(self.run_cli(workdir, "set-status", "T-000002", "blocked").returncode, 0)
        r = self.run_cli(workdir, "set-status", "T-000002", "claimed")
        self.assertEqual(r.returncode, 0)
        ticket_path = workdir / "tickets" / "T-000002.md"
        self.assertEqual(self._read_meta_field(ticket_path, "owner"), "bob")

    # ── branch invariant ──

    def test_set_status_claimed_autogenerates_branch(self) -> None:
        """When owner given but no branch, a default branch is generated."""
        workdir = self._init_repo()
        self.assertEqual(self.run_cli(workdir, "new", "Auto Branch").returncode, 0)
        r = self.run_cli(workdir, "set-status", "T-000002", "claimed", "--owner", "carol")
        self.assertEqual(r.returncode, 0)
        ticket_path = workdir / "tickets" / "T-000002.md"
        branch = self._read_meta_field(ticket_path, "branch")
        self.assertIn("t-000002", branch.lower())

    def test_set_status_claimed_respects_branch_flag(self) -> None:
        """--branch flag sets the branch explicitly."""
        workdir = self._init_repo()
        self.assertEqual(self.run_cli(workdir, "new", "Explicit Branch").returncode, 0)
        r = self.run_cli(workdir, "set-status", "T-000002", "claimed",
                         "--owner", "dave", "--branch", "fix/custom-branch")
        self.assertEqual(r.returncode, 0)
        ticket_path = workdir / "tickets" / "T-000002.md"
        self.assertEqual(self._read_meta_field(ticket_path, "branch"), "fix/custom-branch")

    # ── dependency invariant ──

    def test_set_status_claimed_rejects_unsatisfied_deps(self) -> None:
        """Transition to claimed must fail when dependencies are not done."""
        workdir = self._init_repo()
        self.assertEqual(self.run_cli(workdir, "new", "Dep Target").returncode, 0)
        self.assertEqual(self.run_cli(workdir, "new", "Dep Holder").returncode, 0)
        # Add dependency T-000003 depends on T-000002
        ticket_path = workdir / "tickets" / "T-000003.md"
        text = ticket_path.read_text(encoding="utf-8")
        text = text.replace("depends_on: []", "depends_on:\n- T-000002")
        ticket_path.write_text(text, encoding="utf-8")

        r = self.run_cli(workdir, "set-status", "T-000003", "claimed", "--owner", "eve")
        self.assertEqual(r.returncode, 2)
        self.assertIn("dependencies not done", r.stderr)

    def test_set_status_claimed_ignore_deps_overrides(self) -> None:
        """--ignore-deps skips the dependency check."""
        workdir = self._init_repo()
        self.assertEqual(self.run_cli(workdir, "new", "Dep Target").returncode, 0)
        self.assertEqual(self.run_cli(workdir, "new", "Dep Holder").returncode, 0)
        ticket_path = workdir / "tickets" / "T-000003.md"
        text = ticket_path.read_text(encoding="utf-8")
        text = text.replace("depends_on: []", "depends_on:\n- T-000002")
        ticket_path.write_text(text, encoding="utf-8")

        r = self.run_cli(workdir, "set-status", "T-000003", "claimed",
                         "--owner", "eve", "--ignore-deps")
        self.assertEqual(r.returncode, 0)

    # ── force bypasses all invariants ──

    def test_set_status_force_bypasses_claimed_invariants(self) -> None:
        """--force skips owner, branch, and dependency checks."""
        workdir = self._init_repo()
        self.assertEqual(self.run_cli(workdir, "new", "Force Ticket").returncode, 0)
        r = self.run_cli(workdir, "set-status", "T-000002", "claimed", "--force")
        self.assertEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
