import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Optional

from muontickets import mt


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"


class InstallerHookTests(unittest.TestCase):
    def _run(self, cmd: list[str], cwd: Path, env: Optional[dict[str, str]] = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(cmd, cwd=str(cwd), env=env, capture_output=True, text=True)

    def _write_fake_uv(self, root: Path) -> Path:
        bin_dir = root / "bin"
        bin_dir.mkdir()
        uv = bin_dir / "uv"
        uv.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        uv.chmod(0o755)
        return bin_dir

    def _init_project_with_muontickets_fixture(self, root: Path, include_template: bool = True) -> tuple[Path, str]:
        project = root / "project"
        project.mkdir()
        self._run(["git", "init", "-q"], project).check_returncode()

        fixture = project / "tickets" / "mt" / "muontickets"
        (fixture / "hooks").mkdir(parents=True)
        muon_hook = "#!/bin/sh\necho muontickets hook\n"
        (fixture / "hooks" / "pre-commit").write_text(muon_hook, encoding="utf-8")
        (fixture / "mt.py").write_text("print('fixture mt')\n", encoding="utf-8")
        (fixture / "Makefile.snippet").write_text("# fixture snippet\n", encoding="utf-8")
        if include_template:
            (fixture / "ticket.template").write_text("---\nid: T-000000\n---\n", encoding="utf-8")

        self._run(["git", "init", "-q"], fixture).check_returncode()
        self._run(["git", "add", "."], fixture).check_returncode()
        self._run(
            [
                "git",
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "-qm",
                "fixture",
            ],
            fixture,
        ).check_returncode()
        return project, muon_hook

    def _run_installer(self, project: Path, fake_bin: Path) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
        return self._run(["bash", str(INSTALLER), "--repo", str(project / "tickets" / "mt" / "muontickets")], project, env=env)

    def test_existing_precommit_hook_is_backed_up_before_muontickets_hook_is_written(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            fake_bin = self._write_fake_uv(root)
            project, muon_hook = self._init_project_with_muontickets_fixture(root)
            hooks_dir = project / ".git" / "hooks"
            hooks_dir.mkdir(exist_ok=True)
            original_hook = "#!/bin/sh\necho existing project hook\n"
            installed_hook = hooks_dir / "pre-commit"
            installed_hook.write_text(original_hook, encoding="utf-8")
            installed_hook.chmod(0o755)

            first = self._run_installer(project, fake_bin)
            self.assertEqual(first.returncode, 0, first.stderr + first.stdout)

            backup = hooks_dir / "pre-commit.muontickets-backup"
            self.assertTrue(backup.exists(), first.stderr + first.stdout)
            self.assertEqual(backup.read_text(encoding="utf-8"), original_hook)
            self.assertEqual(installed_hook.read_text(encoding="utf-8"), muon_hook)

            second = self._run_installer(project, fake_bin)
            self.assertEqual(second.returncode, 0, second.stderr + second.stdout)
            backups = sorted(path.name for path in hooks_dir.glob("pre-commit.muontickets-backup*"))
            self.assertEqual(backups, ["pre-commit.muontickets-backup"])
            self.assertEqual(backup.read_text(encoding="utf-8"), original_hook)
            self.assertEqual(installed_hook.read_text(encoding="utf-8"), muon_hook)

    def test_help_documents_existing_hook_backup_behavior(self) -> None:
        result = self._run(["bash", str(INSTALLER), "--help"], ROOT)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("--no-hooks", result.stdout)
        self.assertIn("pre-commit.muontickets-backup", result.stdout)

    def test_fallback_ticket_template_is_valid_yaml(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            fake_bin = self._write_fake_uv(root)
            project, _ = self._init_project_with_muontickets_fixture(root, include_template=False)

            installed = self._run_installer(project, fake_bin)

            self.assertEqual(installed.returncode, 0, installed.stderr + installed.stdout)
            template = (project / "tickets" / "ticket.template").read_text(encoding="utf-8")
            meta, body = mt.split_frontmatter(template)
            self.assertEqual(meta["title"], "Template: replace title")
            self.assertIn("## Goal", body)


if __name__ == "__main__":
    unittest.main()
