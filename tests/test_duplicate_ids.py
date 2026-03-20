import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "mt.py"
PYTHON = ROOT / ".venv" / "bin" / "python"


class DuplicateIdTests(unittest.TestCase):
    """Duplicate logical IDs must be rejected."""

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
        self.assertEqual(self.run_cli(workdir, "new", "Ticket A").returncode, 0)
        self.assertEqual(self.run_cli(workdir, "new", "Ticket B").returncode, 0)

    def _set_frontmatter_id(self, ticket_path: Path, new_id: str) -> None:
        text = ticket_path.read_text(encoding="utf-8")
        text = re.sub(r"^id:\s*.*$", f"id: {new_id}", text, flags=re.M)
        ticket_path.write_text(text, encoding="utf-8")

    # ── validate detects duplicates within active tickets ──────────

    def test_validate_detects_duplicate_active_ids(self) -> None:
        """validate must fail when two active tickets share the same frontmatter id."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)

            # Corrupt T-000003's frontmatter id to match T-000002
            ticket_b = workdir / "tickets" / "T-000003.md"
            self._set_frontmatter_id(ticket_b, "T-000002")

            r = self.run_cli(workdir, "validate")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("duplicate", r.stderr.lower())
            self.assertIn("T-000002", r.stderr)

    # ── validate detects duplicate across active and archive ───────

    def test_validate_detects_duplicate_across_active_and_archive(self) -> None:
        """validate must fail when an active ticket has the same id as an archived one."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)

            # Archive T-000002
            self.run_cli(workdir, "set-status", "T-000002", "claimed", "--owner", "a", "--force")
            self.run_cli(workdir, "set-status", "T-000002", "needs_review")
            self.run_cli(workdir, "done", "T-000002")
            self.run_cli(workdir, "archive", "T-000002")

            # Corrupt T-000003's id to match archived T-000002
            ticket_b = workdir / "tickets" / "T-000003.md"
            self._set_frontmatter_id(ticket_b, "T-000002")

            r = self.run_cli(workdir, "validate")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("duplicate", r.stderr.lower())

    # ── validate detects duplicate across active and errors ────────

    def test_validate_detects_duplicate_across_active_and_errors(self) -> None:
        """validate must fail when active ticket has same id as one in errors/."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)

            # Manually create an errors/ ticket with same id as T-000002
            errors = workdir / "tickets" / "errors"
            errors.mkdir(parents=True, exist_ok=True)
            src = workdir / "tickets" / "T-000002.md"
            dst = errors / "T-000099.md"
            shutil.copy2(str(src), str(dst))
            # dst has frontmatter id=T-000002, same as active

            r = self.run_cli(workdir, "validate")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("duplicate", r.stderr.lower())
            self.assertIn("T-000002", r.stderr)

    # ── validate passes when no duplicates ─────────────────────────

    def test_validate_passes_with_unique_ids(self) -> None:
        """validate should pass when all tickets have unique ids."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)

            r = self.run_cli(workdir, "validate")
            self.assertEqual(r.returncode, 0, msg=r.stderr)

    # ── new never overwrites existing tickets ────────────────────────

    def test_new_never_overwrites_existing_ticket(self) -> None:
        """cmd_new must never overwrite an existing ticket file."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=str(workdir), check=True)
            self.assertEqual(self.run_cli(workdir, "init").returncode, 0)

            # Create several tickets, verify each has unique content
            r1 = self.run_cli(workdir, "new", "Alpha")
            self.assertEqual(r1.returncode, 0)
            r2 = self.run_cli(workdir, "new", "Beta")
            self.assertEqual(r2.returncode, 0)

            t2 = workdir / "tickets" / "T-000002.md"
            t3 = workdir / "tickets" / "T-000003.md"
            self.assertIn("Alpha", t2.read_text(encoding="utf-8"))
            self.assertIn("Beta", t3.read_text(encoding="utf-8"))

            # Original content preserved after another new
            original = t2.read_text(encoding="utf-8")
            r3 = self.run_cli(workdir, "new", "Gamma")
            self.assertEqual(r3.returncode, 0)
            self.assertEqual(t2.read_text(encoding="utf-8"), original)


if __name__ == "__main__":
    unittest.main()
