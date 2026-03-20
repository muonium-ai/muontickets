import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "mt.py"
PYTHON = ROOT / ".venv" / "bin" / "python"


class FilenameIdMatchTests(unittest.TestCase):
    """Filename and frontmatter id must always agree."""

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
        self.assertEqual(self.run_cli(workdir, "new", "Test Ticket").returncode, 0)

    def _corrupt_frontmatter_id(self, ticket_path: Path, new_id: str) -> None:
        text = ticket_path.read_text(encoding="utf-8")
        text = re.sub(r"^id:\s*.*$", f"id: {new_id}", text, flags=re.M)
        ticket_path.write_text(text, encoding="utf-8")

    # ── validate detects mismatch ──────────────────────────────────

    def test_validate_detects_filename_id_mismatch(self) -> None:
        """validate must report when filename and frontmatter id diverge."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)
            ticket = workdir / "tickets" / "T-000002.md"
            self._corrupt_frontmatter_id(ticket, "T-999999")

            r = self.run_cli(workdir, "validate")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("mismatch", r.stderr.lower())

    def test_validate_passes_when_ids_match(self) -> None:
        """validate should pass when filename and frontmatter id agree."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)

            r = self.run_cli(workdir, "validate")
            self.assertEqual(r.returncode, 0, msg=r.stderr)

    # ── write rejects mismatch ─────────────────────────────────────

    def test_set_status_rejects_corrupted_id(self) -> None:
        """set-status must refuse to write a ticket with mismatched id."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)
            ticket = workdir / "tickets" / "T-000002.md"
            self._corrupt_frontmatter_id(ticket, "T-888888")

            r = self.run_cli(workdir, "set-status", "T-000002", "blocked")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("mismatch", r.stderr.lower())

    def test_comment_rejects_corrupted_id(self) -> None:
        """comment must refuse to write a ticket with mismatched id."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)
            ticket = workdir / "tickets" / "T-000002.md"
            self._corrupt_frontmatter_id(ticket, "T-777777")

            r = self.run_cli(workdir, "comment", "T-000002", "hello")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("mismatch", r.stderr.lower())

    # ── show detects mismatch ──────────────────────────────────────

    def test_show_rejects_corrupted_id(self) -> None:
        """show must refuse to display a ticket with mismatched id."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)
            ticket = workdir / "tickets" / "T-000002.md"
            self._corrupt_frontmatter_id(ticket, "T-666666")

            r = self.run_cli(workdir, "show", "T-000002")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("mismatch", r.stderr.lower())

    # ── new always creates matched ids ─────────────────────────────

    def test_new_ticket_has_matching_filename_and_id(self) -> None:
        """new must create ticket where filename matches frontmatter id."""
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_repo(workdir)

            ticket = workdir / "tickets" / "T-000002.md"
            text = ticket.read_text(encoding="utf-8")
            m = re.search(r"^id:\s*(.+)$", text, flags=re.M)
            self.assertIsNotNone(m)
            self.assertEqual(m.group(1).strip(), "T-000002")


if __name__ == "__main__":
    unittest.main()
