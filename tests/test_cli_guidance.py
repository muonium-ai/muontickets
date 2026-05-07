import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "mt.py"
PYTHON = ROOT / ".venv" / "bin" / "python"


class CliGuidanceTests(unittest.TestCase):
    def run_cli(self, cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(PYTHON), str(CLI), *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
        )

    def _init_git_repo(self, workdir: Path) -> None:
        subprocess.run(["git", "init", "-q"], cwd=str(workdir), check=True)

    def test_no_command_shows_human_guidance_without_replacing_version_command(self) -> None:
        proc = self.run_cli(ROOT)

        self.assertEqual(proc.returncode, 0, msg=f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("MuonTickets CLI", proc.stdout)
        self.assertIn("mt init", proc.stdout)
        self.assertIn("mt new", proc.stdout)
        self.assertIn("mt ls", proc.stdout)
        self.assertIn("mt version", proc.stdout)
        self.assertNotIn("python_executable=", proc.stdout)

        version = self.run_cli(ROOT, "version")
        self.assertEqual(version.returncode, 0, msg=f"stdout:\n{version.stdout}\nstderr:\n{version.stderr}")
        self.assertIn("mt.py", version.stdout)
        self.assertIn("python_executable=", version.stdout)

    def test_init_prints_next_commands_for_new_and_existing_board(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_git_repo(workdir)

            created = self.run_cli(workdir, "init")
            self.assertEqual(created.returncode, 0, msg=f"stdout:\n{created.stdout}\nstderr:\n{created.stderr}")
            self.assertIn("Next:", created.stdout)
            self.assertIn("mt new \"Title\"", created.stdout)
            self.assertIn("mt ls", created.stdout)
            self.assertIn("mt pick --owner <name>", created.stdout)

            existing = self.run_cli(workdir, "init")
            self.assertEqual(existing.returncode, 0, msg=f"stdout:\n{existing.stdout}\nstderr:\n{existing.stderr}")
            self.assertIn("tickets dir exists:", existing.stdout)
            self.assertIn("Next:", existing.stdout)
            self.assertIn("mt new \"Title\"", existing.stdout)

    def test_new_prints_id_relative_path_next_commands_and_absolute_path_compatibility(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_git_repo(workdir)
            self.assertEqual(self.run_cli(workdir, "init").returncode, 0)

            created = self.run_cli(workdir, "new", "First real ticket")

            self.assertEqual(created.returncode, 0, msg=f"stdout:\n{created.stdout}\nstderr:\n{created.stderr}")
            self.assertRegex(created.stdout, re.escape(str(workdir)) + r"/tickets/T-000002\.md")
            self.assertIn("Created T-000002", created.stdout)
            self.assertIn("Path: tickets/T-000002.md", created.stdout)
            self.assertIn("Next:", created.stdout)
            self.assertIn("mt show T-000002", created.stdout)
            self.assertIn("mt claim T-000002 --owner <name>", created.stdout)

    def test_empty_ls_explains_no_matches_and_suggests_new_or_filter_changes(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            workdir = Path(td)
            self._init_git_repo(workdir)

            empty_board = self.run_cli(workdir, "ls")
            self.assertEqual(empty_board.returncode, 0, msg=f"stdout:\n{empty_board.stdout}\nstderr:\n{empty_board.stderr}")
            self.assertIn("No tickets matched.", empty_board.stdout)
            self.assertIn("mt new \"Title\"", empty_board.stdout)

            self.assertEqual(self.run_cli(workdir, "init").returncode, 0)
            filtered = self.run_cli(workdir, "ls", "--status", "done")
            self.assertEqual(filtered.returncode, 0, msg=f"stdout:\n{filtered.stdout}\nstderr:\n{filtered.stderr}")
            self.assertIn("No tickets matched.", filtered.stdout)
            self.assertIn("Try less restrictive filters.", filtered.stdout)


if __name__ == "__main__":
    unittest.main()
