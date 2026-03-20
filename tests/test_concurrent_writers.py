import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "mt.py"
PYTHON = ROOT / ".venv" / "bin" / "python"


class ConcurrentWriterSafetyTests(unittest.TestCase):
    """Tests for T-000117: inter-process locking prevents concurrent writer races."""

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

    def test_lockfile_created_on_write(self):
        """Writer commands create .mt.lock in tickets directory."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)
            self.run_cli(workdir, "new", "Alpha")
            lockfile = workdir / "tickets" / ".mt.lock"
            self.assertTrue(lockfile.exists(), ".mt.lock should be created by writer commands")

    def test_parallel_claims_no_double_claim(self):
        """Two parallel claims on the same ticket: one succeeds, the other fails."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)
            self.run_cli(workdir, "new", "Alpha")
            # T-000002 is the new ticket (T-000001 is the example)

            # Launch two claim processes in parallel
            procs = []
            for owner in ["agent-a", "agent-b"]:
                p = subprocess.Popen(
                    [str(PYTHON), str(CLI), "claim", "T-000002", "--owner", owner],
                    cwd=str(workdir),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                procs.append((owner, p))

            results = []
            for owner, p in procs:
                stdout, stderr = p.communicate(timeout=30)
                results.append((owner, p.returncode, stdout, stderr))

            successes = [r for r in results if r[1] == 0]
            failures = [r for r in results if r[1] != 0]

            # With locking, exactly one should succeed and one should fail
            # (the second sees status=claimed, not ready)
            self.assertEqual(len(successes), 1,
                             f"Expected exactly 1 success, got {len(successes)}: {results}")
            self.assertEqual(len(failures), 1,
                             f"Expected exactly 1 failure, got {len(failures)}: {results}")

    def test_parallel_new_unique_ids(self):
        """Parallel new commands produce unique ticket IDs (no collisions)."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)

            # Launch 5 parallel new commands
            procs = []
            for i in range(5):
                p = subprocess.Popen(
                    [str(PYTHON), str(CLI), "new", f"Ticket-{i}"],
                    cwd=str(workdir),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                procs.append(p)

            paths = []
            for p in procs:
                stdout, stderr = p.communicate(timeout=30)
                self.assertEqual(p.returncode, 0,
                                 f"new failed: stdout={stdout}, stderr={stderr}")
                paths.append(stdout.strip())

            # All paths should be unique (no duplicate IDs)
            self.assertEqual(len(set(paths)), 5,
                             f"Expected 5 unique paths, got: {paths}")

    def test_parallel_picks_no_double_pick(self):
        """Two parallel picks: each should claim a different ticket."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)
            self.run_cli(workdir, "new", "Task A")
            self.run_cli(workdir, "new", "Task B")
            # T-000002 and T-000003 are ready

            procs = []
            for owner in ["agent-a", "agent-b"]:
                p = subprocess.Popen(
                    [str(PYTHON), str(CLI), "pick", "--owner", owner],
                    cwd=str(workdir),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                procs.append((owner, p))

            results = []
            for owner, p in procs:
                stdout, stderr = p.communicate(timeout=30)
                results.append((owner, p.returncode, stdout, stderr))

            successes = [r for r in results if r[1] == 0]
            # Both should succeed (claiming different tickets)
            self.assertEqual(len(successes), 2,
                             f"Expected 2 successes, got {len(successes)}: {results}")

            # Verify they claimed different tickets
            claimed_ids = set()
            for owner, rc, stdout, stderr in successes:
                for word in stdout.split():
                    if word.startswith("T-"):
                        claimed_ids.add(word)
            self.assertEqual(len(claimed_ids), 2,
                             f"Expected 2 different ticket IDs, got: {claimed_ids}")

    def test_lock_is_reentrant_safe(self):
        """Sequential operations on the same repo work fine (lock released properly)."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)
            r1 = self.run_cli(workdir, "new", "First")
            self.assertEqual(r1.returncode, 0)
            r2 = self.run_cli(workdir, "new", "Second")
            self.assertEqual(r2.returncode, 0)
            r3 = self.run_cli(workdir, "new", "Third")
            self.assertEqual(r3.returncode, 0)
            # All three should succeed sequentially
            r = self.run_cli(workdir, "validate")
            self.assertEqual(r.returncode, 0, f"Validation failed: {r.stderr}")


if __name__ == "__main__":
    unittest.main()
